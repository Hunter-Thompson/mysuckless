/* Native macOS configuration. Mirrors ../../dwm/config.h where the platform allows;
 * key codes are physical ANSI positions and Command replaces Mod1. */

/* appearance */
static const CGFloat barHeight = 25;       /* points */
static const BOOL topBar = YES;
/* Points reserved at the top of every display for the macOS menu bar.
 * -1: detect (menu bar height, or 0 when it is set to hide automatically).
 *  0: menu bar hidden, use the whole display (a notch is always respected).
 *  n: reserve n points. */
static const CGFloat menuBarInset = -1;
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

/* commands, run with /bin/sh -c; spawn's value indexes this array */
static NSString *const commands[] = {@"/usr/bin/open -a Terminal"};
/* launcher: dwm presses this system shortcut itself (Cmd-Space opens Spotlight;
 * set it to whatever hotkey Raycast, Alfred etc. use) */
static const CGKeyCode launcherKey = 49;
static const CGEventFlags launcherModifiers = kCGEventFlagMaskCommand;

/* key definitions */
#define MODKEY kCGEventFlagMaskCommand
#define SHIFT kCGEventFlagMaskShift
#define CTRL kCGEventFlagMaskControl
#define TAGKEY(code, mask) \
	{code, MODKEY, @"view", mask}, \
	{code, MODKEY|CTRL, @"toggleview", mask}, \
	{code, MODKEY|SHIFT, @"tag", mask}, \
	{code, MODKEY|CTRL|SHIFT, @"toggletag", mask}
static const struct {
	CGKeyCode code;
	CGEventFlags modifiers;
	NSString *action;
	int value;
} keys[] = {
	/* code  modifiers        action            value */
	{35, MODKEY,            @"launcher",       0},   /* p */
	{36, MODKEY|SHIFT,      @"spawn",          0},   /* return: commands[0] */
	{11, MODKEY,            @"togglebar",      0},   /* b */
	{38, MODKEY,            @"focusstack",     1},   /* j */
	{40, MODKEY,            @"focusstack",    -1},   /* k */
	{34, MODKEY,            @"incnmaster",     1},   /* i */
	{2,  MODKEY,            @"incnmaster",    -1},   /* d */
	{4,  MODKEY,            @"setmfact",      -1},   /* h */
	{37, MODKEY,            @"setmfact",       1},   /* l */
	{36, MODKEY,            @"zoom",           0},   /* return */
	{48, MODKEY,            @"view",           0},   /* tab */
	{8,  MODKEY|SHIFT,      @"killclient",     0},   /* c */
	{17, MODKEY,            @"setlayout",      0},   /* t */
	{3,  MODKEY,            @"setlayout",      1},   /* f */
	{46, MODKEY,            @"setlayout",      2},   /* m */
	{49, MODKEY,            @"setlayout",     -1},   /* space */
	{49, MODKEY|SHIFT,      @"togglefloating", 0},   /* space */
	{3,  MODKEY|SHIFT,      @"togglefullscr",  0},   /* f */
	{29, MODKEY,            @"view",           DWM_TAGMASK}, /* 0 */
	{29, MODKEY|SHIFT,      @"tag",            DWM_TAGMASK}, /* 0 */
	{43, MODKEY,            @"focusmon",      -1},   /* comma */
	{47, MODKEY,            @"focusmon",       1},   /* period */
	{43, MODKEY|SHIFT,      @"tagmon",        -1},   /* comma */
	{47, MODKEY|SHIFT,      @"tagmon",         1},   /* period */
	TAGKEY(18, 1), TAGKEY(19, 2), TAGKEY(20, 4), TAGKEY(21, 8), TAGKEY(23, 16),
	{12, MODKEY|SHIFT,      @"quit",           0},   /* q */
};
#undef TAGKEY
