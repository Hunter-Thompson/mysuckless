/* Native macOS configuration. Mirrors ../config.h where the platform allows;
 * key codes are physical ANSI positions and Option replaces Mod1. */

/* appearance */
static const CGFloat barHeight = 25;       /* points */
static const BOOL topBar = YES;
static const CGFloat fontSize = 14;
static const unsigned colNormFG = 0xbbbbbb, colNormBG = 0x222222;
static const unsigned colSelFG = 0xeeeeee, colSelBG = 0x005577;
static const CGFloat snapDistance = 32;
static const BOOL lockFullscreen = YES;    /* keep dwm focus on a fullscreen window */
/* Focus follows mouse. Off by default: on macOS the menu bar and Dock belong
 * to the active application, so crossing windows on the way to a menu would
 * switch applications. Clicking a window focuses it either way. */
static const BOOL sloppyFocus = NO;

/* tagging */
static NSString *const tagNames[] = {@"1", @"2", @"3", @"4", @"5"};

static const struct {
	NSString *bundle;   /* exact bundle identifier or nil */
	NSString *title;    /* title substring or nil */
	unsigned tags;      /* 0 keeps the current view */
	BOOL floating;
	int monitor;        /* -1 keeps the window's monitor */
} rules[] = {
	{@"org.gimp.gimp", nil, 0, YES, -1},
};

/* layouts: index 0 tile, 1 floating, 2 monocle */
static NSString *const layoutNames[] = {@"[]=", @"><>", @"[M]"};

/* commands, run with /bin/sh -c */
static NSString *const terminalCommand = @"/usr/bin/open -a Terminal";
static NSString *const launcherCommand = @"/usr/bin/open -a Spotlight";

/* key definitions */
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
	/* code  modifiers        action            value */
	{35, ALT,            @"spawn",          0},   /* p */
	{36, ALT|SHIFT,      @"spawn",          1},   /* return */
	{11, ALT,            @"togglebar",      0},   /* b */
	{38, ALT,            @"focusstack",     1},   /* j */
	{40, ALT,            @"focusstack",    -1},   /* k */
	{34, ALT,            @"incnmaster",     1},   /* i */
	{2,  ALT,            @"incnmaster",    -1},   /* d */
	{4,  ALT,            @"setmfact",      -1},   /* h */
	{37, ALT,            @"setmfact",       1},   /* l */
	{36, ALT,            @"zoom",           0},   /* return */
	{48, ALT,            @"view",           0},   /* tab */
	{8,  ALT|SHIFT,      @"killclient",     0},   /* c */
	{17, ALT,            @"setlayout",      0},   /* t */
	{3,  ALT,            @"setlayout",      1},   /* f */
	{46, ALT,            @"setlayout",      2},   /* m */
	{49, ALT,            @"setlayout",     -1},   /* space */
	{49, ALT|SHIFT,      @"togglefloating", 0},   /* space */
	{3,  ALT|SHIFT,      @"togglefullscr",  0},   /* f */
	{29, ALT,            @"view",           DWM_TAGMASK}, /* 0 */
	{29, ALT|SHIFT,      @"tag",            DWM_TAGMASK}, /* 0 */
	{43, ALT,            @"focusmon",      -1},   /* comma */
	{47, ALT,            @"focusmon",       1},   /* period */
	{43, ALT|SHIFT,      @"tagmon",        -1},   /* comma */
	{47, ALT|SHIFT,      @"tagmon",         1},   /* period */
	TAGKEY(18, 1), TAGKEY(19, 2), TAGKEY(20, 4), TAGKEY(21, 8), TAGKEY(23, 16),
	{12, ALT|SHIFT,      @"quit",           0},   /* q */
};
#undef TAGKEY
