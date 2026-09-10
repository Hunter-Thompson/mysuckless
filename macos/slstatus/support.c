#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "support.h"

double
cpu_percent(const uint32_t previous[4], const uint32_t current[4])
{
	uint64_t total = 0, idle = 0;
	for (size_t i = 0; i < 4; i++) {
		uint32_t delta = current[i] - previous[i];
		total += delta;
		if (i == 2)
			idle = delta;
	}
	return total ? 100.0 * (double)(total - idle) / (double)total : -1.0;
}

int
network_rates(uint64_t previous_rx, uint64_t previous_tx,
              uint64_t rx, uint64_t tx, double seconds,
              double *rx_rate, double *tx_rate)
{
	if (seconds <= 0 || rx < previous_rx || tx < previous_tx)
		return 0;
	*rx_rate = (double)(rx - previous_rx) / seconds;
	*tx_rate = (double)(tx - previous_tx) / seconds;
	return 1;
}

int
atomic_write_status(const char *path, const void *data, size_t length)
{
	char *temporary = malloc(strlen(path) + sizeof(".XXXXXX"));
	if (!temporary)
		return -1;
	sprintf(temporary, "%s.XXXXXX", path);
	int fd = mkstemp(temporary);
	if (fd < 0) {
		free(temporary);
		return -1;
	}
	int result = 0;
	const char *bytes = data;
	while (length) {
		ssize_t written = write(fd, bytes, length);
		if (written < 0 && errno == EINTR)
			continue;
		if (written <= 0) {
			if (!written)
				errno = EIO;
			result = -1;
			break;
		}
		bytes += written;
		length -= (size_t)written;
	}
	int saved_errno = errno;
	if (close(fd) < 0 && !result) {
		result = -1;
		saved_errno = errno;
	}
	if (!result && rename(temporary, path) < 0) {
		result = -1;
		saved_errno = errno;
	}
	if (result)
		unlink(temporary);
	free(temporary);
	errno = saved_errno;
	return result;
}
