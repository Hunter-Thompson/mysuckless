#ifndef DWM_MAC_MODEL_H
#define DWM_MAC_MODEL_H
#include <stddef.h>

typedef struct { double x, y, w, h; } DwmRect;
#define DWM_TAGMASK 31u
unsigned dwm_tags(unsigned current, unsigned requested, int toggle);
DwmRect dwm_tile(DwmRect area, size_t index, size_t count, int masters, double factor);
int dwm_monitor(int current, int direction, int count);
#endif
