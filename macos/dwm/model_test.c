#include "model.h"
#include <assert.h>
#include <math.h>
#include <stdio.h>

static int near(double a, double b) { return fabs(a-b) < 0.000001; }
static int whole(double v) { return near(v, floor(v)); }

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
	assert(near(dwm_factor(1000, 550, 1), 0.55));
	assert(near(dwm_factor(1000, 450, 0), 0.55));
	assert(near(dwm_factor(1000, 10, 1), 0.05));
	assert(near(dwm_factor(1000, 990, 1), 0.95));
	assert(near(dwm_factor(0, 10, 1), 0.55));
	/* the same numbers dwm's tile() computes with its integer arithmetic */
	DwmRect area = {-1920, 25, 1920, 1055};
	DwmRect master = dwm_tile(area, 0, 3, 1, 0.55);
	DwmRect stack1 = dwm_tile(area, 1, 3, 1, 0.55);
	DwmRect stack2 = dwm_tile(area, 2, 3, 1, 0.55);
	assert(near(master.x, -1920) && near(master.y, 25) && near(master.w, 1056) && near(master.h, 1055));
	assert(near(stack1.x, -864) && near(stack1.y, 25) && near(stack1.w, 864) && near(stack1.h, 527));
	assert(near(stack2.x, -864) && near(stack2.y, 552) && near(stack2.w, 864) && near(stack2.h, 528));
	/* no masters: one column; more masters than clients: one column too */
	DwmRect only = dwm_tile(area, 0, 2, 0, 0.55);
	assert(near(only.x, area.x) && near(only.w, area.w) && near(only.h, 527));
	DwmRect all = dwm_tile(area, 1, 2, 5, 0.55);
	assert(near(all.x, area.x) && near(all.w, area.w) && near(all.y, 552) && near(all.h, 528));
	DwmRect odd[] = {{0, 0, 1512, 957}, {-1920, 25, 1920, 1055}, {1512, -200, 1000, 601}, {0, 25, 7, 5}};
	for (size_t o = 0; o < sizeof(odd) / sizeof(odd[0]); ++o) {
		area = odd[o];
		for (size_t count = 1; count <= 20; ++count) {
			for (int masters = 0; masters <= 22; ++masters) {
				for (int factor = 5; factor <= 95; factor += 5) {
					double total = 0;
					for (size_t i = 0; i < count; ++i) {
						DwmRect r = dwm_tile(area, i, count, masters, factor/100.0);
						assert(whole(r.x) && whole(r.y) && whole(r.w) && whole(r.h));
						assert(r.w >= 0 && r.h >= 0);
						assert(r.x >= area.x && r.y >= area.y);
						assert(r.x+r.w <= area.x+area.w+0.000001);
						assert(r.y+r.h <= area.y+area.h+0.000001);
						if (count <= 5 && area.w > 100) assert(r.w > 0 && r.h > 0);
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
	}
	DwmRect empty = dwm_tile(area, 0, 0, 1, 0.55);
	assert(near(empty.w, area.w));
	puts("PASS: tags, monitor wrap, master factor, integral tiles with exact coverage and no overlap (34,960 configurations)");
	return 0;
}
