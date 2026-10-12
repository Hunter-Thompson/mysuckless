#include "model.h"
#include <math.h>

unsigned
dwm_tags(unsigned current, unsigned requested, int toggle)
{
	unsigned next = (toggle ? current ^ requested : requested) & DWM_TAGMASK;
	return next ? next : current;
}

/* dwm's tile(): the master column is floor(w * factor) wide and each column is
 * split by repeated integer division, so the last client takes the remainder and
 * tiles meet exactly on whole points without gaps or overlaps. The area must be
 * integral. */
DwmRect
dwm_tile(DwmRect a, size_t index, size_t count, int masters, double factor)
{
	if (!count || index >= count) return a;
	size_t n = masters > 0 ? (size_t)masters : 0;
	if (n > count) n = count;
	double mw = count > n ? (n ? floor(a.w * factor) : 0) : a.w;
	DwmRect r = a;
	double y = 0;
	if (index < n) {
		for (size_t i = 0; i < index; ++i) y += floor((a.h - y) / (double)(n - i));
		r.w = mw;
		r.h = floor((a.h - y) / (double)(n - index));
	} else {
		for (size_t i = n; i < index; ++i) y += floor((a.h - y) / (double)(count - i));
		r.x = a.x + mw;
		r.w = a.w - mw;
		r.h = floor((a.h - y) / (double)(count - index));
	}
	r.y = a.y + y;
	return r;
}

/* the master factor that gives a column this width, within dwm's 0.05..0.95 */
double
dwm_factor(double areaWidth, double width, int master)
{
	if (areaWidth <= 0) return 0.55;
	double f = master ? width / areaWidth : 1 - width / areaWidth;
	return fmax(0.05, fmin(0.95, f));
}

int
dwm_monitor(int current, int direction, int count)
{
	return count > 0 ? ((current + direction) % count + count) % count : 0;
}
