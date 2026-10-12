/* dwm for native macOS windows. See LICENSE file for copyright and license details.
 *
 * Windows are driven through the public Accessibility API, input arrives through
 * a CoreGraphics event tap, and the on-screen window list from CoreGraphics is
 * used for hit testing and to know which windows are on the current Space.
 * Windows on hidden tags are parked one point inside a bottom corner of a
 * display, the way dwm parks them off the X screen. */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>
#import <dispatch/dispatch.h>
#import <fcntl.h>
#import <math.h>
#import <signal.h>
#import <sys/file.h>
#import <sys/stat.h>
#import <unistd.h>
#import "model.h"
#import "config.h"

#define LENGTH(x) (sizeof(x) / sizeof((x)[0]))
#define LOG(...) do { if (verbose) NSLog(__VA_ARGS__); } while (0)
enum { Tile, Float, Monocle };
enum { AxRole, AxSubrole, AxPosition, AxSize, AxTitle, AxMinimized, AxFullScreen, AxCount };
_Static_assert((1u << LENGTH(tagNames)) - 1 == DWM_TAGMASK, "tagNames must match DWM_TAGMASK");
_Static_assert(LENGTH(layoutNames) == 3, "three layouts: tile, float, monocle");

static BOOL verbose;
static const int64_t ownEvent = 0x64776d;   /* "dwm": marks events dwm posts itself */
static NSString *const supportPath = @"Library/Application Support/dwm";

static id attribute(AXUIElementRef element, CFStringRef name)
{
	CFTypeRef value = NULL;
	if (!element || AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
	return CFBridgingRelease(value);
}

/* the window attributes dwm reads, fetched in one round trip; nil when the
 * window is gone or its application does not answer */
static NSArray *attributes(AXUIElementRef element)
{
	static CFArrayRef names;
	if (!names) {
		const void *list[AxCount] = {kAXRoleAttribute, kAXSubroleAttribute, kAXPositionAttribute, kAXSizeAttribute,
			kAXTitleAttribute, kAXMinimizedAttribute, CFSTR("AXFullScreen")};
		names = CFArrayCreate(NULL, list, AxCount, &kCFTypeArrayCallBacks);
	}
	CFArrayRef values = NULL;
	if (!element || AXUIElementCopyMultipleAttributeValues(element, names, 0, &values) != kAXErrorSuccess || !values) return nil;
	NSArray *result = CFBridgingRelease(values);
	return result.count == AxCount ? result : nil;
}

/* one entry of attributes(): nil when the window lacks the attribute */
static id entry(NSArray *values, NSUInteger index)
{
	if (!values) return nil;
	id v = values[index];
	if (v == (id)kCFNull) return nil;
	if (CFGetTypeID((__bridge CFTypeRef)v) == AXValueGetTypeID() && AXValueGetType((__bridge AXValueRef)v) == kAXValueTypeAXError) return nil;
	return v;
}

static BOOL axValue(id v, AXValueType type, void *out)
{
	return v && CFGetTypeID((__bridge CFTypeRef)v) == AXValueGetTypeID() && AXValueGetValue((__bridge AXValueRef)v, type, out);
}

static DwmRect frameOf(NSArray *values)
{
	CGPoint p;
	CGSize s;
	if (!axValue(entry(values, AxPosition), kAXValueTypeCGPoint, &p) || !axValue(entry(values, AxSize), kAXValueTypeCGSize, &s)) return (DwmRect){0, 0, 0, 0};
	return (DwmRect){p.x, p.y, s.width, s.height};
}

static DwmRect geometry(AXUIElementRef element)
{
	return frameOf(attributes(element));
}

static BOOL setAttribute(AXUIElementRef element, CFStringRef name, id value)
{
	return element && AXUIElementSetAttributeValue(element, name, (__bridge CFTypeRef)value) == kAXErrorSuccess;
}

static BOOL setPosition(AXUIElementRef element, CGPoint p)
{
	AXValueRef value = AXValueCreate(kAXValueTypeCGPoint, &p);
	BOOL ok = element && AXUIElementSetAttributeValue(element, kAXPositionAttribute, value) == kAXErrorSuccess;
	CFRelease(value);
	return ok;
}

static BOOL setSize(AXUIElementRef element, CGSize s)
{
	AXValueRef value = AXValueCreate(kAXValueTypeCGSize, &s);
	BOOL ok = element && AXUIElementSetAttributeValue(element, kAXSizeAttribute, value) == kAXErrorSuccess;
	CFRelease(value);
	return ok;
}

static BOOL same(DwmRect a, DwmRect b)
{
	return fabs(a.x - b.x) < 1 && fabs(a.y - b.y) < 1 && fabs(a.w - b.w) < 1 && fabs(a.h - b.h) < 1;
}

static DwmRect integral(DwmRect r)
{
	r.x = round(r.x); r.y = round(r.y);
	r.w = MAX(1, round(r.w)); r.h = MAX(1, round(r.h));
	return r;
}

static CGRect cg(DwmRect r)
{
	return CGRectMake(r.x, r.y, r.w, r.h);
}

static double overlap(DwmRect a, DwmRect b)
{
	CGRect i = CGRectIntersection(cg(a), cg(b));
	return CGRectIsNull(i) ? 0 : i.size.width * i.size.height;
}

/* one entry of CGWindowListCopyWindowInfo: ordinary (layer 0) visible windows only */
static BOOL windowInfo(NSDictionary *info, pid_t *pid, uint32_t *number, CGRect *bounds)
{
	if ([info[(__bridge NSString *)kCGWindowLayer] intValue] != 0) return NO;
	if ([info[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) return NO;
	*pid = [info[(__bridge NSString *)kCGWindowOwnerPID] intValue];
	*number = [info[(__bridge NSString *)kCGWindowNumber] unsignedIntValue];
	return CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], bounds);
}

static BOOL matches(DwmRect r, CGRect b)
{
	return fabs(r.x - b.origin.x) < 2 && fabs(r.y - b.origin.y) < 2 && fabs(r.w - b.size.width) < 2 && fabs(r.h - b.size.height) < 2;
}

static BOOL preference(CFStringRef domain, CFStringRef key)
{
	Boolean exists = false;
	Boolean on = CFPreferencesGetAppBooleanValue(key, domain, &exists);
	return exists && on;
}

/* the menu bar auto-hide setting; visibleFrame does not reflect it */
static BOOL menuBarAutoHides(void)
{
	return preference(kCFPreferencesAnyApplication, CFSTR("_HIHideMenuBar"));
}

static NSColor *color(unsigned rgb)
{
	return [NSColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

static NSTimeInterval now(void)
{
	return [NSDate timeIntervalSinceReferenceDate];
}

@class Manager, Monitor;
@interface Client : NSObject
@property AXUIElementRef element;
@property pid_t pid;
@property uint32_t number;        /* CoreGraphics window id */
@property unsigned tags;
@property BOOL floating, fixed, fullscreen, wasFloating;
@property BOOL hidden;            /* parked in a display corner by dwm */
@property BOOL away;              /* minimized, application hidden or on another Space */
@property BOOL nativeFullscreen;  /* in a macOS fullscreen Space; never touched */
@property BOOL geometryFailed, stubborn;
@property int fights;             /* times its application pulled it out of the corner */
@property DwmRect frame;          /* current frame, or the frame to restore while hidden */
@property DwmRect requested;      /* geometry dwm asked for last */
@property DwmRect applied;        /* geometry the window took after that request */
@property DwmRect drift;          /* geometry the window chose for itself afterwards */
@property DwmRect parked;         /* geometry while hidden */
@property DwmRect saved;          /* frame before fullscreen */
@property(strong) NSString *title, *application;
@property(weak) Monitor *monitor;
@end
@implementation Client
- (void)dealloc { if (_element) CFRelease(_element); }
@end

@interface Bar : NSView
@property(weak) Manager *manager;
@property(weak) Monitor *monitor;
@end

/* AppKit keeps windows out of the menu bar and notch strip; the bar may go there.
 * It never takes keyboard focus away from the application being used. */
@interface BarPanel : NSPanel
@end
@implementation BarPanel
- (NSRect)constrainFrameRect:(NSRect)frameRect toScreen:(NSScreen *)screen { (void)screen; return frameRect; }
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface Monitor : NSObject
@property(strong) NSNumber *display;
@property NSRect visible;          /* visibleFrame the work area was computed from */
@property DwmRect frame, work;     /* CoreGraphics coordinates, origin top-left */
@property DwmRect bar;             /* bar frame when it lives beside a notch */
@property BOOL notchBar;           /* bar sits in the notch strip, not in the work area */
@property CGFloat gapStart, gapEnd; /* notch, in bar coordinates */
@property unsigned tags, previousTags;
@property int layout, previousLayout, masters;
@property double factor;
@property BOOL showbar;
@property(strong) NSMutableArray<Client *> *clients;   /* tiling order */
@property(strong) NSMutableArray<Client *> *history;   /* focus order */
@property(weak) Client *selected;
@property(strong) NSPanel *panel;
@end
@implementation Monitor
- (instancetype)init
{
	if ((self = [super init])) {
		_tags = _previousTags = 1;
		_previousLayout = Float;
		_masters = 1;
		_factor = 0.55;
		_showbar = YES;
		_clients = [NSMutableArray array];
		_history = [NSMutableArray array];
	}
	return self;
}
@end

@interface ApplicationWatch : NSObject
@property AXUIElementRef element;
@property AXObserverRef observer;
@property BOOL registered;                /* every notification is in place */
@property NSTimeInterval retryAt, busyUntil, backoff;
@property(strong) NSMutableSet *ignored;  /* elements that turned out not to be windows */
@end
@implementation ApplicationWatch
- (instancetype)init
{
	if ((self = [super init])) { _ignored = [NSMutableSet set]; _backoff = 0.5; }
	return self;
}
- (void)dealloc
{
	if (_observer) {
		CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(_observer), kCFRunLoopCommonModes);
		CFRelease(_observer);
	}
	if (_element) CFRelease(_element);
}
@end

@interface Manager : NSObject <NSApplicationDelegate>
@property(strong) NSMutableArray<Monitor *> *monitors;   /* left to right */
@property(strong) NSMutableDictionary<NSNumber *, ApplicationWatch *> *watches;
@property(strong) NSArray<NSDictionary *> *windows;   /* on-screen windows, front to back */
@property(weak) Monitor *selected;
@property(weak) Client *osFocused;   /* managed window macOS reported focused at the last sync */
@property(weak) Client *wanted;      /* window dwm asked macOS to focus last */
@property(weak) Client *hovered;
@property(strong) Client *dragClient;   /* moved or resized with MOUSEMOD */
@property(strong) Client *pressClient;  /* under a plain left button press */
@property(strong) NSString *status;
@property(strong) NSTimer *timer;
@property(strong) NSMutableDictionary *state;          /* tags and frames by window; survives restarts */
@property(strong) NSMutableSet<NSNumber *> *animated;  /* applications whose window animations are paused */
@property CFMachPortRef tap;
@property CFRunLoopSourceRef tapSource;
@property AXUIElementRef systemElement;
@property(strong) NSMutableIndexSet *heldKeys;
@property CGPoint dragStart, dragPoint, pointer;
@property DwmRect dragFrame;
@property CGFloat top;   /* height of the primary display, converts CG and AppKit y */
@property NSTimeInterval quietUntil;
@property int dragButton, lockFD, focusTries, trustChecks;
@property unsigned buttons;   /* mouse buttons held, seen by the event tap */
@property BOOL pointerPending, dragPending, syncPending, stopping, waiting, menuBarHidden;
@property BOOL locked, secureInput, pressDragged, selectionLost, stateDirty, restoreOnly, started;
@property(strong) dispatch_source_t interruptSource, terminateSource, hangupSource;
- (void)scheduleSync;
- (void)sync;
- (void)arrange;
- (void)focus:(Client *)client raise:(BOOL)raise;
- (void)action:(NSString *)name value:(int)value;
- (NSArray<Client *> *)visible:(Monitor *)m tiled:(BOOL)tiled;
- (CGEventRef)event:(CGEventRef)event type:(CGEventType)type;
- (void)tapReset;
@end

static void observed(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context)
{
	(void)observer; (void)element; (void)notification;
	[(__bridge Manager *)context scheduleSync];
}

static CGEventRef input(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context)
{
	(void)proxy;
	Manager *manager = (__bridge Manager *)context;
	if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
		CGEventTapEnable(manager.tap, true);
		[manager tapReset];
		return event;
	}
	return [manager event:event type:type];
}

@implementation Manager
- (NSString *)statePath
{
	return [NSHomeDirectory() stringByAppendingPathComponent:[supportPath stringByAppendingPathComponent:@"state.plist"]];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	(void)notification;
	self.lockFD = -1;
	NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:supportPath];
	NSError *error = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Cannot create %@: %@", support, error);
		[NSApp terminate:nil];
		return;
	}
	if (!self.restoreOnly) {
		self.lockFD = open([[support stringByAppendingPathComponent:@"lock"] fileSystemRepresentation], O_CREAT|O_RDWR, 0600);
		if (self.lockFD < 0 || flock(self.lockFD, LOCK_EX|LOCK_NB) != 0) {
			NSLog(@"dwm is already running");
			[NSApp terminate:nil];
			return;
		}
	}
	self.monitors = [NSMutableArray array];
	self.watches = [NSMutableDictionary dictionary];
	self.heldKeys = [NSMutableIndexSet indexSet];
	self.animated = [NSMutableSet set];
	self.windows = @[];
	self.status = @"dwm";
	NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:[self statePath]];
	self.state = [NSMutableDictionary dictionary];
	self.state[@"windows"] = [NSMutableDictionary dictionaryWithDictionary:saved[@"windows"]];
	self.state[@"monitors"] = [NSMutableDictionary dictionaryWithDictionary:saved[@"monitors"]];
	[self start];
}

/* Waits for the permissions instead of exiting: grant them in System Settings
 * and dwm picks up within a second, without a restart. */
- (void)start
{
	NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: self.waiting ? @NO : @YES};
	if (!self.systemElement) self.systemElement = AXUIElementCreateSystemWide();
	if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
		/* macOS 26 has answered no to signed binaries it does trust: after a while, ask
		 * the accessibility server itself */
		if (self.trustChecks++ < 5 || !attribute(self.systemElement, kAXFocusedApplicationAttribute)) {
			if (!self.waiting) NSLog(@"Waiting for Accessibility access (System Settings > Privacy & Security > Accessibility)");
			self.waiting = YES;
			[self performSelector:@selector(start) withObject:nil afterDelay:1];
			return;
		}
		NSLog(@"Accessibility works although macOS reports it is not granted; going on");
	}
	/* global AX timeout: an unresponsive application must not stall the manager */
	AXUIElementSetMessagingTimeout(self.systemElement, 0.25);
	if (self.restoreOnly) {
		[self screensChanged:nil];
		[self restoreParked];
		[NSApp terminate:nil];
		return;
	}
	CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|
		CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|
		CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|
		CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|
		CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged)|CGEventMaskBit(kCGEventOtherMouseDragged);
	if (sloppyFocus) mask |= CGEventMaskBit(kCGEventMouseMoved);
	self.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, input, (__bridge void *)self);
	if (!self.tap) {
		if (!self.waiting) NSLog(@"Waiting for input access (System Settings > Privacy & Security > Input Monitoring)");
		self.waiting = YES;
		[self performSelector:@selector(start) withObject:nil afterDelay:1];
		return;
	}
	self.waiting = NO;
	self.tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
	CFRunLoopAddSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes);
	if (preference(CFSTR("com.apple.WindowManager"), CFSTR("GloballyEnabled")))
		NSLog(@"Stage Manager is on and will rearrange windows behind dwm's back (System Settings > Desktop & Dock)");
	Boolean set = false;
	if (CFPreferencesGetAppBooleanValue(CFSTR("EnableTilingByEdgeDrag"), CFSTR("com.apple.WindowManager"), &set) || !set)
		NSLog(@"macOS tiles windows dragged to a display edge (dwm puts them back); turn it off with: defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool false");
	NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
	for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification,
			NSWorkspaceDidActivateApplicationNotification, NSWorkspaceDidHideApplicationNotification,
			NSWorkspaceDidUnhideApplicationNotification, NSWorkspaceActiveSpaceDidChangeNotification])
		[workspace addObserver:self selector:@selector(scheduleSyncNotification:) name:name object:nil];
	for (NSNotificationName name in @[NSWorkspaceDidWakeNotification, NSWorkspaceScreensDidWakeNotification])
		[workspace addObserver:self selector:@selector(screensChanged:) name:name object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
	/* the lock screen answers every AX query with nothing; stop looking until it is gone */
	NSDistributedNotificationCenter *distributed = NSDistributedNotificationCenter.defaultCenter;
	[distributed addObserver:self selector:@selector(screenLocked:) name:@"com.apple.screenIsLocked" object:nil];
	[distributed addObserver:self selector:@selector(screenUnlocked:) name:@"com.apple.screenIsUnlocked" object:nil];
	[self screensChanged:nil];
	self.timer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
	[self sync];
	/* a closed terminal (SIGHUP) must restore the windows like Ctrl-C does */
	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);
	signal(SIGHUP, SIG_IGN);
	self.interruptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
	self.terminateSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
	self.hangupSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGHUP, 0, dispatch_get_main_queue());
	for (dispatch_source_t source in @[self.interruptSource, self.terminateSource, self.hangupSource]) {
		dispatch_source_set_event_handler(source, ^{ [NSApp terminate:nil]; });
		dispatch_resume(source);
	}
}

- (void)scheduleSyncNotification:(NSNotification *)notification
{
	(void)notification;
	[self scheduleSync];
}

- (void)screenLocked:(NSNotification *)notification
{
	(void)notification;
	self.locked = YES;
}

- (void)screenUnlocked:(NSNotification *)notification
{
	(void)notification;
	self.locked = NO;
	[self scheduleSync];
}

/* coalesces bursts of notifications into one reconciliation */
- (void)scheduleSync
{
	if (self.syncPending || self.stopping) return;
	self.syncPending = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
		if (!self.stopping) [self sync];
	});
}

- (void)screensChanged:(NSNotification *)notification
{
	(void)notification;
	NSMutableArray *next = [NSMutableArray array];
	self.top = NSMaxY(NSScreen.screens.firstObject.frame);
	BOOL menuBarHidden = self.menuBarHidden = menuBarAutoHides();
	for (NSScreen *screen in NSScreen.screens) {
		NSNumber *display = screen.deviceDescription[@"NSScreenNumber"];
		Monitor *m = nil;
		for (Monitor *existing in self.monitors) if ([existing.display isEqual:display]) m = existing;
		if (!m) {
			m = [Monitor new];
			m.display = display;
			[self restoreMonitor:m];
		}
		CGRect frame = CGDisplayBounds(display.unsignedIntValue);
		m.frame = (DwmRect){frame.origin.x, frame.origin.y, frame.size.width, frame.size.height};
		NSRect visible = m.visible = screen.visibleFrame;   /* excludes menu bar, notch and Dock */
		CGFloat inset = menuBarInset;
		if (inset < 0 && menuBarHidden) inset = 0;   /* visibleFrame keeps reserving an auto-hidden menu bar */
		if (inset >= 0) {
			CGFloat top = NSMaxY(screen.frame) - inset;
			if (@available(macOS 12.0, *)) top = MIN(top, NSMaxY(screen.frame) - screen.safeAreaInsets.top);
			visible.size.height = top - visible.origin.y;
		}
		m.work = integral((DwmRect){visible.origin.x, self.top - NSMaxY(visible), visible.size.width, visible.size.height});
		/* With the menu bar hidden, macOS still keeps windows out of the notch strip.
		 * Use that strip for the bar, beside the notch, and give windows everything below. */
		m.notchBar = NO;
		if (@available(macOS 12.0, *)) {
			NSRect left = screen.auxiliaryTopLeftArea, right = screen.auxiliaryTopRightArea;
			if (inset == 0 && topBar && screen.safeAreaInsets.top > 0 && !NSIsEmptyRect(left) && !NSIsEmptyRect(right)) {
				m.notchBar = YES;
				m.bar = (DwmRect){m.frame.x, m.frame.y, m.frame.w, screen.safeAreaInsets.top};
				m.gapStart = NSMaxX(left) - NSMinX(screen.frame);
				m.gapEnd = NSMinX(right) - NSMinX(screen.frame);
			}
		}
		NSLog(@"display %@: %gx%g at %g,%g, work area %gx%g at %g,%g%@%@", display, m.frame.w, m.frame.h, m.frame.x, m.frame.y,
			m.work.w, m.work.h, m.work.x, m.work.y, menuBarHidden ? @" (menu bar hides)" : @"", m.notchBar ? @", bar beside the notch" : @"");
		if (!m.panel && !self.restoreOnly) {
			m.panel = [[BarPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
			m.panel.level = NSFloatingWindowLevel;
			m.panel.hidesOnDeactivate = NO;
			m.panel.hasShadow = NO;
			m.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|
				NSWindowCollectionBehaviorStationary|NSWindowCollectionBehaviorIgnoresCycle;
			m.panel.backgroundColor = color(colNormBG);
			Bar *bar = [Bar new]; bar.manager = self; bar.monitor = m;
			m.panel.contentView = bar;
		}
		[next addObject:m];
	}
	if (!next.count) return;
	/* dwm numbers monitors by position: left to right, then top to bottom */
	[next sortUsingComparator:^NSComparisonResult(Monitor *a, Monitor *b) {
		if (a.frame.x != b.frame.x) return a.frame.x < b.frame.x ? NSOrderedAscending : NSOrderedDescending;
		if (a.frame.y != b.frame.y) return a.frame.y < b.frame.y ? NSOrderedAscending : NSOrderedDescending;
		return NSOrderedSame;
	}];
	for (Monitor *old in self.monitors) if (![next containsObject:old]) {
		for (Client *c in [old.clients copy]) [self move:c to:next.firstObject tags:NO];
		[old.panel close];
	}
	self.monitors = next;
	if (![next containsObject:self.selected]) self.selected = next.firstObject;
	if (self.restoreOnly) return;
	/* display corners moved; park hidden windows again */
	for (Monitor *m in next) for (Client *c in m.clients) if (c.hidden) { c.hidden = NO; [self park:c]; }
	[self arrange];
	[self scheduleSync];
}

- (Monitor *)monitorAt:(CGPoint)p
{
	for (Monitor *m in self.monitors) if (CGRectContainsPoint(cg(m.frame), p)) return m;
	return self.selected ?: self.monitors.firstObject;
}

/* dwm's recttomon: the monitor showing most of the rectangle */
- (Monitor *)monitorFor:(DwmRect)r
{
	Monitor *best = nil;
	double most = -1;
	for (Monitor *m in self.monitors) {
		double a = overlap(r, m.frame);
		if (a > most) { most = a; best = m; }
	}
	return most > 0 ? best : [self monitorAt:CGPointMake(r.x + r.w / 2, r.y + r.h / 2)];
}

/* the area windows may use: the work area minus the bar when the bar is in it */
- (DwmRect)area:(Monitor *)m
{
	DwmRect a = m.work;
	if (m.showbar && !m.notchBar) { a.h -= barHeight; if (topBar) a.y += barHeight; }
	return a;
}

- (BOOL)isVisible:(Client *)c
{
	return c && (c.tags & c.monitor.tags) && !c.hidden && !c.away && !c.nativeFullscreen;
}

/* whether c belongs on screen: visible, or hidden and about to be shown */
- (BOOL)shows:(Client *)c
{
	return c && (c.tags & c.monitor.tags) && !c.away && !c.nativeFullscreen;
}

- (NSArray<Client *> *)visible:(Monitor *)m tiled:(BOOL)tiled
{
	NSMutableArray *result = [NSMutableArray array];
	for (Client *c in m.clients)
		if ([self isVisible:c] && (!tiled || (!c.floating && !c.fullscreen))) [result addObject:c];
	return result;
}

- (void)refreshWindows
{
	self.windows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly|kCGWindowListExcludeDesktopElements, kCGNullWindowID)) ?: @[];
}

/* the CoreGraphics id of a window on the current Space, 0 when it is not there.
 * Known windows are found by id; a window whose id changed (some style changes
 * recreate it) or a new one is found by its frame. */
- (uint32_t)numberOf:(Client *)c pid:(pid_t)pid frame:(DwmRect)r
{
	uint32_t byFrame = 0;
	for (NSDictionary *info in self.windows) {
		pid_t owner; uint32_t number; CGRect bounds;
		if (!windowInfo(info, &owner, &number, &bounds) || owner != pid) continue;
		if (c && number == c.number) return number;
		if (!byFrame && matches(r, bounds)) byFrame = number;
	}
	return byFrame;
}

/* the managed window on top at p, nil for the bar, the desktop or unmanaged windows */
- (Client *)clientAt:(CGPoint)p
{
	for (Monitor *m in self.monitors)
		if (m.panel.visible && NSPointInRect(NSMakePoint(p.x, self.top - p.y), m.panel.frame)) return nil;
	for (NSDictionary *info in self.windows) {
		pid_t owner; uint32_t number; CGRect bounds;
		if (!windowInfo(info, &owner, &number, &bounds) || !CGRectContainsPoint(bounds, p)) continue;
		for (Monitor *m in self.monitors) for (Client *c in m.clients)
			if (c.pid == owner && c.number == number && !c.hidden && !c.away) return c;
		return nil;
	}
	return nil;
}

/* the visible tiled window whose place in the layout contains p */
- (Client *)tiledAt:(CGPoint)p on:(Monitor *)m except:(Client *)skip
{
	for (Client *c in [self visible:m tiled:YES])
		if (c != skip && CGRectContainsPoint(cg(c.requested), p)) return c;
	return nil;
}

/* Applications are observed for window events as soon as they answer; a
 * launching application may take a while, so registration is retried with
 * growing pauses instead of being given up. */
- (ApplicationWatch *)watch:(NSRunningApplication *)app
{
	NSNumber *pid = @(app.processIdentifier);
	ApplicationWatch *watch = self.watches[pid];
	if (!watch) {
		watch = [ApplicationWatch new];
		watch.element = AXUIElementCreateApplication(app.processIdentifier);
		self.watches[pid] = watch;
	}
	if (watch.registered || now() < watch.retryAt) return watch;
	if (!watch.observer) {
		AXObserverRef observer = NULL;
		if (AXObserverCreate(app.processIdentifier, observed, &observer) == kAXErrorSuccess) {
			watch.observer = observer;
			CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
		}
	}
	if (watch.observer) {
		BOOL ok = YES;
		for (NSString *name in @[(__bridge NSString *)kAXWindowCreatedNotification, (__bridge NSString *)kAXFocusedWindowChangedNotification,
				(__bridge NSString *)kAXWindowMovedNotification, (__bridge NSString *)kAXWindowResizedNotification,
				(__bridge NSString *)kAXWindowMiniaturizedNotification, (__bridge NSString *)kAXWindowDeminiaturizedNotification,
				(__bridge NSString *)kAXTitleChangedNotification]) {
			AXError error = AXObserverAddNotification(watch.observer, watch.element, (__bridge CFStringRef)name, (__bridge void *)self);
			if (error != kAXErrorSuccess && error != kAXErrorNotificationAlreadyRegistered) ok = NO;
		}
		watch.registered = ok;
	}
	if (!watch.registered) {
		watch.retryAt = now() + watch.backoff;
		watch.backoff = MIN(60, watch.backoff * 2);
	}
	return watch;
}

- (Client *)clientFor:(AXUIElementRef)element pid:(pid_t)pid
{
	for (Monitor *m in self.monitors) for (Client *c in m.clients)
		if (c.pid == pid && CFEqual(c.element, element)) return c;
	return nil;
}

/* a window left in a display corner by an earlier dwm that did not get to restore it */
- (BOOL)isParked:(DwmRect)f
{
	for (Monitor *m in self.monitors) {
		DwmRect d = m.frame;
		if (fabs(f.y - (d.y + d.h - 1)) > 16) continue;
		if (fabs(f.x - (d.x + d.w - 1)) <= 16 || fabs(f.x + f.w - (d.x + 1)) <= 16) return YES;
	}
	return NO;
}

- (NSString *)stateKey:(Client *)c
{
	return [NSString stringWithFormat:@"%d:%u", c.pid, c.number];
}

/* tags and frame a previous instance recorded for this window */
- (void)restoreClient:(Client *)c parked:(BOOL)parked
{
	NSDictionary *saved = self.state[@"windows"][[self stateKey:c]];
	if (!saved) return;
	unsigned tags = [saved[@"tags"] unsignedIntValue] & DWM_TAGMASK;
	if (tags) c.tags = tags;
	if (!c.fixed) c.floating = [saved[@"floating"] boolValue];
	for (Monitor *m in self.monitors) if ([m.display isEqual:saved[@"display"]]) c.monitor = m;
	NSArray *frame = saved[@"frame"];
	if (parked && frame.count == 4)
		c.frame = (DwmRect){[frame[0] doubleValue], [frame[1] doubleValue], [frame[2] doubleValue], [frame[3] doubleValue]};
	LOG(@"restored tags %u%@ for \"%@\"", c.tags, c.floating ? @" floating" : @"", c.title);
}

- (void)restoreMonitor:(Monitor *)m
{
	NSDictionary *saved = self.state[@"monitors"][m.display.stringValue];
	if (!saved) return;
	m.tags = [saved[@"tags"] unsignedIntValue] & DWM_TAGMASK ?: 1;
	m.previousTags = [saved[@"previousTags"] unsignedIntValue] & DWM_TAGMASK ?: 1;
	m.layout = MAX(Tile, MIN(Monocle, [saved[@"layout"] intValue]));
	m.previousLayout = MAX(Tile, MIN(Monocle, [saved[@"previousLayout"] intValue]));
	m.masters = MAX(0, [saved[@"masters"] intValue]);
	m.factor = MAX(0.05, MIN(0.95, [saved[@"factor"] doubleValue] ?: 0.55));
	m.showbar = saved[@"showbar"] ? [saved[@"showbar"] boolValue] : YES;
}

- (void)saveState
{
	self.stateDirty = NO;
	NSMutableDictionary *windows = [NSMutableDictionary dictionary], *monitors = [NSMutableDictionary dictionary];
	for (Monitor *m in self.monitors) {
		for (Client *c in m.clients)
			windows[[self stateKey:c]] = @{@"tags": @(c.tags), @"floating": @(c.floating), @"display": m.display,
				@"frame": @[@(c.frame.x), @(c.frame.y), @(c.frame.w), @(c.frame.h)]};
		monitors[m.display.stringValue] = @{@"tags": @(m.tags), @"previousTags": @(m.previousTags), @"layout": @(m.layout),
			@"previousLayout": @(m.previousLayout), @"masters": @(m.masters), @"factor": @(m.factor), @"showbar": @(m.showbar)};
	}
	self.state[@"windows"] = windows;
	self.state[@"monitors"] = monitors;
	if (![self.state writeToFile:[self statePath] atomically:YES]) NSLog(@"Cannot write %@", [self statePath]);
}

/* centered in the area and within it, for floating windows found off screen */
- (DwmRect)center:(DwmRect)r in:(DwmRect)a
{
	r.w = MIN(r.w, a.w); r.h = MIN(r.h, a.h);
	r.x = a.x + floor((a.w - r.w) / 2);
	r.y = a.y + floor((a.h - r.h) / 2);
	return r;
}

/* dwm keeps floating windows on their monitor: pull in what lies entirely outside */
- (DwmRect)clamp:(DwmRect)r to:(DwmRect)a
{
	if (r.x >= a.x + a.w) r.x = a.x + a.w - r.w;
	if (r.y >= a.y + a.h) r.y = a.y + a.h - r.h;
	if (r.x + r.w <= a.x) r.x = a.x;
	if (r.y + r.h <= a.y) r.y = a.y;
	return r;
}

- (Client *)manage:(AXUIElementRef)element pid:(pid_t)pid number:(uint32_t)number app:(NSRunningApplication *)app frame:(DwmRect)frame values:(NSArray *)values
{
	NSString *subrole = entry(values, AxSubrole), *title = entry(values, AxTitle) ?: @"";
	BOOL standard = [subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole];
	BOOL dialog = [subrole isEqual:(__bridge NSString *)kAXDialogSubrole] || [subrole isEqual:(__bridge NSString *)kAXSystemDialogSubrole];
	ApplicationWatch *watch = self.watches[@(pid)];
	if (!standard && !dialog && !title.length && !attribute(element, kAXCloseButtonAttribute)) {
		/* tooltips, menus, the input source switcher: chrome that reports as a window */
		LOG(@"ignore %@ %@ %gx%g at %g,%g", app.localizedName, subrole, frame.w, frame.h, frame.x, frame.y);
		if (watch.ignored.count > 64) [watch.ignored removeAllObjects];
		[watch.ignored addObject:(__bridge id)element];
		return nil;
	}
	Boolean resizable = false;
	AXUIElementIsAttributeSettable(element, kAXSizeAttribute, &resizable);
	Client *c = [Client new];
	c.element = (AXUIElementRef)CFRetain(element);
	c.pid = pid;
	c.number = number;
	c.title = title;
	c.application = app.localizedName ?: app.bundleIdentifier ?: @"";
	c.frame = c.requested = c.applied = frame;
	c.monitor = [self monitorFor:frame];
	c.tags = c.monitor.tags;
	c.fixed = !resizable;
	c.floating = c.fixed || !standard;
	unsigned tags = 0;
	for (size_t i = 0; i < LENGTH(rules); ++i) {
		if (rules[i].bundle && ![app.bundleIdentifier isEqual:rules[i].bundle]) continue;
		if (rules[i].title && ![title containsString:rules[i].title]) continue;
		c.floating = rules[i].floating;
		if (rules[i].monitor >= 0 && rules[i].monitor < (int)self.monitors.count) c.monitor = self.monitors[rules[i].monitor];
		tags |= rules[i].tags;
	}
	c.tags = (tags & DWM_TAGMASK) ?: c.monitor.tags;
	BOOL parked = [self isParked:frame];
	[self restoreClient:c parked:parked];
	if (c.fixed) c.floating = YES;
	if (parked && same(c.frame, frame)) c.frame = [self center:frame in:[self area:c.monitor]];   /* nothing recorded: bring it to the middle */
	if (parked) LOG(@"rescue \"%@\" from the display corner", title);
	[c.monitor.clients insertObject:c atIndex:0];
	[c.monitor.history insertObject:c atIndex:0];
	NSLog(@"manage %@ \"%@\" %gx%g at %g,%g%@ tags %u", c.application, title, frame.w, frame.h, frame.x, frame.y, c.floating ? @" floating" : @"", c.tags);
	if (watch.observer) AXObserverAddNotification(watch.observer, element, kAXUIElementDestroyedNotification, (__bridge void *)self);
	return c;
}

- (BOOL)forget:(pid_t)pid except:(NSSet *)seen
{
	BOOL changed = NO;
	ApplicationWatch *watch = self.watches[@(pid)];
	for (Monitor *m in self.monitors) for (Client *c in [m.clients copy]) {
		if (c.pid != pid || [seen containsObject:c]) continue;
		[m.clients removeObject:c];
		[m.history removeObject:c];
		if (m.selected == c) { m.selected = nil; if (m == self.selected) self.selectionLost = YES; }
		if (self.dragClient == c) self.dragClient = nil;
		if (self.pressClient == c) self.pressClient = nil;
		if (self.osFocused == c) self.osFocused = nil;
		if (watch.observer) AXObserverRemoveNotification(watch.observer, c.element, kAXUIElementDestroyedNotification);
		[self.state[@"windows"] removeObjectForKey:[self stateKey:c]];
		NSLog(@"unmanage \"%@\"", c.title);
		changed = YES;
	}
	return changed;
}

- (void)select:(Client *)c
{
	self.selected = c.monitor;
	c.monitor.selected = c;
	[c.monitor.history removeObject:c];
	[c.monitor.history insertObject:c atIndex:0];
}

- (Client *)visibleClientOf:(pid_t)pid on:(Monitor *)m
{
	for (Client *c in m.history) if (c.pid == pid && [self isVisible:c]) return c;
	return nil;
}

/* Reconciles the model with what macOS reports. Runs on notifications and
 * every half second as a fallback for applications with poor AX support. */
- (void)sync
{
	self.syncPending = NO;
	if (self.locked || self.stopping) return;
	[self refreshWindows];
	BOOL changed = NO;
	Client *focused = nil;
	NSMutableSet *live = [NSMutableSet set];
	NSMutableArray *fresh = [NSMutableArray array];
	for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
		if (app.processIdentifier == getpid() || app.activationPolicy != NSApplicationActivationPolicyRegular || app.terminated) continue;
		pid_t pid = app.processIdentifier;
		[live addObject:@(pid)];
		ApplicationWatch *watch = [self watch:app];
		if (now() < watch.busyUntil) continue;
		NSArray *windows = attribute(watch.element, kAXWindowsAttribute);
		if (!windows) {
			/* unresponsive: keep what we know and ask again later, less and less often */
			watch.busyUntil = now() + watch.backoff;
			watch.backoff = MIN(8, watch.backoff * 2);
			continue;
		}
		watch.backoff = 0.5;
		id focusedWindow = app.active ? attribute(watch.element, kAXFocusedWindowAttribute) : nil;
		NSMutableSet *seen = [NSMutableSet set];
		for (id object in windows) {
			AXUIElementRef element = (__bridge AXUIElementRef)object;
			if ([watch.ignored containsObject:object]) continue;
			Client *c = [self clientFor:element pid:pid];
			NSArray *values = attributes(element);
			if (!values) { if (c) [seen addObject:c]; continue; }   /* no answer right now: keep it */
			if (![entry(values, AxRole) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
			DwmRect frame = frameOf(values);
			uint32_t number = [self numberOf:c pid:pid frame:frame];
			if (!c) {
				/* manage windows when they appear on the current Space, but not while a
				 * button is down: a tab being torn off is a window only once it is dropped */
				if (frame.w <= 0 || frame.h <= 0 || !number || self.buttons) continue;
				c = [self manage:element pid:pid number:number app:app frame:frame values:values];
				if (!c) continue;
				changed = YES;
				[fresh addObject:c];
			}
			if (number) c.number = number;
			[seen addObject:c];
			c.title = entry(values, AxTitle) ?: c.application;
			BOOL nativeFullscreen = [entry(values, AxFullScreen) boolValue];
			BOOL away = app.hidden || [entry(values, AxMinimized) boolValue] || !number;
			if (c.away != away || c.nativeFullscreen != nativeFullscreen) changed = YES;
			c.away = away;
			c.nativeFullscreen = nativeFullscreen;
			if (!away && !nativeFullscreen && frame.w > 0) {
				if (c.hidden) {
					if (!same(frame, c.parked) && c.fights < 3) {
						/* its application pulled it out of the corner; park it again, but
						 * not forever: some refuse the corner and would flicker */
						c.hidden = NO;
						c.fights++;
						if (c.fights == 3) NSLog(@"Window keeps leaving the corner, leaving it alone: %@", c.title);
						changed = YES;
					}
				} else if (c.fullscreen || (!c.floating && c.monitor.layout != Float && (c.tags & c.monitor.tags))) {
					/* dwm owns the geometry: a window moved by its application or the user
					 * goes back into the layout, unless it insists on the same geometry */
					c.frame = frame;
					if (!self.buttons && !self.dragClient && !same(frame, c.applied)) {
						if (same(frame, c.drift)) { c.stubborn = YES; c.applied = frame; LOG(@"accepting geometry of \"%@\"", c.title); }
						else { c.drift = frame; c.stubborn = NO; changed = YES; }
					}
				} else if (!same(frame, c.frame)) c.frame = c.requested = c.applied = frame;   /* floating: follow the user */
			}
			if (focusedWindow && CFEqual(element, (__bridge CFTypeRef)focusedWindow)) focused = c;
		}
		if ([self forget:pid except:seen]) changed = YES;
	}
	for (NSNumber *pid in self.watches.allKeys) if (![live containsObject:pid]) {
		[self.watches removeObjectForKey:pid];
		if ([self forget:pid.intValue except:nil]) changed = YES;
	}
	/* an activation macOS did not honor gets one more try before dwm follows macOS */
	if (self.wanted) {
		NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:self.wanted.pid];
		if (focused == self.wanted || ![self isVisible:self.wanted] || app.active || self.focusTries++) self.wanted = nil;
		else { [self activate:self.wanted]; focused = self.osFocused; }
	}
	/* at startup every window is new; the user's focus stands, as after Cmd-Tab */
	if (!self.started) { self.started = YES; [fresh removeAllObjects]; }
	/* Follow focus changes made outside dwm: clicks, Cmd-Tab, the Dock. Reaching a
	 * window on a hidden tag that way views its tag, unless the application has a
	 * window in view already or just opened the window there itself. */
	Client *refocus = nil;
	BOOL unfocus = NO;
	if (focused != self.osFocused) {
		self.osFocused = focused;
		Monitor *m = focused.monitor;
		if (m && !focused.away && !focused.nativeFullscreen && !self.dragClient) {
			if (focused.tags & m.tags) [self select:focused];
			else if ([fresh containsObject:focused]) { refocus = self.selected.selected; unfocus = !refocus; }
			else if (!(refocus = [self visibleClientOf:focused.pid on:m])) {
				m.previousTags = m.tags;
				m.tags = focused.tags;
				changed = YES;
				[self select:focused];
			}
		}
	}
	if (changed && !self.dragClient) [self arrange];
	/* dwm gives new windows the focus and, when the focused window went away,
	 * the next one in the focus history */
	if (focusNewWindows && !refocus) for (Client *c in fresh.reverseObjectEnumerator)
		if (c.monitor == self.selected && [self isVisible:c]) { refocus = c; break; }
	if (!refocus && self.selectionLost && self.selected.selected) refocus = self.selected.selected;
	self.selectionLost = NO;
	if (refocus) [self focus:refocus raise:YES];
	else if (unfocus) [self unfocus];   /* keys must not reach a window that is not in view */
	if (changed) self.stateDirty = YES;
	for (Monitor *m in self.monitors) [m.panel.contentView setNeedsDisplay:YES];
}

- (void)tick:(NSTimer *)timer
{
	(void)timer;
	NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:[supportPath stringByAppendingPathComponent:@"status"]];
	int fd = open(path.fileSystemRepresentation, O_RDONLY|O_NONBLOCK);
	NSData *data = nil;
	if (fd >= 0) {
		struct stat info;
		if (fstat(fd, &info) == 0 && S_ISREG(info.st_mode)) {
			char buffer[4096];
			ssize_t length = read(fd, buffer, sizeof(buffer));
			if (length >= 0) data = [NSData dataWithBytes:buffer length:(NSUInteger)length];
		}
		close(fd);
	}
	NSString *status = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
	self.status = [status stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"dwm";
	/* the Dock moving or hiding changes the work area without a screen notification */
	BOOL screensMoved = menuBarAutoHides() != self.menuBarHidden;
	for (NSScreen *screen in NSScreen.screens) {
		NSRect visible = screen.visibleFrame;
		for (Monitor *m in self.monitors) if ([m.display isEqual:screen.deviceDescription[@"NSScreenNumber"]] && !NSEqualRects(visible, m.visible)) screensMoved = YES;
	}
	if (screensMoved) [self screensChanged:nil];
	/* password fields and terminals with secure entry take the keyboard away from the tap */
	BOOL secure = IsSecureEventInputEnabled();
	if (secure != self.secureInput) {
		self.secureInput = secure;
		if (secure) NSLog(@"Secure keyboard entry is on: shortcuts are suspended until it ends");
	}
	/* a release the tap missed must not keep a drag going or the layout frozen */
	BOOL left = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft);
	BOOL right = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight);
	BOOL center = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonCenter);
	if ((self.buttons & 7) & ~((left ? 1u : 0) | (right ? 2u : 0) | (center ? 4u : 0))) [self tapReset];
	[self sync];
	if (self.stateDirty) [self saveState];
}

/* Chrome and other Electron applications animate every frame change while
 * "AXEnhancedUserInterface" is set on them; it is cleared while dwm moves windows. */
- (void)pauseAnimations:(pid_t)pid
{
	if ([self.animated containsObject:@(pid)]) return;
	AXUIElementRef app = self.watches[@(pid)].element;
	if (![attribute(app, CFSTR("AXEnhancedUserInterface")) boolValue]) return;
	setAttribute(app, CFSTR("AXEnhancedUserInterface"), @NO);
	[self.animated addObject:@(pid)];
}

- (void)resumeAnimations
{
	for (NSNumber *pid in self.animated) setAttribute(self.watches[pid].element, CFSTR("AXEnhancedUserInterface"), @YES);
	[self.animated removeAllObjects];
}

/* Asks the window for a geometry and records what it took. Size first, then
 * position, then the size again: a window at a display edge clamps the first
 * request (sizes are requests; applications enforce minimums). */
- (void)apply:(Client *)c frame:(DwmRect)r from:(DwmRect)current
{
	[self pauseAnimations:c.pid];
	BOOL ok = YES;
	if (fabs(current.w - r.w) >= 1 || fabs(current.h - r.h) >= 1) ok = setSize(c.element, CGSizeMake(r.w, r.h));
	if (fabs(current.x - r.x) >= 1 || fabs(current.y - r.y) >= 1) ok = setPosition(c.element, CGPointMake(r.x, r.y)) && ok;
	DwmRect got = geometry(c.element);
	if (got.w > 0 && (fabs(got.w - r.w) >= 1 || fabs(got.h - r.h) >= 1)) {
		setSize(c.element, CGSizeMake(r.w, r.h));
		got = geometry(c.element);
	}
	if (got.w <= 0) got = r;
	c.applied = c.frame = got;
	if (!ok && !c.geometryFailed) NSLog(@"Window refused geometry: %@", c.title);
	c.geometryFailed = !ok;
}

- (void)resize:(Client *)c frame:(DwmRect)r
{
	if (!c || c.nativeFullscreen) return;
	r = integral(r);
	if (c.hidden) { c.frame = r; return; }   /* applied when the window is shown */
	BOOL asked = same(r, c.requested);
	if (asked && same(c.frame, c.applied)) return;   /* asked already and nothing moved it */
	if (asked && c.stubborn && same(c.frame, c.drift)) return;   /* it insists; do not fight */
	if (!asked) c.stubborn = NO;
	c.requested = r;
	if (same(c.frame, r)) { c.applied = r; return; }
	[self apply:c frame:r from:c.frame];
}

/* shows a window where the layout wants it, straight from the corner if it was hidden */
- (void)show:(Client *)c frame:(DwmRect)r
{
	if (!c.hidden) { [self resize:c frame:r]; return; }
	c.hidden = NO;
	c.fights = 0;
	c.requested = integral(r);
	[self apply:c frame:c.requested from:c.parked];
}

/* The corner where the window shows the least of itself: it hangs out of the
 * display there, so a corner another display continues past would reveal it.
 * Every display's bottom corners are candidates, for stacked arrangements. */
- (CGPoint)parkPosition:(Client *)c
{
	CGPoint best = CGPointMake(c.monitor.frame.x + c.monitor.frame.w - 1, c.monitor.frame.y + c.monitor.frame.h - 1);
	double least = INFINITY;
	for (Monitor *m in self.monitors) {
		DwmRect d = m.frame;
		DwmRect right = {d.x + d.w - 1, d.y + d.h - 1, c.frame.w, c.frame.h};
		DwmRect left = {d.x + 1 - c.frame.w, d.y + d.h - 1, c.frame.w, c.frame.h};
		for (int side = 0; side < 2; ++side) {
			DwmRect r = side ? left : right;
			double shown = 0;
			for (Monitor *other in self.monitors) shown += overlap(r, other.frame);
			if (shown < least - 0.5 || (fabs(shown - least) <= 0.5 && m == c.monitor && !side)) { least = shown; best = CGPointMake(r.x, r.y); }
		}
	}
	return best;
}

/* hidden tags: park the window one point inside a display corner */
- (void)park:(Client *)c
{
	if (c.hidden) return;
	[self pauseAnimations:c.pid];
	c.hidden = setPosition(c.element, [self parkPosition:c]);
	if (c.hidden) {
		c.parked = geometry(c.element);
		if (c.parked.w <= 0) c.parked = c.frame;
		LOG(@"park \"%@\" at %g,%g", c.title, c.parked.x, c.parked.y);
	} else if (!c.geometryFailed) NSLog(@"Window refused to hide: %@", c.title);
	if (!c.hidden) c.geometryFailed = YES;
}

- (void)unpark:(Client *)c
{
	if (c.hidden) [self show:c frame:c.frame];
}

/* dwm's sendmon: the client joins the target's list and, unless the display it
 * was on went away, takes the target's tags */
- (void)move:(Client *)c to:(Monitor *)target tags:(BOOL)assign
{
	Monitor *source = c.monitor;
	if (source == target) return;
	[source.clients removeObject:c];
	[source.history removeObject:c];
	if (source.selected == c) source.selected = nil;
	c.monitor = target;
	if (assign) c.tags = target.tags;
	[target.clients insertObject:c atIndex:0];
	[target.history insertObject:c atIndex:0];
}

- (void)showBar:(Monitor *)m covered:(BOOL)covered
{
	for (;;) {
		if (!m.showbar || covered) { [m.panel orderOut:nil]; return; }
		DwmRect bar = m.notchBar ? m.bar : (DwmRect){m.work.x, topBar ? m.work.y : m.work.y + m.work.h - barHeight, m.work.w, barHeight};
		NSRect frame = NSMakeRect(bar.x, self.top - bar.y - bar.h, bar.w, bar.h);
		[m.panel setFrame:frame display:YES];
		if (m.notchBar && fabs(m.panel.frame.origin.y - frame.origin.y) > 1) {
			/* AppKit refused the notch strip: fall back to a bar inside the work area */
			NSLog(@"bar cannot use the notch strip on display %@", m.display);
			m.notchBar = NO;
			continue;
		}
		[m.panel orderFrontRegardless];
		return;
	}
}

- (void)arrange
{
	for (Monitor *m in self.monitors) {
		BOOL covered = NO;
		for (Client *c in m.clients) if (!c.away && ((c.fullscreen && (c.tags & m.tags)) || c.nativeFullscreen)) covered = YES;
		[self showBar:m covered:covered];
		DwmRect area = [self area:m];
		NSMutableArray<Client *> *tiled = [NSMutableArray array], *floating = [NSMutableArray array];
		for (Client *c in m.clients) {
			if (![self shows:c]) continue;
			if (c.floating || c.fullscreen) [floating addObject:c]; else [tiled addObject:c];
		}
		/* windows coming into view first, then the ones leaving: no empty flash */
		for (NSUInteger i = 0; i < tiled.count; ++i) {
			Client *c = tiled[i];
			DwmRect r = m.layout == Tile ? dwm_tile(area, i, tiled.count, m.masters, m.factor) : m.layout == Monocle ? area : c.frame;
			[self show:c frame:r];
		}
		for (Client *c in floating) [self show:c frame:c.fullscreen ? m.work : [self clamp:c.frame to:area]];
		for (Client *c in m.clients) if (!c.away && !c.nativeFullscreen && !(c.tags & m.tags)) [self park:c];
		if (![self isVisible:m.selected] || m.selected.monitor != m) {
			m.selected = nil;
			for (Client *c in m.history) if ([self isVisible:c]) { m.selected = c; break; }
		}
		[m.panel.contentView setNeedsDisplay:YES];
	}
	[self resumeAnimations];
	/* windows just moved under a resting pointer must not steal focus (dwm drains EnterNotify) */
	self.quietUntil = now() + 0.3;
	self.stateDirty = YES;
}

- (void)focus:(Client *)c raise:(BOOL)raise
{
	if (![self isVisible:c]) return;
	Client *current = self.selected.selected;
	if (lockFullscreen && current && current != c && current.fullscreen && current.monitor == c.monitor && [self isVisible:current]) return;
	[self select:c];
	for (Monitor *m in self.monitors) [m.panel.contentView setNeedsDisplay:YES];
	/* raise the window inside its application first so activation brings this one forward */
	if (raise) {
		setAttribute(c.element, kAXMainAttribute, @YES);
		AXUIElementPerformAction(c.element, kAXRaiseAction);
	}
	setAttribute(self.watches[@(c.pid)].element, kAXFocusedWindowAttribute, (__bridge id)c.element);
	[self activate:c];
	self.osFocused = c;
	self.wanted = c;
	self.focusTries = 0;
	LOG(@"focus \"%@\"", c.title);
}

/* Puts the application in front with just this window. Activation requests are
 * not guaranteed to be honored since macOS 14; the Process Manager call still is. */
- (void)activate:(Client *)c
{
	ProcessSerialNumber psn;
	if (GetProcessForPID(c.pid, &psn) == noErr) SetFrontProcessWithOptions(&psn, kSetFrontProcessFrontWindowOnly);
	NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:c.pid];
	if (!app.active) [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
}

/* dwm's focus on the root window: keys reach no application window */
- (void)unfocus
{
	ProcessSerialNumber psn = {0, kCurrentProcess};
	SetFrontProcessWithOptions(&psn, 0);
}

- (void)spawn:(NSString *)command
{
	NSTask *task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
	task.arguments = @[@"-c", command];
	task.terminationHandler = ^(NSTask *finished) {
		if (finished.terminationStatus) NSLog(@"%@ exited with status %d", command, finished.terminationStatus);
	};
	NSError *error = nil;
	if (![task launchAndReturnError:&error]) NSLog(@"Cannot run %@: %@", command, error);
}

/* presses a system shortcut; needs only the Accessibility access dwm already has */
- (void)press:(CGKeyCode)code modifiers:(CGEventFlags)modifiers
{
	CGEventRef down = CGEventCreateKeyboardEvent(NULL, code, true);
	CGEventRef up = CGEventCreateKeyboardEvent(NULL, code, false);
	CGEventSetFlags(down, modifiers);
	CGEventSetFlags(up, modifiers);
	/* Do not consume our launcher shortcut as a dwm binding. */
	CGEventSetIntegerValueField(down, kCGEventSourceUserData, ownEvent);
	CGEventSetIntegerValueField(up, kCGEventSourceUserData, ownEvent);
	CGEventPost(kCGSessionEventTap, down);
	CGEventPost(kCGSessionEventTap, up);
	CFRelease(down);
	CFRelease(up);
}

- (void)action:(NSString *)name value:(int)value
{
	Monitor *m = self.selected;
	Client *c = m.selected;
	if ([name isEqual:@"quit"]) { [NSApp terminate:nil]; return; }
	if ([name isEqual:@"launcher"]) { [self press:launcherKey modifiers:launcherModifiers]; return; }
	if ([name isEqual:@"spawn"]) { if (value >= 0 && value < (int)LENGTH(commands)) [self spawn:commands[value]]; return; }
	if (!m) return;
	if ([name isEqual:@"view"]) {
		unsigned next = value ? ((unsigned)value & DWM_TAGMASK) : m.previousTags;
		if (next && next != m.tags) { m.previousTags = m.tags; m.tags = next; }
	} else if ([name isEqual:@"toggleview"]) m.tags = dwm_tags(m.tags, (unsigned)value, 1);
	else if ([name isEqual:@"tag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 0);
	else if ([name isEqual:@"toggletag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 1);
	else if ([name isEqual:@"togglebar"]) m.showbar = !m.showbar;
	else if ([name isEqual:@"incnmaster"]) m.masters = MAX(0, m.masters + value);
	else if ([name isEqual:@"setmfact"]) { if (m.layout != Float) m.factor = MAX(0.05, MIN(0.95, m.factor + value * 0.05)); }
	else if ([name isEqual:@"setlayout"]) {
		int next = value < 0 ? m.previousLayout : MIN(value, Monocle);
		if (next != m.layout) { m.previousLayout = m.layout; m.layout = next; }
	} else if ([name isEqual:@"togglefloating"] && c && !c.fullscreen) c.floating = !c.floating || c.fixed;
	else if ([name isEqual:@"togglefullscr"] && c && !c.nativeFullscreen) {
		if (!c.fullscreen) { c.saved = c.frame; c.wasFloating = c.floating; c.fullscreen = YES; c.floating = YES; }
		else { c.fullscreen = NO; c.floating = c.wasFloating; c.frame = c.saved; }
	} else if ([name isEqual:@"killclient"] && c) {
		id close = attribute(c.element, kAXCloseButtonAttribute);
		if (close) AXUIElementPerformAction((__bridge AXUIElementRef)close, kAXPressAction);
		else NSLog(@"Window has no close button: %@", c.title);
	} else if ([name isEqual:@"focusstack"] && c && !(c.fullscreen && lockFullscreen)) {
		NSArray *visible = [self visible:m tiled:NO];
		NSUInteger index = [visible indexOfObject:c];
		if (index != NSNotFound) [self focus:visible[dwm_monitor((int)index, value, (int)visible.count)] raise:YES];
	} else if ([name isEqual:@"zoom"] && c && m.layout != Float && !c.floating && !c.fullscreen) {
		NSArray *tiled = [self visible:m tiled:YES];
		Client *target = c == tiled.firstObject && tiled.count > 1 ? tiled[1] : c;
		[m.clients removeObject:target];
		[m.clients insertObject:target atIndex:0];
		m.selected = target;
	} else if ([name isEqual:@"focusmon"] && self.monitors.count > 1) {
		self.selected = self.monitors[dwm_monitor((int)[self.monitors indexOfObject:m], value, (int)self.monitors.count)];
	} else if ([name isEqual:@"tagmon"] && c && self.monitors.count > 1) {
		Monitor *target = self.monitors[dwm_monitor((int)[self.monitors indexOfObject:m], value, (int)self.monitors.count)];
		[self move:c to:target tags:YES];
		target.selected = c;
	}
	[self arrange];
	Client *selected = self.selected.selected;
	if (selected) [self focus:selected raise:YES];
	else if (self.osFocused && ![self isVisible:self.osFocused]) [self unfocus];   /* keys must not reach a hidden window */
	self.stateDirty = YES;
}

/* sloppy focus, coalesced to one hit test per run loop pass */
- (void)hover
{
	Client *c = [self clientAt:self.pointer];
	if (c == self.hovered) return;
	self.hovered = c;
	if (now() < self.quietUntil) return;
	if (c) {
		if (c != self.selected.selected) [self focus:c raise:NO];
		return;
	}
	Monitor *m = [self monitorAt:self.pointer];
	if (m == self.selected) return;
	self.selected = m;
	if (m.selected) [self focus:m.selected raise:NO];
	else [self unfocus];
	for (Monitor *each in self.monitors) [each.panel.contentView setNeedsDisplay:YES];
}

/* MOUSEMOD drag: move with the left button, resize with the right, like dwm */
- (void)dragTo:(CGPoint)p
{
	Client *c = self.dragClient;
	if (!c) return;
	DwmRect r = self.dragFrame;
	double dx = p.x - self.dragStart.x, dy = p.y - self.dragStart.y;
	if (!c.floating && c.monitor.layout != Float) {
		if (fabs(dx) < snapDistance && fabs(dy) < snapDistance) return;
		c.floating = YES;   /* dwm's togglefloating: the others close the gap right away */
		[self arrange];
	}
	if (self.dragButton == 0) {
		DwmRect a = [self area:[self monitorAt:p]];
		r.x += dx; r.y += dy;
		if (fabs(r.x - a.x) < snapDistance) r.x = a.x;
		else if (fabs(r.x + r.w - a.x - a.w) < snapDistance) r.x = a.x + a.w - r.w;
		if (fabs(r.y - a.y) < snapDistance) r.y = a.y;
		else if (fabs(r.y + r.h - a.y - a.h) < snapDistance) r.y = a.y + a.h - r.h;
	} else {
		r.w = MAX(1, r.w + dx);
		r.h = MAX(1, r.h + dy);
	}
	[self resize:c frame:r];
}

- (void)endDrag
{
	Client *c = self.dragClient;
	self.dragClient = nil;
	if (!c || !c.monitor) return;
	Monitor *target = [self monitorFor:c.frame];
	if (target != c.monitor) [self move:c to:target tags:YES];
	[self arrange];
	[self focus:c raise:YES];
}

/* The user moved or resized a window with its own title bar or edges. A floating
 * window is simply followed; a tiled one swaps places with the window it was
 * dropped on, moves to the display it was dropped on, hands its new width to the
 * master factor, or snaps back into the layout. */
- (void)dropped:(Client *)c at:(CGPoint)p moved:(BOOL)moved
{
	Monitor *m = c.monitor;
	if (!m || !moved || c.hidden || c.away || c.nativeFullscreen) return;
	DwmRect frame = geometry(c.element);
	if (frame.w <= 0 || same(frame, c.applied)) return;
	DwmRect before = c.applied;
	c.frame = frame;
	Monitor *under = [self monitorAt:p];
	if (c.fullscreen) {
		/* nothing: the layout puts it back */
	} else if (c.floating || m.layout == Float) {
		c.requested = c.applied = frame;
		Monitor *target = [self monitorFor:frame];
		if (target != m) [self move:c to:target tags:YES];
	} else if (fabs(frame.w - before.w) >= 1 || fabs(frame.h - before.h) >= 1) {
		if (m.layout == Tile && fabs(frame.w - before.w) >= 1) {
			NSArray *tiled = [self visible:m tiled:YES];
			NSUInteger index = [tiled indexOfObject:c], masters = MIN((NSUInteger)MAX(0, m.masters), tiled.count);
			if (index != NSNotFound && masters > 0 && masters < tiled.count) m.factor = dwm_factor([self area:m].w, frame.w, index < masters);
		}
	} else {
		Client *target = [self tiledAt:p on:under except:c];
		if (target && under == m) {
			NSUInteger i = [m.clients indexOfObject:c], j = [m.clients indexOfObject:target];
			[m.clients exchangeObjectAtIndex:i withObjectAtIndex:j];
		} else if (under != m) {
			[self move:c to:under tags:YES];
			if (target) {
				[under.clients removeObject:c];
				[under.clients insertObject:c atIndex:[under.clients indexOfObject:target]];
			}
		}
	}
	[self arrange];
	[self focus:c raise:YES];
}

- (void)tapReset
{
	self.buttons = 0;
	self.pressClient = nil;
	if (self.dragClient) dispatch_async(dispatch_get_main_queue(), ^{ [self endDrag]; });
	else [self scheduleSync];
}

- (CGEventRef)event:(CGEventRef)event type:(CGEventType)type
{
	if (CGEventGetIntegerValueField(event, kCGEventSourceUserData) == ownEvent) return event;
	CGEventFlags flags = CGEventGetFlags(event) & (ALT|SHIFT|CTRL|kCGEventFlagMaskCommand);
	if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
		CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
		if (type == kCGEventKeyUp) {
			if ([self.heldKeys containsIndex:code]) { [self.heldKeys removeIndex:code]; return NULL; }
			return event;
		}
		for (size_t i = 0; i < LENGTH(keys); ++i) if (keys[i].code == code && keys[i].modifiers == flags) {
			NSString *action = keys[i].action;
			int value = keys[i].value;
			/* with one display the monitor keys stay with the applications */
			if (self.monitors.count < 2 && ([action isEqual:@"focusmon"] || [action isEqual:@"tagmon"])) return event;
			[self.heldKeys addIndex:code];
			dispatch_async(dispatch_get_main_queue(), ^{ if (!self.stopping) [self action:action value:value]; });
			return NULL;
		}
		return event;
	}
	CGPoint p = CGEventGetLocation(event);
	if (type == kCGEventMouseMoved) {
		self.pointer = p;
		if (!self.pointerPending) {
			self.pointerPending = YES;
			dispatch_async(dispatch_get_main_queue(), ^{
				self.pointerPending = NO;
				if (!self.stopping && !self.dragClient && !self.buttons) [self hover];
			});
		}
		return event;
	}
	BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
	BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
	BOOL dragged = type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged || type == kCGEventOtherMouseDragged;
	int button = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
	if (button >= 0 && button < 32) {
		if (down) self.buttons |= 1u << button;
		if (up) self.buttons &= ~(1u << button);
	}
	if (self.dragClient) {
		if (up && button == self.dragButton) { dispatch_async(dispatch_get_main_queue(), ^{ [self endDrag]; }); return NULL; }
		if (dragged) {
			self.dragPoint = p;
			if (!self.dragPending) {
				self.dragPending = YES;
				dispatch_async(dispatch_get_main_queue(), ^{ self.dragPending = NO; [self dragTo:self.dragPoint]; });
			}
			return NULL;
		}
		return event;
	}
	if (down && flags == MOUSEMOD && button <= 2) {
		[self refreshWindows];
		Client *c = [self clientAt:p];
		if (!c || c.fullscreen) return event;
		if (button == 2) {
			dispatch_async(dispatch_get_main_queue(), ^{ [self focus:c raise:YES]; [self action:@"togglefloating" value:0]; });
			return NULL;
		}
		self.pressClient = nil;
		self.dragClient = c;
		self.dragButton = button;
		self.dragStart = p;
		self.dragFrame = c.frame;
		dispatch_async(dispatch_get_main_queue(), ^{ [self focus:c raise:YES]; });
		return NULL;
	}
	/* plain left button: watch where the window under it ends up */
	if (button == 0) {
		if (down) {
			[self refreshWindows];
			self.pressClient = [self clientAt:p];
			self.pressDragged = NO;
		} else if (dragged && self.pressClient) self.pressDragged = YES;
		else if (up && self.pressClient) {
			Client *c = self.pressClient;
			BOOL moved = self.pressDragged;
			self.pressClient = nil;
			dispatch_async(dispatch_get_main_queue(), ^{ if (!self.stopping) [self dropped:c at:p moved:moved]; });
		}
	}
	return event;
}

/* `dwm-macos --restore`: bring back windows a crashed instance left in the corners */
- (void)restoreParked
{
	[self refreshWindows];
	int count = 0;
	for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
		if (app.processIdentifier == getpid() || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
		AXUIElementRef application = AXUIElementCreateApplication(app.processIdentifier);
		for (id object in attribute(application, kAXWindowsAttribute)) {
			AXUIElementRef element = (__bridge AXUIElementRef)object;
			NSArray *values = attributes(element);
			if (![entry(values, AxRole) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
			DwmRect frame = frameOf(values);
			if (frame.w <= 0 || ![self isParked:frame]) continue;
			Client *c = [Client new];
			c.pid = app.processIdentifier;
			c.number = [self numberOf:nil pid:c.pid frame:frame];
			c.frame = frame;
			c.monitor = [self monitorFor:frame];
			[self restoreClient:c parked:YES];
			if (same(c.frame, frame)) c.frame = [self center:frame in:[self area:c.monitor]];
			c.frame = [self clamp:c.frame to:[self area:c.monitor]];
			setSize(element, CGSizeMake(c.frame.w, c.frame.h));
			setPosition(element, CGPointMake(c.frame.x, c.frame.y));
			NSLog(@"restored %@ \"%@\" to %g,%g", app.localizedName, entry(values, AxTitle), c.frame.x, c.frame.y);
			count++;
		}
		CFRelease(application);
	}
	NSLog(@"%d window%s restored", count, count == 1 ? "" : "s");
	[[NSFileManager defaultManager] removeItemAtPath:[self statePath] error:NULL];
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	(void)notification;
	self.stopping = YES;
	[self.timer invalidate];
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
	[NSDistributedNotificationCenter.defaultCenter removeObserver:self];
	if (self.tap) { CGEventTapEnable(self.tap, false); CFMachPortInvalidate(self.tap); CFRelease(self.tap); self.tap = NULL; }
	if (self.tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes); CFRelease(self.tapSource); self.tapSource = NULL; }
	self.dragClient = nil;
	for (Monitor *m in self.monitors) {
		for (Client *c in m.clients) {
			if (c.fullscreen) { c.fullscreen = NO; c.floating = c.wasFloating; [self resize:c frame:c.saved]; }
			[self unpark:c];
		}
		[m.panel close];
	}
	[self resumeAnimations];
	if (!self.restoreOnly && self.lockFD >= 0) [self saveState];
	[self.watches removeAllObjects];
	if (self.systemElement) { CFRelease(self.systemElement); self.systemElement = NULL; }
	if (self.interruptSource) dispatch_source_cancel(self.interruptSource);
	if (self.terminateSource) dispatch_source_cancel(self.terminateSource);
	if (self.hangupSource) dispatch_source_cancel(self.hangupSource);
	if (self.lockFD >= 0) close(self.lockFD);
}
@end

@implementation Bar
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }

static NSFont *barFont(void)
{
	return [NSFont monospacedSystemFontOfSize:fontSize weight:NSFontWeightRegular];
}

/* text width plus padding, like dwm's TEXTW */
- (CGFloat)width:(NSString *)text
{
	return ceil([text sizeWithAttributes:@{NSFontAttributeName: barFont()}].width) + fontSize;
}

/* the layout symbol; monocle shows how many windows are in view, like dwm */
- (NSString *)symbol
{
	Monitor *m = self.monitor;
	NSUInteger n = m.layout == Monocle ? [self.manager visible:m tiled:NO].count : 0;
	return n ? [NSString stringWithFormat:@"[%lu]", (unsigned long)n] : layoutNames[m.layout];
}

- (NSString *)status
{
	NSString *status = self.manager.status;
	return self.manager.secureInput ? [@"secure input | " stringByAppendingString:status] : status;
}

- (void)drawText:(NSString *)text x:(CGFloat)x width:(CGFloat)w selected:(BOOL)selected
{
	CGFloat h = self.bounds.size.height;
	[color(selected ? colSelBG : colNormBG) setFill];
	NSRectFill(NSMakeRect(x, 0, w, h));
	NSFont *font = barFont();
	NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
	style.lineBreakMode = NSLineBreakByTruncatingTail;
	NSDictionary *attrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color(selected ? colSelFG : colNormFG), NSParagraphStyleAttributeName: style};
	CGFloat y = floor((h - (font.ascender - font.descender)) / 2);
	[text drawInRect:NSMakeRect(x + fontSize / 2, y, MAX(0, w - fontSize), h - y) withAttributes:attrs];
}

- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	Monitor *m = self.monitor;
	Manager *manager = self.manager;
	CGFloat w = self.bounds.size.width, x = 0, box = floor(fontSize / 3);
	[color(colNormBG) setFill];
	NSRectFill(self.bounds);
	unsigned occupied = 0;
	for (Client *c in m.clients) occupied |= c.tags;
	for (size_t i = 0; i < LENGTH(tagNames); ++i) {
		CGFloat tw = [self width:tagNames[i]];
		BOOL selected = (m.tags & (1u << i)) != 0;
		[self drawText:tagNames[i] x:x width:tw selected:selected];
		if (occupied & (1u << i)) {
			[color(selected ? colSelFG : colNormFG) setFill];
			NSRect mark = NSMakeRect(x + 2, 2, box, box);
			if (m == manager.selected && m.selected && (m.selected.tags & (1u << i))) NSRectFill(mark); else NSFrameRect(mark);
		}
		x += tw;
	}
	NSString *symbol = self.symbol;
	CGFloat lw = [self width:symbol];
	[self drawText:symbol x:x width:lw selected:NO];
	x += lw;
	CGFloat sw = 0, titleEnd = w;
	if (m == manager.selected) {
		NSString *status = self.status;
		sw = MIN([self width:status], MAX(0, w - (m.notchBar ? m.gapEnd : x)));
		[self drawText:status x:w - sw width:sw selected:NO];
		titleEnd = w - sw;
	}
	if (m.notchBar) titleEnd = MIN(titleEnd, m.gapStart);   /* the title stops at the notch */
	if (titleEnd - x > barHeight) {
		Client *c = m.selected;
		if (c) {
			[self drawText:c.title x:x width:titleEnd - x selected:m == manager.selected];
			if (c.floating) {
				[color(m == manager.selected ? colSelFG : colNormFG) setFill];
				NSRect mark = NSMakeRect(x + 2, 2, box, box);
				if (c.fixed) NSRectFill(mark); else NSFrameRect(mark);
			}
		}
	}
}

- (void)click:(NSEvent *)event
{
	Manager *manager = self.manager;
	Monitor *m = self.monitor;
	if (manager.selected != m) { manager.selected = m; [manager action:@"focusmon" value:0]; }
	CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x, w = self.bounds.size.width, edge = 0;
	/* CGEventFlags and NSEventModifierFlags share their bits */
	NSEventModifierFlags held = event.modifierFlags & (NSEventModifierFlagShift|NSEventModifierFlagControl|NSEventModifierFlagOption|NSEventModifierFlagCommand);
	BOOL mod = held == (NSEventModifierFlags)MODKEY, plain = held == 0;
	BOOL right = event.buttonNumber == 1, middle = event.buttonNumber == 2;
	for (size_t i = 0; i < LENGTH(tagNames); ++i) {
		edge += [self width:tagNames[i]];
		if (x < edge) {
			if (middle) return;
			if (mod) [manager action:right ? @"toggletag" : @"tag" value:(int)(1u << i)];
			else if (plain) [manager action:right ? @"toggleview" : @"view" value:(int)(1u << i)];
			return;
		}
	}
	edge += [self width:self.symbol];
	if (x < edge) {
		if (plain && !middle) [manager action:@"setlayout" value:right ? Monocle : -1];
		return;
	}
	if (!middle || !plain) return;
	CGFloat sw = MIN([self width:self.status], MAX(0, w - (m.notchBar ? m.gapEnd : edge)));
	if (m.notchBar && x >= m.gapStart && x < w - sw) return;
	[manager action:x >= w - sw ? @"spawn" : @"zoom" value:0];
}

- (void)mouseDown:(NSEvent *)event { [self click:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self click:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self click:event]; }
@end

int main(int argc, char *argv[])
{
	BOOL restore = NO;
	for (int i = 1; i < argc; ++i) {
		NSString *arg = @(argv[i]);
		if ([arg isEqual:@"-v"] || [arg isEqual:@"--verbose"]) verbose = YES;
		else if ([arg isEqual:@"-r"] || [arg isEqual:@"--restore"]) restore = YES;
		else {
			fprintf([arg isEqual:@"-h"] || [arg isEqual:@"--help"] ? stdout : stderr,
				"usage: dwm-macos [-v] [-r]\n  -v, --verbose  log every decision about every window\n  -r, --restore  bring back windows an earlier instance left hidden, then exit\n");
			return [arg isEqual:@"-h"] || [arg isEqual:@"--help"] ? 0 : 2;
		}
	}
	@autoreleasepool {
		NSApplication *app = NSApplication.sharedApplication;
		[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
		__attribute__((objc_precise_lifetime)) Manager *manager = [Manager new];
		manager.restoreOnly = restore;
		app.delegate = manager;
		[app run];
	}
	return 0;
}
