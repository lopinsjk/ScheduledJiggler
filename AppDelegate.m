// AppDelegate.m
// ScheduledJiggler
//
// A macOS menu-bar app inspired by Jiggler (https://github.com/bhaller/Jiggler)
// with time-based scheduling: the jiggler activates on launch and stops at a
// user-chosen time each day.
//
// License: GPL-3.0 (same as original Jiggler)

#import "AppDelegate.h"
#import "ScheduleWindowController.h"
#import <ApplicationServices/ApplicationServices.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <ServiceManagement/ServiceManagement.h>

// UserDefaults keys
static NSString * const kScheduleEnabled   = @"ScheduleEnabled";
static NSString * const kStopHour          = @"StopHour";
static NSString * const kStopMinute        = @"StopMinute";
static NSString * const kIdleThreshold     = @"IdleThreshold";
static NSString * const kJiggleInterval    = @"JiggleInterval";
static NSString * const kJigglingEnabled   = @"JigglingEnabled";
static NSString * const kLaunchAtLogin     = @"LaunchAtLogin";

static double SystemIdleTime(void) {
    return CGEventSourceSecondsSinceLastEventType(
        kCGEventSourceStateCombinedSessionState, kCGAnyInputEventType);
}

@implementation AppDelegate {
    // Status bar
    NSStatusItem *_statusItem;
    NSMenuItem   *_statusMenuItem;
    NSMenuItem   *_enableMenuItem;
    NSMenuItem   *_scheduleMenuItem;
    NSMenuItem   *_launchAtLoginMenuItem;
    
    // Timers
    NSTimer *_jiggleTimer;
    NSTimer *_scheduleTimer;
    
    // Jiggle state
    BOOL     _jigglingEnabled;
    BOOL     _isCurrentlyJiggling;
    BOOL     _stoppedBySchedule;
    BOOL     _haveSetMouseLocation;
    BOOL     _haveGotUserMouseLocation;
    CGPoint  _lastSetMouseLocation;
    CGPoint  _lastUserMouseLocation;
    NSDate  *_timeOfLastJiggle;
    
    // Power assertion
    IOPMAssertionID _assertionID;
    
    // App Nap prevention
    id<NSObject> _activityToken;
    
    // Settings window
    ScheduleWindowController *_scheduleWindowController;
}

#pragma mark - Defaults Helpers

- (BOOL)scheduleEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kScheduleEnabled];
}

- (NSInteger)stopHour {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kStopHour];
}

- (NSInteger)stopMinute {
    return [[NSUserDefaults standardUserDefaults] integerForKey:kStopMinute];
}

- (double)idleThreshold {
    double val = [[NSUserDefaults standardUserDefaults] doubleForKey:kIdleThreshold];
    return val > 0 ? val : 120.0;
}

- (double)jiggleInterval {
    double val = [[NSUserDefaults standardUserDefaults] doubleForKey:kJiggleInterval];
    return val > 0 ? val : 30.0;
}

#pragma mark - App Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Register defaults
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kScheduleEnabled : @YES,
        kStopHour        : @18,
        kStopMinute      : @15,
        kIdleThreshold   : @120.0,
        kJiggleInterval  : @30.0,
        kJigglingEnabled : @YES,
        kLaunchAtLogin   : @NO,
    }];
    
    _jigglingEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:kJigglingEnabled];
    _assertionID = kIOPMNullAssertionID;
    
    // Hide Dock icon
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    
    // Set up status bar
    [self setupStatusItem];
    
    // Start timers
    _jiggleTimer = [NSTimer scheduledTimerWithTimeInterval:0.5
                                                   target:self
                                                 selector:@selector(periodicJiggleCheck:)
                                                 userInfo:nil
                                                  repeats:YES];
    _jiggleTimer.tolerance = 0.2;
    [[NSRunLoop currentRunLoop] addTimer:_jiggleTimer forMode:NSRunLoopCommonModes];
    
    _scheduleTimer = [NSTimer scheduledTimerWithTimeInterval:30.0
                                                     target:self
                                                   selector:@selector(checkSchedule:)
                                                   userInfo:nil
                                                    repeats:YES];
    _scheduleTimer.tolerance = 5.0;
    [[NSRunLoop currentRunLoop] addTimer:_scheduleTimer forMode:NSRunLoopCommonModes];
    
    // Prevent App Nap
    _activityToken = [[NSProcessInfo processInfo]
        beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
                          reason:@"ScheduledJiggler needs to stay responsive"];
    
    // Check accessibility
    NSDictionary *opts = @{(__bridge id)kAXTrustedCheckOptionPrompt : @YES};
    if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts)) {
        NSLog(@"[ScheduledJiggler] Accessibility access not yet granted.");
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_jiggleTimer invalidate];
    [_scheduleTimer invalidate];
    [self releaseAssertion];
    
    if (_activityToken) {
        [[NSProcessInfo processInfo] endActivity:_activityToken];
        _activityToken = nil;
    }
    
    [[NSStatusBar systemStatusBar] removeStatusItem:_statusItem];
}

#pragma mark - Status Bar

- (void)setupStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSSquareStatusItemLength];
    [self updateStatusIcon];
    
    NSMenu *menu = [[NSMenu alloc] init];
    menu.delegate = self;
    
    // Status line
    _statusMenuItem = [[NSMenuItem alloc] initWithTitle:@"Status: Active"
                                                 action:nil
                                          keyEquivalent:@""];
    _statusMenuItem.enabled = NO;
    [menu addItem:_statusMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Enable toggle
    _enableMenuItem = [[NSMenuItem alloc] initWithTitle:@"Jiggling Enabled"
                                                action:@selector(toggleEnabled:)
                                         keyEquivalent:@"e"];
    _enableMenuItem.target = self;
    _enableMenuItem.state = _jigglingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_enableMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Schedule item (opens settings)
    _scheduleMenuItem = [[NSMenuItem alloc] initWithTitle:[self scheduleDisplayString]
                                                  action:@selector(openSettings:)
                                           keyEquivalent:@""];
    _scheduleMenuItem.target = self;
    [menu addItem:_scheduleMenuItem];
    
    // Settings
    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                                                         action:@selector(openSettings:)
                                                  keyEquivalent:@","];
    settingsItem.target = self;
    [menu addItem:settingsItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Launch at login
    _launchAtLoginMenuItem = [[NSMenuItem alloc] initWithTitle:@"Launch at Login"
                                                       action:@selector(toggleLaunchAtLogin:)
                                                keyEquivalent:@""];
    _launchAtLoginMenuItem.target = self;
    _launchAtLoginMenuItem.state = [[NSUserDefaults standardUserDefaults] boolForKey:kLaunchAtLogin]
        ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:_launchAtLoginMenuItem];
    
    [menu addItem:[NSMenuItem separatorItem]];
    
    // Quit
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ScheduledJiggler"
                                                      action:@selector(quitApp:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];
    
    _statusItem.menu = menu;
}

- (void)updateStatusIcon {
    NSStatusBarButton *button = _statusItem.button;
    if (!button) return;
    
    NSImageSymbolConfiguration *config =
        [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    
    if (!_jigglingEnabled || _stoppedBySchedule) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"cursorarrow.motionlines"
                                accessibilityDescription:@"Jiggler Disabled"];
        button.image = [img imageWithSymbolConfiguration:config];
        button.appearsDisabled = YES;
    } else if (_isCurrentlyJiggling) {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"cursorarrow.motionlines"
                                accessibilityDescription:@"Jiggling"];
        button.image = [img imageWithSymbolConfiguration:config];
        button.appearsDisabled = NO;
    } else {
        NSImage *img = [NSImage imageWithSystemSymbolName:@"cursorarrow"
                                accessibilityDescription:@"Waiting"];
        button.image = [img imageWithSymbolConfiguration:config];
        button.appearsDisabled = NO;
    }
}

- (NSString *)scheduleDisplayString {
    if ([self scheduleEnabled]) {
        return [NSString stringWithFormat:@"⏱ Stop at %02ld:%02ld",
                (long)[self stopHour], (long)[self stopMinute]];
    }
    return @"⏱ Schedule: Disabled";
}

- (void)updateStatusText {
    if (!_jigglingEnabled) {
        _statusMenuItem.title = @"Status: Disabled";
    } else if (_stoppedBySchedule) {
        _statusMenuItem.title = [NSString stringWithFormat:@"Status: Stopped (past %02ld:%02ld)",
                                 (long)[self stopHour], (long)[self stopMinute]];
    } else if (_isCurrentlyJiggling) {
        _statusMenuItem.title = @"Status: Jiggling ✨";
    } else {
        _statusMenuItem.title = @"Status: Waiting for idle…";
    }
}

#pragma mark - NSMenuDelegate

- (void)menuWillOpen:(NSMenu *)menu {
    _enableMenuItem.state = _jigglingEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    _scheduleMenuItem.title = [self scheduleDisplayString];
    _launchAtLoginMenuItem.state =
        [[NSUserDefaults standardUserDefaults] boolForKey:kLaunchAtLogin]
            ? NSControlStateValueOn : NSControlStateValueOff;
    [self updateStatusText];
}

#pragma mark - Menu Actions

- (void)toggleEnabled:(id)sender {
    _jigglingEnabled = !_jigglingEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:_jigglingEnabled forKey:kJigglingEnabled];
    _stoppedBySchedule = NO;
    
    if (!_jigglingEnabled) {
        _isCurrentlyJiggling = NO;
        [self releaseAssertion];
    }
    
    [self updateStatusIcon];
    [self updateStatusText];
}

- (void)toggleLaunchAtLogin:(id)sender {
    BOOL current = [[NSUserDefaults standardUserDefaults] boolForKey:kLaunchAtLogin];
    BOOL newVal = !current;
    [[NSUserDefaults standardUserDefaults] setBool:newVal forKey:kLaunchAtLogin];
    
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        if (newVal) {
            [SMAppService.mainAppService registerAndReturnError:&error];
        } else {
            [SMAppService.mainAppService unregisterAndReturnError:&error];
        }
        if (error) {
            NSLog(@"[ScheduledJiggler] Login item error: %@", error);
        }
    }
}

- (void)openSettings:(id)sender {
    if (!_scheduleWindowController) {
        _scheduleWindowController = [[ScheduleWindowController alloc] initWithAppDelegate:self];
    }
    [_scheduleWindowController showWindow:nil];
    [_scheduleWindowController.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)quitApp:(id)sender {
    [NSApp terminate:nil];
}

#pragma mark - Public API (for ScheduleWindowController)

- (void)applyScheduleEnabled:(BOOL)enabled hour:(NSInteger)hour minute:(NSInteger)minute
              idleThreshold:(double)idle jiggleInterval:(double)interval {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kScheduleEnabled];
    [[NSUserDefaults standardUserDefaults] setInteger:hour forKey:kStopHour];
    [[NSUserDefaults standardUserDefaults] setInteger:minute forKey:kStopMinute];
    [[NSUserDefaults standardUserDefaults] setDouble:idle forKey:kIdleThreshold];
    [[NSUserDefaults standardUserDefaults] setDouble:interval forKey:kJiggleInterval];
    
    _stoppedBySchedule = NO;
    [self checkSchedule:nil];
    [self updateStatusIcon];
    [self updateStatusText];
}

#pragma mark - Schedule Logic

- (BOOL)isWithinSchedule {
    if (![self scheduleEnabled]) return YES;
    
    NSDateComponents *now = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitHour | NSCalendarUnitMinute) fromDate:[NSDate date]];
    
    NSInteger currentMinutes = now.hour * 60 + now.minute;
    NSInteger stopMinutes = [self stopHour] * 60 + [self stopMinute];
    
    return currentMinutes < stopMinutes;
}

- (void)checkSchedule:(id)sender {
    if ([self scheduleEnabled]) {
        if (![self isWithinSchedule]) {
            if (!_stoppedBySchedule) {
                _stoppedBySchedule = YES;
                _isCurrentlyJiggling = NO;
                [self releaseAssertion];
                [self updateStatusIcon];
                [self updateStatusText];
            }
        } else {
            if (_stoppedBySchedule) {
                _stoppedBySchedule = NO;
                [self updateStatusIcon];
                [self updateStatusText];
            }
        }
    } else {
        if (_stoppedBySchedule) {
            _stoppedBySchedule = NO;
            [self updateStatusIcon];
            [self updateStatusText];
        }
    }
}

#pragma mark - Jiggle Engine

- (void)periodicJiggleCheck:(id)sender {
    // Don't jiggle if disabled or stopped by schedule
    if (!_jigglingEnabled || _stoppedBySchedule) {
        if (_isCurrentlyJiggling) {
            _isCurrentlyJiggling = NO;
            [self releaseAssertion];
            [self updateStatusIcon];
        }
        return;
    }
    
    // Don't jiggle if any mouse button is down
    for (int i = 0; i < 5; i++) {
        if (CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, (CGMouseButton)i)) {
            return;
        }
    }
    
    double idleTime = SystemIdleTime();
    double timeSinceLastJiggle = _timeOfLastJiggle
        ? -[_timeOfLastJiggle timeIntervalSinceNow]
        : 100000.0;
    
    // If user active, stop jiggling
    if (_isCurrentlyJiggling && idleTime < (timeSinceLastJiggle - 0.5)) {
        _isCurrentlyJiggling = NO;
        [self releaseAssertion];
        [self updateStatusIcon];
        return;
    }
    
    // If idle long enough and enough time since last jiggle, do it
    if (idleTime > [self idleThreshold] && timeSinceLastJiggle > [self jiggleInterval]) {
        [self performJiggle];
        _timeOfLastJiggle = [NSDate date];
        
        if (!_isCurrentlyJiggling) {
            _isCurrentlyJiggling = YES;
            [self updateStatusIcon];
        }
    }
}

- (BOOL)isPointOnScreen:(NSPoint)point {
    for (NSScreen *screen in [NSScreen screens]) {
        NSRect frame = NSInsetRect(screen.frame, 3, 3);
        if (NSPointInRect(point, frame)) return YES;
    }
    return NO;
}

- (void)performJiggle {
    NSPoint mouseLocation = [NSEvent mouseLocation];
    NSScreen *primary = [NSScreen screens].firstObject;
    if (!primary) return;
    
    NSRect screenFrame = primary.frame;
    CGPoint cgLocation = CGPointMake(mouseLocation.x,
                                     screenFrame.size.height - mouseLocation.y);
    
    // Track if user moved mouse
    if (!_haveGotUserMouseLocation ||
        (_haveSetMouseLocation &&
         (_lastSetMouseLocation.x != cgLocation.x || _lastSetMouseLocation.y != cgLocation.y))) {
        _haveGotUserMouseLocation = YES;
        _lastUserMouseLocation = cgLocation;
    }
    
    // Find a new location
    CGFloat tolerance = 15.0;
    CGPoint newLocation;
    int tries = 0;
    
    do {
        if (++tries > 100) return;
        
        CGFloat dx = (CGFloat)(arc4random_uniform(2 * (uint32_t)tolerance + 1)) - tolerance;
        CGFloat dy = (CGFloat)(arc4random_uniform(2 * (uint32_t)tolerance + 1)) - tolerance;
        newLocation = CGPointMake(cgLocation.x + dx, cgLocation.y + dy);
        
        NSPoint checkPt = NSMakePoint(newLocation.x, screenFrame.size.height - newLocation.y);
        if (![self isPointOnScreen:checkPt]) continue;
        
        if (fabs(newLocation.x - _lastUserMouseLocation.x) > tolerance * 2) continue;
        if (fabs(newLocation.y - _lastUserMouseLocation.y) > tolerance * 2) continue;
        
        // Don't land on exact same spot
        if (newLocation.x == cgLocation.x && newLocation.y == cgLocation.y) continue;
        
        break;
    } while (YES);
    
    // Move the mouse
    CGEventSourceRef source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
    if (source) {
        CFTimeInterval oldInterval = CGEventSourceGetLocalEventsSuppressionInterval(source);
        CGEventSourceSetLocalEventsSuppressionInterval(source, 0.0);
        
        CGEventRef event = CGEventCreateMouseEvent(source, kCGEventMouseMoved,
                                                    newLocation, kCGMouseButtonLeft);
        if (event) {
            CGEventPost(kCGHIDEventTap, event);
            CFRelease(event);
        }
        
        CGEventSourceSetLocalEventsSuppressionInterval(source, oldInterval);
        CFRelease(source);
        
        _haveSetMouseLocation = YES;
        _lastSetMouseLocation = newLocation;
    }
    
    [self declareUserActivity];
}

#pragma mark - Power Management

- (void)declareUserActivity {
    [self releaseAssertion];
    
    IOReturn result = IOPMAssertionCreateWithName(
        kIOPMAssertionTypePreventUserIdleDisplaySleep,
        kIOPMAssertionLevelOn,
        CFSTR("ScheduledJiggler keeping Mac awake"),
        &_assertionID);
    
    if (result != kIOReturnSuccess) {
        NSLog(@"[ScheduledJiggler] Failed to create power assertion: 0x%x", result);
    }
}

- (void)releaseAssertion {
    if (_assertionID != kIOPMNullAssertionID) {
        IOPMAssertionRelease(_assertionID);
        _assertionID = kIOPMNullAssertionID;
    }
}

@end
