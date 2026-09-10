#ifndef SLSTATUS_SUPPORT_H
#define SLSTATUS_SUPPORT_H

#include <stddef.h>
#include <stdint.h>

double cpu_percent(const uint32_t previous[4], const uint32_t current[4]);
int network_rates(uint64_t previous_rx, uint64_t previous_tx,
                  uint64_t rx, uint64_t tx, double seconds,
                  double *rx_rate, double *tx_rate);
int atomic_write_status(const char *path, const void *data, size_t length);

#endif
