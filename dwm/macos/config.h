/* Native bindings use macOS virtual key codes and Option in place of Mod1. */
static const CGFloat barHeight = 25;
static const BOOL topBar = YES;
static const CGFloat snapDistance = 32;
static const BOOL lockFullscreen = YES;
static NSString *const terminalCommand = @"/usr/bin/open -a Terminal";
static NSString *const launcherCommand = @"/usr/bin/open -a Spotlight";
static NSString *const tagNames[] = {@"1", @"2", @"3", @"4", @"5"};
static NSString *const layoutNames[] = {@"[]=", @"><>", @"[M]"};

static const struct {
	NSString *bundle;
	NSString *title;
	unsigned tags;
	BOOL floating;
	int monitor;
} rules[] = {
	{@"org.gimp.gimp", nil, 0, YES, -1},
};

#define ALT kCGEventFlagMaskAlternate
#define SHIFT kCGEventFlagMaskShift
#define CTRL kCGEventFlagMaskControl
#define TAGKEY(code, mask) \
	{code, ALT, @"view", mask}, \
	{code, ALT|CTRL, @"toggleview", mask}, \
	{code, ALT|SHIFT, @"tag", mask}, \
	{code, ALT|CTRL|SHIFT, @"toggletag", mask}
static const struct {
	CGKeyCode code;
	CGEventFlags modifiers;
	NSString *action;
	int value;
} keys[] = {
	{35, ALT, @"spawn", 0}, {36, ALT|SHIFT, @"spawn", 1},
	{11, ALT, @"togglebar", 0},
	{38, ALT, @"focusstack", 1}, {40, ALT, @"focusstack", -1},
	{34, ALT, @"incnmaster", 1}, {2, ALT, @"incnmaster", -1},
	{4, ALT, @"setmfact", -1}, {37, ALT, @"setmfact", 1},
	{36, ALT, @"zoom", 0}, {48, ALT, @"view", 0},
	{8, ALT|SHIFT, @"killclient", 0},
	{17, ALT, @"setlayout", 0}, {3, ALT, @"setlayout", 1},
	{46, ALT, @"setlayout", 2}, {49, ALT, @"setlayout", -1},
	{49, ALT|SHIFT, @"togglefloating", 0},
	{3, ALT|SHIFT, @"togglefullscr", 0},
	{29, ALT, @"view", DWM_TAGMASK}, {29, ALT|SHIFT, @"tag", DWM_TAGMASK},
	{43, ALT, @"focusmon", -1}, {47, ALT, @"focusmon", 1},
	{43, ALT|SHIFT, @"tagmon", -1}, {47, ALT|SHIFT, @"tagmon", 1},
	TAGKEY(18, 1), TAGKEY(19, 2), TAGKEY(20, 4), TAGKEY(21, 8), TAGKEY(23, 16),
	{12, ALT|SHIFT, @"quit", 0},
};
#undef TAGKEY
