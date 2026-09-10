/* dwm for native macOS windows. See LICENSE file for copyright and license details.
 *
 * Windows are driven through the public Accessibility API, input arrives through
 * a CoreGraphics event tap, and the on-screen window list from CoreGraphics is
 * used for hit testing and to know which windows are on the current Space.
 * Windows on hidden tags are parked one point inside the bottom-right corner of
 * their display, the way dwm parks them off the X screen. */
#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
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
enum { Tile, Float, Monocle };
_Static_assert((1u << LENGTH(tagNames)) - 1 == DWM_TAGMASK, "tagNames must match DWM_TAGMASK");
_Static_assert(LENGTH(layoutNames) == 3, "three layouts: tile, float, monocle");

static id attribute(AXUIElementRef element, CFStringRef name)
{
	CFTypeRef value = NULL;
	if (!element || AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
	return CFBridgingRelease(value);
}

static BOOL setAttribute(AXUIElementRef element, CFStringRef name, id value)
{
	return element && AXUIElementSetAttributeValue(element, name, (__bridge CFTypeRef)value) == kAXErrorSuccess;
}

static BOOL setPosition(AXUIElementRef element, CGPoint p)
{
	AXValueRef value = AXValueCreate(kAXValueCGPointType, &p);
	BOOL ok = element && AXUIElementSetAttributeValue(element, kAXPositionAttribute, value) == kAXErrorSuccess;
	CFRelease(value);
	return ok;
}

static BOOL setSize(AXUIElementRef element, CGSize s)
{
	AXValueRef value = AXValueCreate(kAXValueCGSizeType, &s);
	BOOL ok = element && AXUIElementSetAttributeValue(element, kAXSizeAttribute, value) == kAXErrorSuccess;
	CFRelease(value);
	return ok;
}

static DwmRect geometry(AXUIElementRef element)
{
	CGPoint p = CGPointZero;
	CGSize s = CGSizeZero;
	id position = attribute(element, kAXPositionAttribute);
	id size = attribute(element, kAXSizeAttribute);
	if (position && CFGetTypeID((__bridge CFTypeRef)position) == AXValueGetTypeID())
		AXValueGetValue((__bridge AXValueRef)position, kAXValueCGPointType, &p);
	if (size && CFGetTypeID((__bridge CFTypeRef)size) == AXValueGetTypeID())
		AXValueGetValue((__bridge AXValueRef)size, kAXValueCGSizeType, &s);
	return (DwmRect){p.x, p.y, s.width, s.height};
}

/* one entry of CGWindowListCopyWindowInfo: ordinary (layer 0) visible windows only */
static BOOL windowInfo(NSDictionary *info, pid_t *pid, CGRect *bounds)
{
	if ([info[(__bridge NSString *)kCGWindowLayer] intValue] != 0) return NO;
	if ([info[(__bridge NSString *)kCGWindowAlpha] doubleValue] <= 0) return NO;
	*pid = [info[(__bridge NSString *)kCGWindowOwnerPID] intValue];
	return CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)info[(__bridge NSString *)kCGWindowBounds], bounds);
}

static BOOL matches(DwmRect r, CGRect b)
{
	return fabs(r.x - b.origin.x) < 2 && fabs(r.y - b.origin.y) < 2 && fabs(r.w - b.size.width) < 2 && fabs(r.h - b.size.height) < 2;
}

/* the menu bar auto-hide setting; visibleFrame does not reflect it */
static BOOL menuBarAutoHides(void)
{
	Boolean exists = false;
	Boolean hides = CFPreferencesGetAppBooleanValue(CFSTR("_HIHideMenuBar"), kCFPreferencesAnyApplication, &exists);
	return exists && hides;
}

static NSColor *color(unsigned rgb)
{
	return [NSColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

@class Manager, Monitor;
@interface Client : NSObject
@property AXUIElementRef element;
@property pid_t pid;
@property unsigned tags;
@property BOOL floating, fullscreen, wasFloating;
@property BOOL hidden;            /* parked in the display corner by dwm */
@property BOOL away;              /* minimized, application hidden or on another Space */
@property BOOL nativeFullscreen;  /* in a macOS fullscreen Space; never touched */
@property BOOL geometryFailed;
@property DwmRect frame, saved;   /* last known on-screen frame, frame before fullscreen */
@property(strong) NSString *title;
@property(weak) Monitor *monitor;
@end
@implementation Client
- (void)dealloc { if (_element) CFRelease(_element); }
@end

@interface Bar : NSView
@property(weak) Manager *manager;
@property(weak) Monitor *monitor;
@end

@interface Monitor : NSObject
@property(strong) NSNumber *display;
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
@end
@implementation ApplicationWatch
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
@property(strong) NSMutableArray<Monitor *> *monitors;
@property(strong) NSMutableDictionary<NSNumber *, ApplicationWatch *> *watches;
@property(strong) NSArray<NSDictionary *> *windows;   /* on-screen windows, front to back */
@property(weak) Monitor *selected;
@property(weak) Client *osFocused;   /* managed window macOS reported focused at the last sync */
@property(weak) Client *hovered;
@property(strong) Client *dragClient;
@property(strong) NSString *status;
@property(strong) NSTimer *timer;
@property CFMachPortRef tap;
@property CFRunLoopSourceRef tapSource;
@property AXUIElementRef systemElement;
@property(strong) NSMutableIndexSet *heldKeys;
@property CGPoint dragStart, pointer;
@property DwmRect dragFrame;
@property CGFloat top;   /* height of the primary display, converts CG and AppKit y */
@property NSTimeInterval quietUntil;
@property int dragButton, lockFD;
@property BOOL pointerPending, syncPending, stopping, waiting, menuBarHidden;
@property(strong) dispatch_source_t interruptSource, terminateSource;
- (void)scheduleSync;
- (void)sync;
- (void)arrange;
- (void)focus:(Client *)client raise:(BOOL)raise;
- (void)action:(NSString *)name value:(int)value;
- (NSArray<Client *> *)visible:(Monitor *)m tiled:(BOOL)tiled;
- (CGEventRef)event:(CGEventRef)event type:(CGEventType)type;
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
		return event;
	}
	return [manager event:event type:type];
}

@implementation Manager
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
	(void)notification;
	self.lockFD = -1;
	NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/dwm"];
	NSError *error = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Cannot create %@: %@", support, error);
		[NSApp terminate:nil];
		return;
	}
	self.lockFD = open([[support stringByAppendingPathComponent:@"lock"] fileSystemRepresentation], O_CREAT|O_RDWR, 0600);
	if (self.lockFD < 0 || flock(self.lockFD, LOCK_EX|LOCK_NB) != 0) {
		NSLog(@"dwm is already running");
		[NSApp terminate:nil];
		return;
	}
	self.monitors = [NSMutableArray array];
	self.watches = [NSMutableDictionary dictionary];
	self.heldKeys = [NSMutableIndexSet indexSet];
	self.windows = @[];
	self.status = @"dwm";
	[self start];
}

/* Waits for the permissions instead of exiting: grant them in System Settings
 * and dwm picks up within a second, without a restart. */
- (void)start
{
	NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: self.waiting ? @NO : @YES};
	if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
		if (!self.waiting) NSLog(@"Waiting for Accessibility access (System Settings > Privacy & Security > Accessibility)");
		self.waiting = YES;
		[self performSelector:@selector(start) withObject:nil afterDelay:1];
		return;
	}
	CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|
		CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|
		CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|
		CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|
		CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged);
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
	/* global AX timeout: an unresponsive application must not stall the manager */
	self.systemElement = AXUIElementCreateSystemWide();
	AXUIElementSetMessagingTimeout(self.systemElement, 0.25);
	NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
	for (NSNotificationName name in @[NSWorkspaceDidLaunchApplicationNotification, NSWorkspaceDidTerminateApplicationNotification,
			NSWorkspaceDidActivateApplicationNotification, NSWorkspaceDidHideApplicationNotification,
			NSWorkspaceDidUnhideApplicationNotification, NSWorkspaceActiveSpaceDidChangeNotification])
		[workspace addObserver:self selector:@selector(scheduleSyncNotification:) name:name object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(screensChanged:) name:NSApplicationDidChangeScreenParametersNotification object:nil];
	[self screensChanged:nil];
	self.timer = [NSTimer timerWithTimeInterval:0.5 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
	[[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
	[self sync];
	signal(SIGINT, SIG_IGN);
	signal(SIGTERM, SIG_IGN);
	self.interruptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGINT, 0, dispatch_get_main_queue());
	self.terminateSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, SIGTERM, 0, dispatch_get_main_queue());
	dispatch_source_set_event_handler(self.interruptSource, ^{ [NSApp terminate:nil]; });
	dispatch_source_set_event_handler(self.terminateSource, ^{ [NSApp terminate:nil]; });
	dispatch_resume(self.interruptSource);
	dispatch_resume(self.terminateSource);
}

- (void)scheduleSyncNotification:(NSNotification *)notification
{
	(void)notification;
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
		if (!m) { m = [Monitor new]; m.display = display; }
		CGRect frame = CGDisplayBounds(display.unsignedIntValue);
		m.frame = (DwmRect){frame.origin.x, frame.origin.y, frame.size.width, frame.size.height};
		NSRect visible = screen.visibleFrame;   /* excludes menu bar, notch and Dock */
		CGFloat inset = menuBarInset;
		if (inset < 0 && menuBarHidden) inset = 0;   /* visibleFrame keeps reserving an auto-hidden menu bar */
		if (inset >= 0) {
			CGFloat top = NSMaxY(screen.frame) - inset;
			if (@available(macOS 12.0, *)) top = MIN(top, NSMaxY(screen.frame) - screen.safeAreaInsets.top);
			visible.size.height = top - visible.origin.y;
		}
		m.work = (DwmRect){visible.origin.x, self.top - NSMaxY(visible), visible.size.width, visible.size.height};
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
		NSLog(@"display %@: %gx%g, work area %gx%g at %g,%g%@%@", display, m.frame.w, m.frame.h, m.work.w, m.work.h, m.work.x, m.work.y,
			menuBarHidden ? @" (menu bar hides)" : @"", m.notchBar ? @", bar beside the notch" : @"");
		if (!m.panel) {
			m.panel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
			m.panel.level = NSFloatingWindowLevel;
			m.panel.hidesOnDeactivate = NO;
			m.panel.hasShadow = NO;
			m.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary|NSWindowCollectionBehaviorStationary;
			m.panel.backgroundColor = color(colNormBG);
			Bar *bar = [Bar new]; bar.manager = self; bar.monitor = m;
			m.panel.contentView = bar;
		}
		[next addObject:m];
	}
	if (!next.count) return;
	for (Monitor *old in self.monitors) if (![next containsObject:old]) {
		for (Client *c in [old.clients copy]) [self move:c to:next.firstObject relocate:YES];
		[old.panel close];
	}
	self.monitors = next;
	if (![next containsObject:self.selected]) self.selected = next.firstObject;
	/* display corners moved; park hidden windows again */
	for (Monitor *m in next) for (Client *c in m.clients) if (c.hidden) { c.hidden = NO; [self park:c]; }
	[self arrange];
}

- (Monitor *)monitorAt:(CGPoint)p
{
	for (Monitor *m in self.monitors)
		if (CGRectContainsPoint(CGRectMake(m.frame.x, m.frame.y, m.frame.w, m.frame.h), p)) return m;
	return self.selected ?: self.monitors.firstObject;
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

- (BOOL)onscreen:(pid_t)pid frame:(DwmRect)r
{
	for (NSDictionary *info in self.windows) {
		pid_t owner; CGRect bounds;
		if (windowInfo(info, &owner, &bounds) && owner == pid && matches(r, bounds)) return YES;
	}
	return NO;
}

/* the managed window on top at p, nil for the bar, the desktop or unmanaged windows */
- (Client *)clientAt:(CGPoint)p
{
	for (Monitor *m in self.monitors)
		if (m.panel.visible && NSPointInRect(NSMakePoint(p.x, self.top - p.y), m.panel.frame)) return nil;
	for (NSDictionary *info in self.windows) {
		pid_t owner; CGRect bounds;
		if (!windowInfo(info, &owner, &bounds) || !CGRectContainsPoint(bounds, p)) continue;
		for (Monitor *m in self.monitors) for (Client *c in m.clients)
			if (c.pid == owner && !c.hidden && !c.away && matches(c.frame, bounds)) return c;
		return nil;
	}
	return nil;
}

- (ApplicationWatch *)watch:(NSRunningApplication *)app
{
	NSNumber *pid = @(app.processIdentifier);
	if (self.watches[pid]) return self.watches[pid];
	ApplicationWatch *watch = [ApplicationWatch new];
	watch.element = AXUIElementCreateApplication(app.processIdentifier);
	AXObserverRef observer = NULL;
	if (AXObserverCreate(app.processIdentifier, observed, &observer) == kAXErrorSuccess) {
		watch.observer = observer;
		for (NSString *name in @[(__bridge NSString *)kAXWindowCreatedNotification, (__bridge NSString *)kAXFocusedWindowChangedNotification,
				(__bridge NSString *)kAXWindowMovedNotification, (__bridge NSString *)kAXWindowResizedNotification,
				(__bridge NSString *)kAXWindowMiniaturizedNotification, (__bridge NSString *)kAXWindowDeminiaturizedNotification,
				(__bridge NSString *)kAXTitleChangedNotification])
			AXObserverAddNotification(observer, watch.element, (__bridge CFStringRef)name, (__bridge void *)self);
		CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
	}
	self.watches[pid] = watch;
	return watch;
}

- (Client *)clientFor:(AXUIElementRef)element pid:(pid_t)pid
{
	for (Monitor *m in self.monitors) for (Client *c in m.clients)
		if (c.pid == pid && CFEqual(c.element, element)) return c;
	return nil;
}

- (Client *)manage:(AXUIElementRef)element pid:(pid_t)pid app:(NSRunningApplication *)app frame:(DwmRect)frame
{
	Client *c = [Client new];
	c.element = (AXUIElementRef)CFRetain(element);
	c.pid = pid;
	c.frame = frame;
	c.monitor = [self monitorAt:CGPointMake(frame.x + frame.w / 2, frame.y + frame.h / 2)];
	c.tags = c.monitor.tags;
	Boolean resizable = false;
	AXUIElementIsAttributeSettable(element, kAXSizeAttribute, &resizable);
	NSString *subrole = attribute(element, kAXSubroleAttribute);
	c.floating = !resizable || ![subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole];
	NSString *title = attribute(element, kAXTitleAttribute) ?: @"";
	for (size_t i = 0; i < LENGTH(rules); ++i) {
		if (rules[i].bundle && ![app.bundleIdentifier isEqual:rules[i].bundle]) continue;
		if (rules[i].title && ![title containsString:rules[i].title]) continue;
		c.floating = rules[i].floating;
		if (rules[i].monitor >= 0 && rules[i].monitor < (int)self.monitors.count) c.monitor = self.monitors[rules[i].monitor];
		c.tags = (rules[i].tags & DWM_TAGMASK) ?: c.monitor.tags;
	}
	[c.monitor.clients insertObject:c atIndex:0];
	[c.monitor.history insertObject:c atIndex:0];
	NSLog(@"manage %@ \"%@\" %gx%g at %g,%g%@ tags %u", app.localizedName, title, frame.w, frame.h, frame.x, frame.y, c.floating ? @" floating" : @"", c.tags);
	ApplicationWatch *watch = self.watches[@(pid)];
	if (watch.observer) AXObserverAddNotification(watch.observer, element, kAXUIElementDestroyedNotification, (__bridge void *)self);
	return c;
}

- (BOOL)forget:(pid_t)pid except:(NSSet *)seen
{
	BOOL changed = NO;
	for (Monitor *m in self.monitors) for (Client *c in [m.clients copy]) {
		if (c.pid != pid || [seen containsObject:c]) continue;
		[m.clients removeObject:c];
		[m.history removeObject:c];
		if (m.selected == c) m.selected = nil;
		if (self.dragClient == c) self.dragClient = nil;
		NSLog(@"unmanage \"%@\"", c.title);
		changed = YES;
	}
	return changed;
}

/* Reconciles the model with what macOS reports. Runs on notifications and
 * every half second as a fallback for applications with poor AX support. */
- (void)sync
{
	self.syncPending = NO;
	[self refreshWindows];
	BOOL changed = NO;
	Client *focused = nil;
	NSMutableSet *live = [NSMutableSet set];
	for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
		if (app.processIdentifier == getpid() || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
		pid_t pid = app.processIdentifier;
		[live addObject:@(pid)];
		ApplicationWatch *watch = [self watch:app];
		NSArray *windows = attribute(watch.element, kAXWindowsAttribute);
		if (!windows) continue;   /* unresponsive: keep what we know */
		id focusedWindow = app.active ? attribute(watch.element, kAXFocusedWindowAttribute) : nil;
		NSMutableSet *seen = [NSMutableSet set];
		for (id object in windows) {
			AXUIElementRef element = (__bridge AXUIElementRef)object;
			if (![attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) continue;
			Client *c = [self clientFor:element pid:pid];
			DwmRect frame = geometry(element);
			BOOL onscreen = [self onscreen:pid frame:frame];
			if (!c) {
				/* manage windows when they appear on the current Space */
				if (frame.w <= 0 || frame.h <= 0 || !onscreen) continue;
				c = [self manage:element pid:pid app:app frame:frame];
				changed = YES;
			}
			[seen addObject:c];
			c.title = attribute(element, kAXTitleAttribute) ?: app.localizedName ?: @"";
			BOOL nativeFullscreen = [attribute(element, CFSTR("AXFullScreen")) boolValue];
			BOOL away = app.hidden || [attribute(element, kAXMinimizedAttribute) boolValue] || (!c.hidden && !onscreen);
			if (c.away != away || c.nativeFullscreen != nativeFullscreen) changed = YES;
			c.away = away;
			c.nativeFullscreen = nativeFullscreen;
			if (!c.hidden && !away) c.frame = frame;   /* follow moves the user made */
			if (focusedWindow && CFEqual(element, (__bridge CFTypeRef)focusedWindow)) focused = c;
		}
		if ([self forget:pid except:seen]) changed = YES;
	}
	for (NSNumber *pid in self.watches.allKeys) if (![live containsObject:pid]) {
		[self.watches removeObjectForKey:pid];
		if ([self forget:pid.intValue except:nil]) changed = YES;
	}
	/* Follow focus changes made outside dwm: clicks, Cmd-Tab, the Dock. When the
	 * user reaches a window on a hidden tag this way, view that tag. */
	if (focused != self.osFocused) {
		self.osFocused = focused;
		Monitor *m = focused.monitor;
		if (m && !focused.away && !focused.nativeFullscreen) {
			if (!(focused.tags & m.tags) && !self.dragClient) { m.previousTags = m.tags; m.tags = focused.tags; changed = YES; }
			self.selected = m;
			m.selected = focused;
			[m.history removeObject:focused];
			[m.history insertObject:focused atIndex:0];
		}
	}
	if (changed && !self.dragClient) [self arrange];
	for (Monitor *m in self.monitors) [m.panel.contentView setNeedsDisplay:YES];
}

- (void)tick:(NSTimer *)timer
{
	(void)timer;
	NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/dwm/status"];
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
	if (menuBarAutoHides() != self.menuBarHidden) [self screensChanged:nil];
	[self sync];
}

- (void)resize:(Client *)c frame:(DwmRect)r
{
	if (!c || c.nativeFullscreen) return;
	r.x = round(r.x); r.y = round(r.y);
	r.w = MAX(1, round(r.w)); r.h = MAX(1, round(r.h));
	if (c.hidden) { c.frame = r; return; }   /* applied when the window is shown */
	if (fabs(c.frame.x - r.x) < 1 && fabs(c.frame.y - r.y) < 1 && fabs(c.frame.w - r.w) < 1 && fabs(c.frame.h - r.h) < 1) return;
	BOOL ok = setSize(c.element, CGSizeMake(r.w, r.h));
	ok = setPosition(c.element, CGPointMake(r.x, r.y)) && ok;
	if (!ok && !c.geometryFailed) NSLog(@"Window refused geometry: %@", c.title);
	c.geometryFailed = !ok;
	c.frame = r;
}

/* hidden tags: park the window one point inside the display's bottom-right corner */
- (void)park:(Client *)c
{
	if (c.hidden) return;
	DwmRect f = c.monitor.frame;
	c.hidden = setPosition(c.element, CGPointMake(f.x + f.w - 1, f.y + f.h - 1));
	if (!c.hidden && !c.geometryFailed) NSLog(@"Window refused to hide: %@", c.title);
	c.geometryFailed = !c.hidden;
}

- (void)unpark:(Client *)c
{
	if (!c.hidden) return;
	c.hidden = NO;
	setSize(c.element, CGSizeMake(c.frame.w, c.frame.h));
	setPosition(c.element, CGPointMake(c.frame.x, c.frame.y));
}

- (void)move:(Client *)c to:(Monitor *)target relocate:(BOOL)relocate
{
	Monitor *source = c.monitor;
	if (source == target) return;
	[source.clients removeObject:c];
	[source.history removeObject:c];
	if (source.selected == c) source.selected = nil;
	c.monitor = target;
	[target.clients insertObject:c atIndex:0];
	[target.history insertObject:c atIndex:0];
	if (relocate && c.floating && !c.fullscreen) {
		DwmRect r = c.frame, a = [self area:target];
		r.x = a.x;
		r.y = a.y;
		[self resize:c frame:r];
	}
}

- (void)arrange
{
	for (Monitor *m in self.monitors) {
		BOOL covered = NO;
		for (Client *c in m.clients) if (!c.away && ((c.fullscreen && (c.tags & m.tags)) || c.nativeFullscreen)) covered = YES;
		DwmRect area = [self area:m];
		for (;;) {
			DwmRect bar = m.notchBar ? m.bar : (DwmRect){m.work.x, topBar ? m.work.y : m.work.y + m.work.h - barHeight, m.work.w, barHeight};
			if (!m.showbar || covered) { [m.panel orderOut:nil]; break; }
			NSRect frame = NSMakeRect(bar.x, self.top - bar.y - bar.h, bar.w, bar.h);
			[m.panel setFrame:frame display:YES];
			if (m.notchBar && fabs(m.panel.frame.origin.y - frame.origin.y) > 1) {
				/* AppKit refused the notch strip: fall back to a bar inside the work area */
				NSLog(@"bar cannot use the notch strip on display %@", m.display);
				m.notchBar = NO;
				area = [self area:m];
				continue;
			}
			[m.panel orderFrontRegardless];
			break;
		}
		for (Client *c in m.clients) {
			if (c.away || c.nativeFullscreen) continue;
			if (c.tags & m.tags) [self unpark:c]; else [self park:c];
		}
		NSArray<Client *> *tiled = [self visible:m tiled:YES];
		for (NSUInteger i = 0; i < tiled.count; ++i) {
			if (m.layout == Tile) [self resize:tiled[i] frame:dwm_tile(area, i, tiled.count, m.masters, m.factor)];
			else if (m.layout == Monocle) [self resize:tiled[i] frame:area];
		}
		for (Client *c in [self visible:m tiled:NO]) if (c.fullscreen) [self resize:c frame:m.work];
		if (![self isVisible:m.selected] || m.selected.monitor != m) {
			m.selected = nil;
			for (Client *c in m.history) if ([self isVisible:c]) { m.selected = c; break; }
		}
		[m.panel.contentView setNeedsDisplay:YES];
	}
	/* windows just moved under a resting pointer must not steal focus (dwm drains EnterNotify) */
	self.quietUntil = [NSDate timeIntervalSinceReferenceDate] + 0.3;
}

- (void)focus:(Client *)c raise:(BOOL)raise
{
	if (![self isVisible:c]) return;
	Client *current = self.selected.selected;
	if (lockFullscreen && current && current != c && current.fullscreen && current.monitor == c.monitor && [self isVisible:current]) return;
	self.selected = c.monitor;
	c.monitor.selected = c;
	[c.monitor.history removeObject:c];
	[c.monitor.history insertObject:c atIndex:0];
	for (Monitor *m in self.monitors) [m.panel.contentView setNeedsDisplay:YES];
	/* raise the window inside its application first so activation brings this one forward */
	if (raise) {
		setAttribute(c.element, kAXMainAttribute, @YES);
		AXUIElementPerformAction(c.element, kAXRaiseAction);
	}
	if (self.osFocused != c) {
		setAttribute(self.watches[@(c.pid)].element, kAXFocusedWindowAttribute, (__bridge id)c.element);
		NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:c.pid];
		if (!app.active) [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
	}
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
	} else if ([name isEqual:@"toggleview"]) {
		unsigned next = dwm_tags(m.tags, (unsigned)value, 1);
		if (next != m.tags) { m.previousTags = m.tags; m.tags = next; }
	} else if ([name isEqual:@"tag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 0);
	else if ([name isEqual:@"toggletag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 1);
	else if ([name isEqual:@"togglebar"]) m.showbar = !m.showbar;
	else if ([name isEqual:@"incnmaster"]) m.masters = MAX(0, m.masters + value);
	else if ([name isEqual:@"setmfact"]) m.factor = MAX(0.05, MIN(0.95, m.factor + value * 0.05));
	else if ([name isEqual:@"setlayout"]) {
		int next = value < 0 ? m.previousLayout : MIN(value, Monocle);
		if (next != m.layout) { m.previousLayout = m.layout; m.layout = next; }
	} else if ([name isEqual:@"togglefloating"] && c && !c.fullscreen) c.floating = !c.floating;
	else if ([name isEqual:@"togglefullscr"] && c && !c.nativeFullscreen) {
		if (!c.fullscreen) { c.saved = c.frame; c.wasFloating = c.floating; c.fullscreen = YES; c.floating = YES; }
		else { c.fullscreen = NO; c.floating = c.wasFloating; [self resize:c frame:c.saved]; }
	} else if ([name isEqual:@"killclient"] && c) {
		id close = attribute(c.element, kAXCloseButtonAttribute);
		if (close) AXUIElementPerformAction((__bridge AXUIElementRef)close, kAXPressAction);
	} else if ([name isEqual:@"focusstack"]) {
		NSArray *visible = [self visible:m tiled:NO];
		if (visible.count) {
			NSUInteger index = [visible indexOfObject:c];
			int next = index == NSNotFound ? 0 : dwm_monitor((int)index, value, (int)visible.count);
			[self focus:visible[next] raise:YES];
		}
	} else if ([name isEqual:@"zoom"] && c && m.layout != Float && !c.floating && !c.fullscreen) {
		NSArray *tiled = [self visible:m tiled:YES];
		Client *target = c == tiled.firstObject && tiled.count > 1 ? tiled[1] : c;
		[m.clients removeObject:target];
		[m.clients insertObject:target atIndex:0];
		m.selected = target;
	} else if ([name isEqual:@"focusmon"] || [name isEqual:@"tagmon"]) {
		Monitor *target = self.monitors[dwm_monitor((int)[self.monitors indexOfObject:m], value, (int)self.monitors.count)];
		if ([name isEqual:@"tagmon"] && c && target != m) {
			[self move:c to:target relocate:YES];
			c.tags = target.tags;
			target.selected = c;
		}
		self.selected = target;
	}
	[self arrange];
	Client *selected = self.selected.selected;
	if (selected) [self focus:selected raise:YES];
	else if (self.osFocused && ![self isVisible:self.osFocused]) [NSApp activateIgnoringOtherApps:YES];   /* keys must not reach a hidden window */
}

/* sloppy focus, coalesced to one hit test per run loop pass */
- (void)hover
{
	Client *c = [self clientAt:self.pointer];
	if (c == self.hovered) return;
	self.hovered = c;
	if ([NSDate timeIntervalSinceReferenceDate] < self.quietUntil) return;
	if (c) {
		if (c != self.selected.selected) [self focus:c raise:NO];
		return;
	}
	Monitor *m = [self monitorAt:self.pointer];
	if (m == self.selected) return;
	self.selected = m;
	[self focus:m.selected raise:NO];
	for (Monitor *each in self.monitors) [each.panel.contentView setNeedsDisplay:YES];
}

- (CGEventRef)event:(CGEventRef)event type:(CGEventType)type
{
	CGEventFlags flags = CGEventGetFlags(event) & (ALT|SHIFT|CTRL|kCGEventFlagMaskCommand);
	if (type == kCGEventKeyDown || type == kCGEventKeyUp) {
		CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
		if (type == kCGEventKeyUp) {
			if ([self.heldKeys containsIndex:code]) { [self.heldKeys removeIndex:code]; return NULL; }
			return event;
		}
		for (size_t i = 0; i < LENGTH(keys); ++i) if (keys[i].code == code && keys[i].modifiers == flags) {
			[self.heldKeys addIndex:code];
			NSString *action = keys[i].action;
			int value = keys[i].value;
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
				if (!self.stopping && !self.dragClient) [self hover];
			});
		}
		return event;
	}
	BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
	BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
	int button = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
	if (down && flags == ALT && button <= 2 && !self.dragClient) {
		[self refreshWindows];
		Client *c = [self clientAt:p];
		if (!c || c.fullscreen) return event;
		[self focus:c raise:YES];
		if (button == 2) { [self action:@"togglefloating" value:0]; return NULL; }
		self.dragClient = c;
		self.dragButton = button;
		self.dragStart = p;
		self.dragFrame = c.frame;
		return NULL;
	}
	if (up && self.dragClient && button == self.dragButton) {
		Client *c = self.dragClient;
		self.dragClient = nil;
		Monitor *target = [self monitorAt:CGPointMake(c.frame.x + c.frame.w / 2, c.frame.y + c.frame.h / 2)];
		if (target != c.monitor) { [self move:c to:target relocate:NO]; c.tags = target.tags; }
		[self arrange];
		[self focus:c raise:YES];
		return NULL;
	}
	if ((type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) && self.dragClient) {
		Client *c = self.dragClient;
		DwmRect r = self.dragFrame;
		double dx = p.x - self.dragStart.x, dy = p.y - self.dragStart.y;
		if (!c.floating && c.monitor.layout != Float && fabs(dx) < snapDistance && fabs(dy) < snapDistance) return NULL;
		c.floating = YES;
		if (self.dragButton == 0) {
			Monitor *target = [self monitorAt:p];
			DwmRect a = [self area:target];
			r.x += dx; r.y += dy;
			if (fabs(r.x - a.x) < snapDistance) r.x = a.x;
			if (fabs(r.y - a.y) < snapDistance) r.y = a.y;
			if (fabs(r.x + r.w - a.x - a.w) < snapDistance) r.x = a.x + a.w - r.w;
			if (fabs(r.y + r.h - a.y - a.h) < snapDistance) r.y = a.y + a.h - r.h;
		} else {
			r.w = MAX(1, r.w + dx);
			r.h = MAX(1, r.h + dy);
		}
		[self resize:c frame:r];
		return NULL;
	}
	return event;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	(void)notification;
	self.stopping = YES;
	[self.timer invalidate];
	[NSObject cancelPreviousPerformRequestsWithTarget:self];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
	if (self.tap) { CGEventTapEnable(self.tap, false); CFMachPortInvalidate(self.tap); CFRelease(self.tap); self.tap = NULL; }
	if (self.tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes); CFRelease(self.tapSource); self.tapSource = NULL; }
	for (Monitor *m in self.monitors) {
		for (Client *c in m.clients) {
			if (c.fullscreen) { c.fullscreen = NO; [self resize:c frame:c.saved]; }
			[self unpark:c];
		}
		[m.panel close];
	}
	[self.watches removeAllObjects];
	if (self.systemElement) { CFRelease(self.systemElement); self.systemElement = NULL; }
	if (self.interruptSource) dispatch_source_cancel(self.interruptSource);
	if (self.terminateSource) dispatch_source_cancel(self.terminateSource);
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

- (NSString *)symbol
{
	Monitor *m = self.monitor;
	if (m.layout != Monocle) return layoutNames[m.layout];
	return [NSString stringWithFormat:@"[%lu]", (unsigned long)[self.manager visible:m tiled:YES].count];
}

- (void)drawText:(NSString *)text x:(CGFloat)x width:(CGFloat)w selected:(BOOL)selected
{
	CGFloat h = self.bounds.size.height;
	[color(selected ? colSelBG : colNormBG) setFill];
	NSRectFill(NSMakeRect(x, 0, w, h));
	NSFont *font = barFont();
	NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
	style.lineBreakMode = NSLineBreakByTruncatingTail;
	NSDictionary *attributes = @{NSFontAttributeName: font, NSForegroundColorAttributeName: color(selected ? colSelFG : colNormFG), NSParagraphStyleAttributeName: style};
	CGFloat y = floor((h - (font.ascender - font.descender)) / 2);
	[text drawInRect:NSMakeRect(x + fontSize / 2, y, MAX(0, w - fontSize), h - y) withAttributes:attributes];
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
		sw = MIN([self width:manager.status], MAX(0, w - (m.notchBar ? m.gapEnd : x)));
		[self drawText:manager.status x:w - sw width:sw selected:NO];
		titleEnd = w - sw;
	}
	if (m.notchBar) titleEnd = MIN(titleEnd, m.gapStart);   /* the title stops at the notch */
	if (titleEnd > x) {
		Client *c = m.selected;
		if (c) {
			[self drawText:c.title x:x width:titleEnd - x selected:m == manager.selected];
			if (c.floating) { [color(m == manager.selected ? colSelFG : colNormFG) setFill]; NSFrameRect(NSMakeRect(x + 2, 2, box, box)); }
		}
	}
}

- (void)click:(NSEvent *)event
{
	Manager *manager = self.manager;
	Monitor *m = self.monitor;
	if (manager.selected != m) { manager.selected = m; [manager action:@"focusmon" value:0]; }
	CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x, w = self.bounds.size.width, edge = 0;
	BOOL alt = (event.modifierFlags & NSEventModifierFlagOption) != 0;
	BOOL right = event.buttonNumber == 1, middle = event.buttonNumber == 2;
	for (size_t i = 0; i < LENGTH(tagNames); ++i) {
		edge += [self width:tagNames[i]];
		if (x < edge) {
			if (!middle) [manager action:alt ? (right ? @"toggletag" : @"tag") : (right ? @"toggleview" : @"view") value:(int)(1u << i)];
			return;
		}
	}
	edge += [self width:self.symbol];
	if (x < edge) {
		if (!middle) [manager action:@"setlayout" value:right ? Monocle : -1];
		return;
	}
	if (!middle) return;
	CGFloat sw = MIN([self width:manager.status], MAX(0, w - (m.notchBar ? m.gapEnd : edge)));
	if (m.notchBar && x >= m.gapStart && x < w - sw) return;
	[manager action:x >= w - sw ? @"spawn" : @"zoom" value:0];
}

- (void)mouseDown:(NSEvent *)event { [self click:event]; }
- (void)rightMouseDown:(NSEvent *)event { [self click:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self click:event]; }
@end

int main(void)
{
	@autoreleasepool {
		NSApplication *app = NSApplication.sharedApplication;
		[app setActivationPolicy:NSApplicationActivationPolicyAccessory];
		__attribute__((objc_precise_lifetime)) Manager *manager = [Manager new];
		app.delegate = manager;
		[app run];
	}
	return 0;
}
