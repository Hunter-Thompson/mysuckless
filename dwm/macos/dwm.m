#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#import <signal.h>
#import <sys/file.h>
#import <unistd.h>
#import <fcntl.h>
#import <math.h>
#import <dispatch/dispatch.h>
#import "model.h"
#import "config.h"

static id attribute(AXUIElementRef element, CFStringRef name)
{
	CFTypeRef value = NULL;
	if (AXUIElementCopyAttributeValue(element, name, &value) != kAXErrorSuccess) return nil;
	return CFBridgingRelease(value);
}

static BOOL setAttribute(AXUIElementRef element, CFStringRef name, id value)
{
	return AXUIElementSetAttributeValue(element, name, (__bridge CFTypeRef)value) == kAXErrorSuccess;
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

@class Manager, Monitor;
@interface Client : NSObject
@property AXUIElementRef element;
@property pid_t pid;
@property unsigned tags;
@property BOOL floating, fullscreen, wasFloating, hidden, minimized, nativeFullscreen;
@property BOOL geometryFailed, visibilityFailed;
@property DwmRect saved;
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
@property DwmRect frame, work;
@property unsigned tags, previousTags;
@property int layout, previousLayout, masters;
@property double factor;
@property BOOL showbar;
@property(strong) NSMutableArray<Client *> *clients;
@property(strong) NSMutableArray<Client *> *history;
@property(weak) Client *selected;
@property(strong) NSPanel *panel;
@end
@implementation Monitor
- (instancetype)init
{
	if ((self = [super init])) {
		_tags = _previousTags = 1;
		_previousLayout = 1;
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
@property(weak) Monitor *selected;
@property(strong) NSString *status;
@property(strong) NSTimer *timer;
@property CFMachPortRef tap;
@property CFRunLoopSourceRef tapSource;
@property(strong) NSMutableIndexSet *heldKeys;
@property(strong) Client *dragClient;
@property CGPoint dragStart;
@property CGPoint pointer;
@property(weak) Client *hovered;
@property BOOL pointerPending;
@property DwmRect dragFrame;
@property int dragButton;
@property BOOL dirty, stopping;
@property(strong) dispatch_source_t interruptSource, terminateSource;
@property int lockFD;
- (void)sync;
- (void)arrange;
- (void)focus:(Client *)client;
- (void)action:(NSString *)name value:(int)value;
- (CGEventRef)event:(CGEventRef)event type:(CGEventType)type;
@end

static void observed(AXObserverRef observer, AXUIElementRef element, CFStringRef notification, void *context)
{
	(void)observer; (void)element; (void)notification;
	((__bridge Manager *)context).dirty = YES;
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
	NSDictionary *options = @{(__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES};
	if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
		NSLog(@"Grant Accessibility access to dwm-macos in System Settings, then restart.");
		[NSApp terminate:nil];
		return;
	}
	NSString *support = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/dwm"];
	NSError *error = nil;
	if (![[NSFileManager defaultManager] createDirectoryAtPath:support withIntermediateDirectories:YES attributes:nil error:&error]) {
		NSLog(@"Cannot create state directory: %@", error);
		[NSApp terminate:nil];
		return;
	}
	self.lockFD = open([[support stringByAppendingPathComponent:@"lock"] fileSystemRepresentation], O_CREAT|O_RDWR, 0600);
	if (self.lockFD < 0 || flock(self.lockFD, LOCK_EX|LOCK_NB) != 0) {
		NSLog(@"Cannot acquire dwm lock; another instance may be running.");
		[NSApp terminate:nil];
		return;
	}
	self.monitors = [NSMutableArray array];
	self.watches = [NSMutableDictionary dictionary];
	self.heldKeys = [NSMutableIndexSet indexSet];
	self.status = @"dwm";
	CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)|CGEventMaskBit(kCGEventKeyUp)|
		CGEventMaskBit(kCGEventLeftMouseDown)|CGEventMaskBit(kCGEventLeftMouseUp)|
		CGEventMaskBit(kCGEventRightMouseDown)|CGEventMaskBit(kCGEventRightMouseUp)|
		CGEventMaskBit(kCGEventOtherMouseDown)|CGEventMaskBit(kCGEventOtherMouseUp)|
		CGEventMaskBit(kCGEventLeftMouseDragged)|CGEventMaskBit(kCGEventRightMouseDragged)|
		CGEventMaskBit(kCGEventMouseMoved);
	self.tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault, mask, input, (__bridge void *)self);
	if (!self.tap) {
		NSLog(@"Cannot capture input. Grant Accessibility and Input Monitoring access, then restart.");
		[NSApp terminate:nil];
		return;
	}
	self.tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.tap, 0);
	CFRunLoopAddSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes);
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

- (void)screensChanged:(NSNotification *)notification
{
	(void)notification;
	NSMutableArray *next = [NSMutableArray array];
	CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
	for (NSScreen *screen in NSScreen.screens) {
		NSNumber *display = screen.deviceDescription[@"NSScreenNumber"];
		Monitor *m = nil;
		for (Monitor *existing in self.monitors) if ([existing.display isEqual:display]) m = existing;
		if (!m) { m = [Monitor new]; m.display = display; }
		CGRect frame = CGDisplayBounds(display.unsignedIntValue);
		m.frame = (DwmRect){frame.origin.x, frame.origin.y, frame.size.width, frame.size.height};
		NSRect visible = screen.visibleFrame;
		m.work = (DwmRect){visible.origin.x, top - NSMaxY(visible), visible.size.width, visible.size.height};
		if (!m.panel) {
			m.panel = [[NSPanel alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskBorderless|NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
			m.panel.level = NSFloatingWindowLevel;
			m.panel.hidesOnDeactivate = NO;
			m.panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces|NSWindowCollectionBehaviorFullScreenAuxiliary;
			m.panel.backgroundColor = [NSColor colorWithWhite:0.13 alpha:1];
			Bar *bar = [Bar new]; bar.manager = self; bar.monitor = m;
			m.panel.contentView = bar;
		}
		[next addObject:m];
	}
	if (!next.count) return;
	for (Monitor *old in self.monitors) if (![next containsObject:old]) {
		Monitor *target = next.firstObject;
		for (Client *c in old.clients) { c.monitor = target; [target.clients addObject:c]; [target.history addObject:c]; }
		[old.panel close];
	}
	self.monitors = next;
	if (![next containsObject:self.selected]) self.selected = next.firstObject;
	[self arrange];
}

- (Monitor *)monitorAt:(CGPoint)p
{
	for (Monitor *m in self.monitors)
		if (CGRectContainsPoint(CGRectMake(m.frame.x, m.frame.y, m.frame.w, m.frame.h), p)) return m;
	return self.selected ?: self.monitors.firstObject;
}

- (NSArray<Client *> *)visible:(Monitor *)m tiled:(BOOL)tiled
{
	NSMutableArray *result = [NSMutableArray array];
	for (Client *c in m.clients)
		if ((c.tags & m.tags) && !c.minimized && !c.nativeFullscreen && (!tiled || (!c.floating && !c.fullscreen))) [result addObject:c];
	return result;
}

- (void)watch:(NSRunningApplication *)app
{
	NSNumber *pid = @(app.processIdentifier);
	if (self.watches[pid]) return;
	ApplicationWatch *watch = [ApplicationWatch new];
	watch.element = AXUIElementCreateApplication(app.processIdentifier);
	AXUIElementSetMessagingTimeout(watch.element, 0.1);
	AXObserverRef observer = NULL;
	if (AXObserverCreate(app.processIdentifier, observed, &observer) == kAXErrorSuccess) {
		watch.observer = observer;
		for (NSString *name in @[(__bridge NSString *)kAXWindowCreatedNotification, (__bridge NSString *)kAXFocusedWindowChangedNotification])
			AXObserverAddNotification(observer, watch.element, (__bridge CFStringRef)name, (__bridge void *)self);
		CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), kCFRunLoopCommonModes);
	}
	self.watches[pid] = watch;
}

- (void)sync
{
	BOOL changed = self.dirty;
	self.dirty = NO;
	NSMutableSet *livePids = [NSMutableSet set];
	for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
		if (app.processIdentifier == getpid() || app.activationPolicy != NSApplicationActivationPolicyRegular) continue;
		NSNumber *pid = @(app.processIdentifier);
		[livePids addObject:pid];
		[self watch:app];
		ApplicationWatch *watch = self.watches[pid];
		NSArray *windows = attribute(watch.element, kAXWindowsAttribute);
		if (!windows) continue;
		NSMutableSet *seen = [NSMutableSet set];
		for (id object in windows) {
			AXUIElementRef element = (__bridge AXUIElementRef)object;
			NSString *role = attribute(element, kAXRoleAttribute);
			if (![role isEqual:(__bridge NSString *)kAXWindowRole]) continue;
			Client *c = nil;
			for (Monitor *m in self.monitors) for (Client *candidate in m.clients)
				if (candidate.pid == app.processIdentifier && CFEqual(candidate.element, element)) c = candidate;
			if (!c) {
				DwmRect frame = geometry(element);
				if (frame.w <= 0 || frame.h <= 0) continue;
				c = [Client new]; c.element = (AXUIElementRef)CFRetain(element); c.pid = app.processIdentifier;
				c.monitor = [self monitorAt:CGPointMake(frame.x + frame.w/2, frame.y + frame.h/2)];
				c.tags = c.monitor.tags;
				NSString *subrole = attribute(element, kAXSubroleAttribute);
				c.floating = ![subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole];
				Boolean resizable = false;
				AXUIElementIsAttributeSettable(element, kAXSizeAttribute, &resizable);
				c.floating |= !resizable;
				NSString *title = attribute(element, kAXTitleAttribute) ?: @"";
				for (size_t i = 0; i < sizeof(rules)/sizeof(rules[0]); ++i) {
					if (rules[i].bundle && ![app.bundleIdentifier isEqual:rules[i].bundle]) continue;
					if (rules[i].title && ![title containsString:rules[i].title]) continue;
					c.floating = rules[i].floating;
					if (rules[i].monitor >= 0 && rules[i].monitor < (int)self.monitors.count) c.monitor = self.monitors[rules[i].monitor];
					c.tags = (rules[i].tags & DWM_TAGMASK) ?: c.monitor.tags;
				}
				[c.monitor.clients insertObject:c atIndex:0]; [c.monitor.history insertObject:c atIndex:0];
				if (watch.observer) for (NSString *name in @[(__bridge NSString *)kAXUIElementDestroyedNotification, (__bridge NSString *)kAXWindowMiniaturizedNotification, (__bridge NSString *)kAXWindowDeminiaturizedNotification, (__bridge NSString *)kAXTitleChangedNotification])
					AXObserverAddNotification(watch.observer, element, (__bridge CFStringRef)name, (__bridge void *)self);
				changed = YES;
			}
			[seen addObject:c];
			c.title = attribute(element, kAXTitleAttribute) ?: app.localizedName ?: @"";
			BOOL minimized = [attribute(element, kAXMinimizedAttribute) boolValue];
			BOOL nativeFullscreen = [attribute(element, CFSTR("AXFullScreen")) boolValue];
			if (c.hidden && !minimized) { c.hidden = NO; changed = YES; }
			BOOL userMinimized = minimized && !c.hidden;
			if (c.minimized != userMinimized || c.nativeFullscreen != nativeFullscreen) changed = YES;
			c.minimized = userMinimized; c.nativeFullscreen = nativeFullscreen;
		}
		for (Monitor *m in self.monitors) for (Client *c in [m.clients copy])
			if (c.pid == app.processIdentifier && ![seen containsObject:c]) { [m.clients removeObject:c]; [m.history removeObject:c]; changed = YES; }
		if (app.active) {
			id focused = attribute(watch.element, kAXFocusedWindowAttribute);
			for (Client *c in seen) if (focused && CFEqual(c.element, (__bridge CFTypeRef)focused) && (c.tags & c.monitor.tags) && !c.minimized) {
				self.selected = c.monitor; c.monitor.selected = c;
				[c.monitor.history removeObject:c]; [c.monitor.history insertObject:c atIndex:0];
			}
		}
	}
	for (NSNumber *pid in [self.watches.allKeys copy]) if (![livePids containsObject:pid]) {
		[self.watches removeObjectForKey:pid];
		for (Monitor *m in self.monitors) for (Client *c in [m.clients copy])
			if (c.pid == pid.intValue) { [m.clients removeObject:c]; [m.history removeObject:c]; changed = YES; }
	}
	if (changed && !self.dragClient) [self arrange];
	for (Monitor *m in self.monitors) [m.panel.contentView setNeedsDisplay:YES];
}

- (void)tick:(NSTimer *)timer
{
	(void)timer;
	NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/dwm/status"];
	NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
	NSData *data = [file readDataUpToLength:4096 error:NULL];
	[file closeFile];
	self.status = data ? ([[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"dwm") : @"dwm";
	[self sync];
}

- (void)resize:(Client *)c frame:(DwmRect)r
{
	if (c.nativeFullscreen) return;
	DwmRect old = geometry(c.element);
	if (fabs(old.x-r.x)<1 && fabs(old.y-r.y)<1 && fabs(old.w-r.w)<1 && fabs(old.h-r.h)<1) return;
	CGPoint p = CGPointMake(round(r.x), round(r.y));
	CGSize s = CGSizeMake(MAX(1, round(r.w)), MAX(1, round(r.h)));
	id position = CFBridgingRelease(AXValueCreate(kAXValueCGPointType, &p));
	id size = CFBridgingRelease(AXValueCreate(kAXValueCGSizeType, &s));
	BOOL ok = setAttribute(c.element, kAXSizeAttribute, size);
	ok = setAttribute(c.element, kAXPositionAttribute, position) && ok;
	if (!ok && !c.geometryFailed) NSLog(@"Application refused window geometry: %@", c.title);
	c.geometryFailed = !ok;
}

- (void)arrange
{
	CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
	for (Monitor *m in self.monitors) {
		DwmRect area = m.work;
		CGFloat barY = topBar ? area.y : area.y + area.h - barHeight;
		[m.panel setFrame:NSMakeRect(area.x, top-barY-barHeight, area.w, barHeight) display:YES];
		BOOL fullscreen = NO;
		for (Client *c in [self visible:m tiled:NO]) fullscreen |= c.fullscreen;
		if (m.showbar) { if (fullscreen) [m.panel orderOut:nil]; else [m.panel orderFrontRegardless]; area.h -= barHeight; if (topBar) area.y += barHeight; }
		else [m.panel orderOut:nil];
		for (Client *c in m.clients) {
			BOOL hide = !(c.tags & m.tags);
			if (c.nativeFullscreen) continue;
			if (hide && !c.hidden && !c.minimized) {
				c.hidden = setAttribute(c.element, kAXMinimizedAttribute, @YES);
				if (!c.hidden && !c.visibilityFailed) NSLog(@"Cannot hide %@; this window does not support native tags", c.title);
				c.visibilityFailed = !c.hidden;
			} else if (!hide && c.hidden && setAttribute(c.element, kAXMinimizedAttribute, @NO)) c.hidden = NO;
		}
		NSArray<Client *> *tiled = [self visible:m tiled:YES];
		for (NSUInteger i = 0; i < tiled.count; ++i) {
			if (m.layout == 0) [self resize:tiled[i] frame:dwm_tile(area, i, tiled.count, m.masters, m.factor)];
			else if (m.layout == 2) [self resize:tiled[i] frame:area];
		}
		for (Client *c in [self visible:m tiled:NO]) if (c.fullscreen) [self resize:c frame:m.frame];
		if (![[self visible:m tiled:NO] containsObject:m.selected]) {
			m.selected = nil;
			for (Client *c in m.history) if ([[self visible:m tiled:NO] containsObject:c]) { m.selected = c; break; }
		}
		[m.panel.contentView setNeedsDisplay:YES];
	}
}

- (void)focus:(Client *)c
{
	if (!c || c.hidden || c.minimized || c.nativeFullscreen) return;
	Client *current = self.selected.selected;
	if (lockFullscreen && current.fullscreen && current != c && current.monitor == c.monitor && (current.tags & current.monitor.tags)) return;
	self.selected = c.monitor; c.monitor.selected = c;
	[c.monitor.history removeObject:c]; [c.monitor.history insertObject:c atIndex:0];
	NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:c.pid];
	[app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
	ApplicationWatch *watch = self.watches[@(c.pid)];
	setAttribute(watch.element, kAXFocusedWindowAttribute, (__bridge id)c.element);
	AXUIElementPerformAction(c.element, kAXRaiseAction);
}

- (void)spawn:(NSString *)command
{
	NSTask *task = [NSTask new];
	task.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
	task.arguments = @[@"-c", command];
	NSError *error = nil;
	if (![task launchAndReturnError:&error]) NSLog(@"Cannot launch command: %@", error);
}

- (void)action:(NSString *)name value:(int)value
{
	Monitor *m = self.selected;
	Client *c = m.selected;
	if ([name isEqual:@"quit"]) { [NSApp terminate:nil]; return; }
	if ([name isEqual:@"spawn"]) { [self spawn:value ? terminalCommand : launcherCommand]; return; }
	if (!m) return;
	if ([name isEqual:@"view"]) {
		unsigned next = value ? ((unsigned)value & DWM_TAGMASK) : m.previousTags;
		if (next && next != m.tags) { m.previousTags = m.tags; m.tags = next; }
	} else if ([name isEqual:@"toggleview"]) m.tags = dwm_tags(m.tags, (unsigned)value, 1);
	else if ([name isEqual:@"tag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 0);
	else if ([name isEqual:@"toggletag"] && c) c.tags = dwm_tags(c.tags, (unsigned)value, 1);
	else if ([name isEqual:@"togglebar"]) m.showbar = !m.showbar;
	else if ([name isEqual:@"incnmaster"]) m.masters = MAX(0, m.masters + value);
	else if ([name isEqual:@"setmfact"]) m.factor = MAX(0.05, MIN(0.95, m.factor + value * 0.05));
	else if ([name isEqual:@"setlayout"]) {
		int next = value < 0 ? m.previousLayout : value;
		if (next != m.layout) { m.previousLayout = m.layout; m.layout = next; }
	} else if ([name isEqual:@"togglefloating"] && c && !c.fullscreen) c.floating = !c.floating;
	else if ([name isEqual:@"togglefullscr"] && c && !c.nativeFullscreen) {
		if (!c.fullscreen) { c.saved = geometry(c.element); c.wasFloating = c.floating; c.fullscreen = YES; c.floating = YES; }
		else { c.fullscreen = NO; c.floating = c.wasFloating; [self resize:c frame:c.saved]; }
	} else if ([name isEqual:@"killclient"] && c) {
		id close = attribute(c.element, kAXCloseButtonAttribute);
		if (close) AXUIElementPerformAction((__bridge AXUIElementRef)close, kAXPressAction);
	} else if ([name isEqual:@"focusstack"]) {
		NSArray *visible = [self visible:m tiled:NO];
		if (visible.count) {
			NSUInteger index = [visible indexOfObject:c];
			int next = index == NSNotFound ? 0 : dwm_monitor((int)index, value, (int)visible.count);
			[self focus:visible[next]];
		}
	} else if ([name isEqual:@"zoom"] && c && m.layout != 1 && !c.floating && !c.fullscreen) {
		NSArray *tiled = [self visible:m tiled:YES];
		Client *target = c == tiled.firstObject && tiled.count > 1 ? tiled[1] : c;
		[m.clients removeObject:target]; [m.clients insertObject:target atIndex:0]; [self focus:target];
	} else if ([name isEqual:@"focusmon"] || [name isEqual:@"tagmon"]) {
		Monitor *target = self.monitors[dwm_monitor((int)[self.monitors indexOfObject:m], value, (int)self.monitors.count)];
		if ([name isEqual:@"tagmon"] && c && target != m) {
			[m.clients removeObject:c]; [m.history removeObject:c];
			c.monitor = target; c.tags = target.tags;
			[target.clients insertObject:c atIndex:0]; [target.history insertObject:c atIndex:0];
			if (c.floating && !c.fullscreen) { DwmRect r = geometry(c.element); r.x = target.work.x; r.y = target.work.y + barHeight; [self resize:c frame:r]; }
			target.selected = c;
		}
		self.selected = target;
	}
	[self arrange];
	[self focus:self.selected.selected];
}

- (Client *)clientAt:(CGPoint)p
{
	AXUIElementRef system = AXUIElementCreateSystemWide(), element = NULL;
	AXError error = AXUIElementCopyElementAtPosition(system, p.x, p.y, &element);
	CFRelease(system);
	if (error != kAXErrorSuccess || !element) return nil;
	id window = attribute(element, kAXWindowAttribute);
	if (!window && [attribute(element, kAXRoleAttribute) isEqual:(__bridge NSString *)kAXWindowRole]) window = (__bridge id)element;
	Client *found = nil;
	for (Monitor *m in self.monitors) for (Client *c in [self visible:m tiled:NO])
		if (window && CFEqual(c.element, (__bridge CFTypeRef)window)) found = c;
	CFRelease(element);
	return found;
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
		for (size_t i = 0; i < sizeof(keys)/sizeof(keys[0]); ++i) if (keys[i].code == code && keys[i].modifiers == flags) {
			[self.heldKeys addIndex:code];
			NSString *action = keys[i].action; int value = keys[i].value;
			dispatch_async(dispatch_get_main_queue(), ^{ [self action:action value:value]; });
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
				if (self.stopping || self.dragClient) return;
				self.selected = [self monitorAt:self.pointer];
				Client *c = [self clientAt:self.pointer];
				if (c != self.hovered) { self.hovered = c; [self focus:c]; }
			});
		}
		return event;
	}
	BOOL down = type == kCGEventLeftMouseDown || type == kCGEventRightMouseDown || type == kCGEventOtherMouseDown;
	BOOL up = type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
	int button = (int)CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
	if (down && flags == ALT) {
		Client *c = [self clientAt:p];
		if (!c || c.fullscreen || c.nativeFullscreen) return event;
		[self focus:c];
		self.dragClient = c; self.dragButton = button; self.dragStart = p; self.dragFrame = geometry(c.element);
		if (button == 2) [self action:@"togglefloating" value:0];
		return NULL;
	}
	if (!self.dragClient) return event;
	if (up && button == self.dragButton) {
		Client *c = self.dragClient;
		DwmRect r = geometry(c.element);
		Monitor *target = [self monitorAt:CGPointMake(r.x+r.w/2, r.y+r.h/2)];
		if (target != c.monitor) {
			[c.monitor.clients removeObject:c]; [c.monitor.history removeObject:c];
			c.monitor = target; c.tags = target.tags; [target.clients insertObject:c atIndex:0]; [target.history insertObject:c atIndex:0];
		}
		self.dragClient = nil; [self arrange]; [self focus:c]; return NULL;
	}
	if (type == kCGEventLeftMouseDragged || type == kCGEventRightMouseDragged) {
		DwmRect r = self.dragFrame;
		double dx = p.x-self.dragStart.x, dy = p.y-self.dragStart.y;
		Client *c = self.dragClient;
		if (!c.floating && c.monitor.layout != 1 && fabs(dx) < snapDistance && fabs(dy) < snapDistance) return NULL;
		c.floating = YES;
		if (self.dragButton == 0) {
			r.x += dx; r.y += dy;
			DwmRect a = [self monitorAt:p].work;
			if (c.monitor.showbar) { a.h -= barHeight; if (topBar) a.y += barHeight; }
			if (fabs(r.x-a.x) < snapDistance) r.x = a.x;
			if (fabs(r.y-a.y) < snapDistance) r.y = a.y;
			if (fabs(r.x+r.w-a.x-a.w) < snapDistance) r.x = a.x+a.w-r.w;
			if (fabs(r.y+r.h-a.y-a.h) < snapDistance) r.y = a.y+a.h-r.h;
		} else if (self.dragButton == 1) { r.w = MAX(1, r.w+dx); r.h = MAX(1, r.h+dy); }
		[self resize:c frame:r]; return NULL;
	}
	return event;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
	(void)notification;
	self.stopping = YES;
	[self.timer invalidate];
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	if (self.tap) { CGEventTapEnable(self.tap, false); CFMachPortInvalidate(self.tap); CFRelease(self.tap); self.tap = NULL; }
	if (self.tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), self.tapSource, kCFRunLoopCommonModes); CFRelease(self.tapSource); self.tapSource = NULL; }
	for (Monitor *m in self.monitors) {
		for (Client *c in m.clients) {
			if (c.hidden) setAttribute(c.element, kAXMinimizedAttribute, @NO);
			if (c.fullscreen) [self resize:c frame:c.saved];
		}
		[m.panel close];
	}
	[self.watches removeAllObjects];
	if (self.interruptSource) dispatch_source_cancel(self.interruptSource);
	if (self.terminateSource) dispatch_source_cancel(self.terminateSource);
	if (self.lockFD >= 0) close(self.lockFD);
}
@end

@implementation Bar
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { (void)event; return YES; }
- (void)drawRect:(NSRect)dirtyRect
{
	(void)dirtyRect;
	Monitor *m = self.monitor;
	[[NSColor colorWithWhite:0.13 alpha:1] setFill]; NSRectFill(self.bounds);
	NSDictionary *attributes = @{NSFontAttributeName: [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor colorWithWhite:0.85 alpha:1]};
	unsigned occupied = 0;
	for (Client *c in m.clients) occupied |= c.tags;
	for (int i = 0; i < 5; ++i) {
		if (m.tags & (1u << i)) { [[NSColor colorWithRed:0 green:0.33 blue:0.47 alpha:1] setFill]; NSRectFill(NSMakeRect(i*30, 0, 30, barHeight)); }
		[tagNames[i] drawAtPoint:NSMakePoint(i*30+10, 3) withAttributes:attributes];
		if (occupied & (1u << i)) {
			[[NSColor whiteColor] setFill];
			NSRect mark = NSMakeRect(i*30+3, 2, 4, 4);
			if (m.selected.tags & (1u << i)) NSRectFill(mark); else NSFrameRect(mark);
		}
	}
	NSString *layout = m.layout == 2 ? [NSString stringWithFormat:@"[%lu]", (unsigned long)[self.manager visible:m tiled:NO].count] : layoutNames[m.layout];
	[layout drawAtPoint:NSMakePoint(155, 3) withAttributes:attributes];
	NSString *status = m == self.manager.selected ? self.manager.status : @"";
	CGFloat statusWidth = MIN([status sizeWithAttributes:attributes].width+12, MAX(0, self.bounds.size.width/3));
	[status drawInRect:NSMakeRect(self.bounds.size.width-statusWidth+6, 3, statusWidth-6, barHeight-3) withAttributes:attributes];
	NSString *title = [NSString stringWithFormat:@"%@%@", m.selected.fullscreen ? @"[F] " : m.selected.floating ? @"[~] " : @"", m.selected.title ?: @""];
	[title drawInRect:NSMakeRect(205, 3, MAX(0, self.bounds.size.width-statusWidth-210), barHeight-3) withAttributes:attributes];
}
- (void)click:(NSEvent *)event
{
	self.manager.selected = self.monitor;
	CGFloat x = [self convertPoint:event.locationInWindow fromView:nil].x;
	BOOL alt = (event.modifierFlags & NSEventModifierFlagOption) != 0;
	BOOL right = event.buttonNumber == 1;
	BOOL middle = event.buttonNumber == 2;
	if (x < 150 && !middle) [self.manager action:alt ? (right ? @"toggletag" : @"tag") : (right ? @"toggleview" : @"view") value:1 << (int)(x/30)];
	else if (x < 205 && !middle) [self.manager action:@"setlayout" value:right ? 2 : -1];
	else if (middle) {
		CGFloat width = MIN([self.manager.status sizeWithAttributes:@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]}].width+12, self.bounds.size.width/3);
		[self.manager action:x >= self.bounds.size.width-width ? @"spawn" : @"zoom" value:1];
	}
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
		Manager *manager = [Manager new];
		app.delegate = manager;
		[app run];
	}
	return 0;
}
