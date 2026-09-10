#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
/* Darwin hides mkdtemp in its strict POSIX namespace. */
#define _DARWIN_C_SOURCE
#endif
#include <assert.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#include "support.h"

static void
test_metrics(void)
{
	uint32_t previous[4] = {100, 100, 100, 100};
	uint32_t current[4] = {120, 110, 160, 110};
	assert(cpu_percent(previous, current) == 40.0);
	assert(cpu_percent(current, current) < 0);
	uint32_t wrapped_before[4] = {UINT32_MAX - 9, 0, UINT32_MAX - 9, 0};
	uint32_t wrapped_after[4] = {10, 0, 10, 0};
	assert(cpu_percent(wrapped_before, wrapped_after) == 50.0);
	uint32_t idle[4] = {100, 100, 200, 100};
	assert(cpu_percent(previous, idle) == 0.0);
	uint32_t busy[4] = {200, 100, 100, 100};
	assert(cpu_percent(previous, busy) == 100.0);
	double rx, tx;
	assert(network_rates(100, 200, 2148, 1224, 2, &rx, &tx));
	assert(rx == 1024 && tx == 512);
	assert(network_rates(0, 0, UINT64_C(1) << 33, UINT64_C(1) << 34, 1, &rx, &tx));
	assert(rx == 8589934592.0 && tx == 17179869184.0);
	assert(!network_rates(100, 200, 99, 300, 1, &rx, &tx));
	assert(!network_rates(100, 200, 300, 199, 1, &rx, &tx));
	assert(!network_rates(0, 0, 1, 1, 0, &rx, &tx));
	assert(!network_rates(0, 0, 1, 1, -1, &rx, &tx));
	assert(network_rates(100, 200, 100, 200, 1, &rx, &tx));
	assert(rx == 0 && tx == 0);
}

static void
test_atomic_file(void)
{
	char directory[] = "./slstatus-test.XXXXXX";
	assert(mkdtemp(directory));
	char path[128], missing[128];
	snprintf(path, sizeof(path), "%s/status", directory);
	snprintf(missing, sizeof(missing), "%s/missing/status", directory);
	assert(atomic_write_status(missing, "x", 1) == -1 && errno == ENOENT);
	assert(atomic_write_status(path, "old\n", 4) == 0);
	int old = open(path, O_RDONLY);
	assert(old >= 0);
	const char replacement[] = "new UTF-8: \342\206\223\n";
	assert(atomic_write_status(path, replacement, sizeof(replacement) - 1) == 0);
	char buffer[4096];
	assert(read(old, buffer, sizeof(buffer)) == 4 && memcmp(buffer, "old\n", 4) == 0);
	assert(close(old) == 0);
	int fresh = open(path, O_RDONLY);
	assert(fresh >= 0);
	assert(read(fresh, buffer, sizeof(buffer)) == (ssize_t)sizeof(replacement) - 1);
	assert(memcmp(buffer, replacement, sizeof(replacement) - 1) == 0);
	struct stat st;
	assert(fstat(fresh, &st) == 0 && (st.st_mode & 0777) == 0600);
	assert(close(fresh) == 0);

	memset(buffer, 'a', sizeof(buffer));
	assert(atomic_write_status(path, buffer, sizeof(buffer)) == 0);
	pid_t child = fork();
	assert(child >= 0);
	if (!child) {
		for (int i = 0; i < 200; i++) {
			memset(buffer, i % 2 ? 'a' : 'b', sizeof(buffer));
			assert(atomic_write_status(path, buffer, sizeof(buffer)) == 0);
		}
		_exit(0);
	}
	for (int i = 0; i < 1000; i++) {
		fresh = open(path, O_RDONLY);
		assert(fresh >= 0);
		assert(read(fresh, buffer, sizeof(buffer)) == (ssize_t)sizeof(buffer));
		assert(buffer[0] == 'a' || buffer[0] == 'b');
		for (size_t j = 1; j < sizeof(buffer); j++)
			assert(buffer[j] == buffer[0]);
		assert(close(fresh) == 0);
	}
	int status;
	assert(waitpid(child, &status, 0) == child && WIFEXITED(status) && WEXITSTATUS(status) == 0);
	assert(atomic_write_status(path, "", 0) == 0);
	assert(stat(path, &st) == 0 && st.st_size == 0);
	assert(unlink(path) == 0);
	assert(mkdir(path, 0700) == 0);
	assert(atomic_write_status(path, "cannot replace directory", 24) == -1);
	assert(rmdir(path) == 0);
	DIR *dir = opendir(directory);
	assert(dir);
	struct dirent *entry;
	while ((entry = readdir(dir)))
		assert(!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."));
	assert(closedir(dir) == 0);
	assert(rmdir(directory) == 0);
}

int
main(void)
{
	test_metrics();
	test_atomic_file();
	puts("support tests passed: CPU wrap/deltas, network rates/resets, atomic replacement and cleanup");
	return 0;
}
