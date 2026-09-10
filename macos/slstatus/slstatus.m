/* See LICENSE file for copyright and license details. */
#import <Foundation/Foundation.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <errno.h>
#include <mach/mach.h>
#include <sys/socket.h>
#include <net/if.h>
#include <net/route.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/statvfs.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

#include "support.h"
#include "config.h"

static volatile sig_atomic_t done;
static volatile sig_atomic_t refresh;

static void
handle_signal(int signo)
{
	if (signo != SIGUSR1)
		done = 1;
	else
		refresh = 1;
}

static NSString *
cpu_usage(void)
{
	static uint32_t previous[4];
	static BOOL sampled;
	host_cpu_load_info_data_t load;
	mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
	mach_port_t host = mach_host_self();
	kern_return_t result = host_statistics(host, HOST_CPU_LOAD_INFO,
	                                      (host_info_t)&load, &count);
	mach_port_deallocate(mach_task_self(), host);
	if (result != KERN_SUCCESS) {
		sampled = NO;
		return unknown;
	}
	uint32_t current[4] = {load.cpu_ticks[CPU_STATE_USER],
	                       load.cpu_ticks[CPU_STATE_SYSTEM],
	                       load.cpu_ticks[CPU_STATE_IDLE],
	                       load.cpu_ticks[CPU_STATE_NICE]};
	double percent = sampled ? cpu_percent(previous, current) : -1;
	memcpy(previous, current, sizeof(previous));
	sampled = YES;
	return percent < 0 ? unknown : [NSString stringWithFormat:@"%.0f%%", percent];
}

static NSString *
ram_usage(void)
{
	vm_statistics64_data_t vm;
	mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
	vm_size_t page_size;
	mach_port_t host = mach_host_self();
	kern_return_t result = host_statistics64(host, HOST_VM_INFO64,
	                                        (host_info64_t)&vm, &count);
	kern_return_t page_result = host_page_size(host, &page_size);
	mach_port_deallocate(mach_task_self(), host);
	if (result != KERN_SUCCESS || page_result != KERN_SUCCESS)
		return unknown;
	double pages = (double)vm.active_count + vm.wire_count + vm.compressor_page_count;
	return [NSString stringWithFormat:@"%.1f GiB", pages * page_size / 1073741824.0];
}

static NSString *
disk_usage(void)
{
	struct statvfs fs;
	if (statvfs(disk_path.fileSystemRepresentation, &fs) < 0 || !fs.f_blocks)
		return unknown;
	return [NSString stringWithFormat:@"%.1f GiB",
	        (double)(fs.f_blocks - fs.f_bfree) * fs.f_frsize / 1073741824.0];
}

static NSString *
battery_usage(void)
{
	CFTypeRef info = IOPSCopyPowerSourcesInfo();
	if (!info)
		return unknown;
	NSArray *sources = CFBridgingRelease(IOPSCopyPowerSourcesList(info));
	NSString *value = unknown;
	for (id source in sources) {
		NSDictionary *battery = (__bridge NSDictionary *)
		    IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)source);
		if (![battery[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType] ||
		    ![battery[@kIOPSIsPresentKey] boolValue])
			continue;
		NSNumber *current = battery[@kIOPSCurrentCapacityKey];
		NSNumber *maximum = battery[@kIOPSMaxCapacityKey];
		if (!current || maximum.doubleValue <= 0)
			continue;
		double percent = MIN(100.0, MAX(0.0, 100.0 * current.doubleValue / maximum.doubleValue));
		NSString *state = [battery[@kIOPSIsChargingKey] boolValue] ? @"charging" :
		    ([battery[@kIOPSPowerSourceStateKey] isEqual:@kIOPSACPowerValue] ? @"AC" : @"battery");
		value = [NSString stringWithFormat:@"%.0f%% %@", percent, state];
		break;
	}
	CFRelease(info);
	return value;
}

static NSString *
primary_interface(void)
{
	if (network_interface.length)
		return network_interface;
	for (NSString *key in @[@"State:/Network/Global/IPv4", @"State:/Network/Global/IPv6"]) {
		NSDictionary *state = CFBridgingRelease(SCDynamicStoreCopyValue(NULL, (__bridge CFStringRef)key));
		NSString *name = state[(__bridge NSString *)kSCDynamicStorePropNetPrimaryInterface];
		if (name.length)
			return name;
	}
	return nil;
}

static BOOL
network_counters(NSString *name, uint64_t *rx, uint64_t *tx)
{
	unsigned int index = if_nametoindex(name.UTF8String);
	if (!index)
		return NO;
	int mib[] = {CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index};
	size_t length = 0;
	if (sysctl(mib, 6, NULL, &length, NULL, 0) < 0 || !length)
		return NO;
	char *buffer = malloc(length);
	if (!buffer)
		return NO;
	BOOL found = NO;
	if (sysctl(mib, 6, buffer, &length, NULL, 0) == 0) {
		for (size_t offset = 0; offset + sizeof(struct if_msghdr) <= length;) {
			struct if_msghdr *header = (struct if_msghdr *)(buffer + offset);
			if (!header->ifm_msglen || header->ifm_msglen > length - offset)
				break;
			if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
				struct if_msghdr2 *message = (struct if_msghdr2 *)header;
				if (message->ifm_index == index && (message->ifm_flags & IFF_UP)) {
					*rx = message->ifm_data.ifi_ibytes;
					*tx = message->ifm_data.ifi_obytes;
					found = YES;
					break;
				}
			}
			offset += header->ifm_msglen;
		}
	}
	free(buffer);
	return found;
}

static NSArray<NSString *> *
network_usage(void)
{
	static NSString *previous_name;
	static uint64_t previous_rx, previous_tx;
	static struct timespec previous_time;
	NSString *name = primary_interface();
	uint64_t rx, tx;
	struct timespec now;
	if (!name || !network_counters(name, &rx, &tx) || clock_gettime(CLOCK_MONOTONIC, &now) < 0) {
		previous_name = nil;
		return @[unknown, unknown];
	}
	double seconds = (double)(now.tv_sec - previous_time.tv_sec) +
	                 (now.tv_nsec - previous_time.tv_nsec) / 1e9;
	double rx_rate, tx_rate;
	BOOL valid = [name isEqualToString:previous_name] &&
	    network_rates(previous_rx, previous_tx, rx, tx, seconds, &rx_rate, &tx_rate);
	previous_name = [name copy];
	previous_rx = rx;
	previous_tx = tx;
	previous_time = now;
	if (!valid)
		return @[unknown, unknown];
	return @[[NSString stringWithFormat:@"%.1f KiB/s", rx_rate / 1024.0],
	         [NSString stringWithFormat:@"%.1f KiB/s", tx_rate / 1024.0]];
}

static NSDateFormatter *
time_formatter(NSString *zone)
{
	NSTimeZone *timezone = [NSTimeZone timeZoneWithName:zone];
	if (!timezone)
		return nil;
	NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
	formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
	formatter.timeZone = timezone;
	formatter.dateFormat = date_format;
	return formatter;
}

int
main(int argc, char **argv)
{
	BOOL stdout_mode = NO, once = NO;
	int option;
	opterr = 0;
	while ((option = getopt(argc, argv, "s1")) != -1) {
		if (option == 's')
			stdout_mode = YES;
		else if (option == '1')
			once = stdout_mode = YES;
		else {
			fprintf(stderr, "usage: %s [-s] [-1]\n", argv[0]);
			return 1;
		}
	}
	if (optind != argc || !interval_ms) {
		fprintf(stderr, "usage: %s [-s] [-1] (interval_ms must be positive)\n", argv[0]);
		return 1;
	}
	struct sigaction action = {0};
	action.sa_handler = handle_signal;
	sigemptyset(&action.sa_mask);
	sigset_t blocked, original;
	sigemptyset(&blocked);
	int signals[] = {SIGINT, SIGTERM, SIGHUP, SIGUSR1};
	for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
		sigaddset(&blocked, signals[i]);
		if (sigaction(signals[i], &action, NULL) < 0) {
			perror("slstatus: sigaction");
			return 1;
		}
	}
	action.sa_handler = SIG_IGN;
	if (sigaction(SIGPIPE, &action, NULL) < 0) {
		perror("slstatus: signals");
		return 1;
	}
	@autoreleasepool {
		NSDateFormatter *berlin = time_formatter(berlin_timezone);
		NSDateFormatter *kolkata = time_formatter(kolkata_timezone);
		if (!berlin || !kolkata) {
			fprintf(stderr, "slstatus: invalid configured timezone\n");
			return 1;
		}
		NSString *path = nil;
		if (!stdout_mode) {
			path = [NSHomeDirectory() stringByAppendingPathComponent:status_relative_path];
			NSError *error = nil;
			if (![[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
			                             withIntermediateDirectories:YES attributes:nil error:&error]) {
				fprintf(stderr, "slstatus: %s\n", error.localizedDescription.UTF8String);
				return 1;
			}
		}
		while (!done) {
			refresh = 0;
			@autoreleasepool {
				NSArray<NSString *> *network = network_usage();
				NSDate *now = [NSDate date];
				NSString *status = [NSString stringWithFormat:status_format,
				    cpu_usage(), ram_usage(), disk_usage(), battery_usage(), network[0], network[1],
				    [berlin stringFromDate:now], [kolkata stringFromDate:now]];
				NSData *data = [[status stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
				if (!data || data.length > 4096) {
					fprintf(stderr, "slstatus: status exceeds dwm's 4096-byte limit or is not UTF-8\n");
					return 1;
				}
				if (stdout_mode) {
					const char *bytes = data.bytes;
					size_t remaining = data.length;
					while (remaining && !done) {
						ssize_t written = write(STDOUT_FILENO, bytes, remaining);
						if (written < 0 && errno == EINTR)
							continue;
						if (written <= 0) {
							if (!written)
								errno = EIO;
							perror("slstatus: stdout");
							return 1;
						}
						bytes += written;
						remaining -= (size_t)written;
					}
				} else if (atomic_write_status(path.fileSystemRepresentation, data.bytes, data.length) < 0) {
					perror("slstatus: status file");
					return 1;
				}
			}
			if (once)
				break;
			struct timespec delay = {interval_ms / 1000, (interval_ms % 1000) * 1000000L};
			/* Block around the flag check; pselect atomically unblocks while waiting. */
			if (sigprocmask(SIG_BLOCK, &blocked, &original) < 0) {
				perror("slstatus: sigprocmask");
				return 1;
			}
			int waited = (done || refresh) ? 0 : pselect(0, NULL, NULL, NULL, &delay, &original);
			int wait_errno = errno;
			if (sigprocmask(SIG_SETMASK, &original, NULL) < 0) {
				perror("slstatus: sigprocmask");
				return 1;
			}
			if (waited < 0 && wait_errno != EINTR) {
				errno = wait_errno;
				perror("slstatus: pselect");
				return 1;
			}
		}
	}
	return 0;
}
