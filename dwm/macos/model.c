#include "model.h"

unsigned
dwm_tags(unsigned current, unsigned requested, int toggle)
{
	unsigned next = (toggle ? current ^ requested : requested) & DWM_TAGMASK;
	return next ? next : current;
}

DwmRect
dwm_tile(DwmRect a, size_t index, size_t count, int masters, double factor)
{
	if (!count || index >= count) return a;
	size_t n = masters > 0 ? (size_t)masters : 0;
	if (n > count) n = count;
	double width = count > n ? (n ? a.w * factor : 0) : a.w;
	if (index < n) {
		a.y += a.h * index / n;
		a.h /= n;
		a.w = width;
	} else {
		a.x += width;
		a.w -= width;
		a.y += a.h * (index - n) / (count - n);
		a.h /= count - n;
	}
	return a;
}

int
dwm_monitor(int current, int direction, int count)
{
	return count > 0 ? ((current + direction) % count + count) % count : 0;
}
