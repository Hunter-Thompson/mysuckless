#include "model.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int near(double a, double b) { return fabs(a-b) < 0.000001; }

int main(void)
{
	assert(dwm_tags(1, 2, 0) == 2);
	assert(dwm_tags(1, 2, 1) == 3);
	assert(dwm_tags(1, 1, 1) == 1);
	assert(dwm_tags(3, 1, 1) == 2);
	assert(dwm_tags(1, ~0u, 0) == DWM_TAGMASK);
	assert(dwm_tags(1, 256, 0) == 1);
	assert(dwm_tags(1, 0, 0) == 1);
	assert(dwm_monitor(0, -1, 3) == 2);
	assert(dwm_monitor(2, 1, 3) == 0);
	assert(dwm_monitor(0, -1, 1) == 0);
	assert(dwm_monitor(0, 1, 0) == 0);
	DwmRect area = {-1920, 25, 1920, 1055};
	DwmRect master = dwm_tile(area, 0, 3, 1, 0.55);
	DwmRect stack = dwm_tile(area, 2, 3, 1, 0.55);
	assert(near(master.w, 1056) && near(master.h, 1055));
	assert(near(stack.x, -864) && near(stack.y, 552.5));
	assert(near(stack.w, 864) && near(stack.h, 527.5));
	for (size_t count = 1; count <= 20; ++count) {
		for (int masters = 0; masters <= 22; ++masters) {
			for (int factor = 5; factor <= 95; factor += 5) {
				double total = 0;
				for (size_t i = 0; i < count; ++i) {
					DwmRect r = dwm_tile(area, i, count, masters, factor/100.0);
					assert(r.w > 0 && r.h > 0);
					assert(r.x >= area.x && r.y >= area.y);
					assert(r.x+r.w <= area.x+area.w+0.000001);
					assert(r.y+r.h <= area.y+area.h+0.000001);
					total += r.w*r.h;
					for (size_t j = 0; j < i; ++j) {
						DwmRect q = dwm_tile(area, j, count, masters, factor/100.0);
						double w = fmin(r.x+r.w, q.x+q.w)-fmax(r.x, q.x);
						double h = fmin(r.y+r.h, q.y+q.h)-fmax(r.y, q.y);
						assert(w < 0.000001 || h < 0.000001);
					}
				}
				assert(near(total, area.w*area.h));
			}
		}
	}
	DwmRect empty = dwm_tile(area, 0, 0, 1, 0.55);
	assert(near(empty.w, area.w));
	puts("PASS: tags, monitor wrap, layout bounds, coverage and non-overlap (8,740 configurations)");
	return 0;
}
