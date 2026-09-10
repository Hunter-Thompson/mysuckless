/* See LICENSE file for copyright and license details. */
static const unsigned int interval_ms = 1000;
static NSString *const unknown = @"n/a";
static NSString *const network_interface = @""; /* Empty: primary IPv4, then IPv6. */
static NSString *const disk_path = @"/";
static NSString *const status_relative_path = @"Library/Application Support/dwm/status";
static NSString *const berlin_timezone = @"Europe/Berlin";
static NSString *const kolkata_timezone = @"Asia/Kolkata";
static NSString *const date_format = @"yyyy-MM-dd HH:mm:ss";
/* Arguments: CPU, RAM, disk used, battery, RX, TX, Berlin time, Kolkata time. */
static NSString *const status_format =
    @"CPU %@ | RAM %@ | DISK %@ | BAT %@ | RX %@ | TX %@ | BER %@ | IST %@";
