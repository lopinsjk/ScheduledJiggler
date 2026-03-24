// ScheduleWindowController.m
// ScheduledJiggler
//
// Settings window with an NSDatePicker (time-only) so the user can pick
// the exact stop time, plus sliders for idle threshold and jiggle interval.

#import "ScheduleWindowController.h"
#import "AppDelegate.h"

static NSString * const kScheduleEnabled = @"ScheduleEnabled";
static NSString * const kStopHour        = @"StopHour";
static NSString * const kStopMinute      = @"StopMinute";
static NSString * const kIdleThreshold   = @"IdleThreshold";
static NSString * const kJiggleInterval  = @"JiggleInterval";

@implementation ScheduleWindowController {
    __weak AppDelegate *_appDelegate;
    
    NSButton       *_scheduleCheckbox;
    NSDatePicker   *_timePicker;
    NSSlider       *_idleSlider;
    NSTextField    *_idleValueLabel;
    NSSlider       *_intervalSlider;
    NSTextField    *_intervalValueLabel;
}

- (instancetype)initWithAppDelegate:(AppDelegate *)appDelegate {
    NSWindow *window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 440, 370)
                  styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                    backing:NSBackingStoreBuffered
                      defer:NO];
    
    self = [super initWithWindow:window];
    if (self) {
        _appDelegate = appDelegate;
        
        window.title = @"ScheduledJiggler Settings";
        window.level = NSFloatingWindowLevel;
        [window center];
        window.releasedWhenClosed = NO;
        
        [self buildUI];
        [self loadCurrentValues];
    }
    return self;
}

#pragma mark - UI Construction

- (void)buildUI {
    NSView *content = self.window.contentView;
    CGFloat padding = 24;
    CGFloat y = 320;
    CGFloat fullWidth = 440 - 2 * padding;
    
    // ── Schedule Section ──
    [self addLabel:@"Schedule" bold:YES at:NSMakePoint(padding, y) width:fullWidth to:content];
    y -= 6;
    [self addSeparatorAt:y padding:padding width:fullWidth to:content];
    
    y -= 30;
    _scheduleCheckbox = [NSButton checkboxWithTitle:@"Enable scheduled stop"
                                            target:self
                                            action:@selector(scheduleToggled:)];
    _scheduleCheckbox.frame = NSMakeRect(padding, y, 250, 20);
    [content addSubview:_scheduleCheckbox];
    
    y -= 38;
    [self addLabel:@"Stop jiggling at:" bold:NO at:NSMakePoint(padding, y + 4) width:130 to:content];
    
    // NSDatePicker in time-only mode (hour:minute)
    _timePicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(padding + 135, y, 120, 28)];
    _timePicker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
    _timePicker.datePickerElements = NSDatePickerElementFlagHourMinute;
    _timePicker.datePickerMode = NSDatePickerModeSingle;
    _timePicker.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_GB"]; // 24h format
    _timePicker.calendar = [NSCalendar currentCalendar];
    _timePicker.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightRegular];
    [content addSubview:_timePicker];
    
    [self addLabel:@"(24h format)" bold:NO size:11
         color:[NSColor secondaryLabelColor]
            at:NSMakePoint(padding + 265, y + 6) width:120 to:content];
    
    // ── Behavior Section ──
    y -= 44;
    [self addLabel:@"Jiggle Behavior" bold:YES at:NSMakePoint(padding, y) width:fullWidth to:content];
    y -= 6;
    [self addSeparatorAt:y padding:padding width:fullWidth to:content];
    
    y -= 28;
    [self addLabel:@"Idle threshold before jiggling:" bold:NO
                at:NSMakePoint(padding, y) width:fullWidth to:content];
    
    y -= 24;
    _idleSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(padding, y, 280, 20)];
    _idleSlider.minValue = 10;
    _idleSlider.maxValue = 600;
    _idleSlider.target = self;
    _idleSlider.action = @selector(idleSliderChanged:);
    _idleSlider.continuous = YES;
    [content addSubview:_idleSlider];
    
    _idleValueLabel = [self makeLabelField];
    _idleValueLabel.frame = NSMakeRect(padding + 290, y, 110, 20);
    [content addSubview:_idleValueLabel];
    
    y -= 32;
    [self addLabel:@"Jiggle every:" bold:NO
                at:NSMakePoint(padding, y) width:fullWidth to:content];
    
    y -= 24;
    _intervalSlider = [[NSSlider alloc] initWithFrame:NSMakeRect(padding, y, 280, 20)];
    _intervalSlider.minValue = 5;
    _intervalSlider.maxValue = 120;
    _intervalSlider.target = self;
    _intervalSlider.action = @selector(intervalSliderChanged:);
    _intervalSlider.continuous = YES;
    [content addSubview:_intervalSlider];
    
    _intervalValueLabel = [self makeLabelField];
    _intervalValueLabel.frame = NSMakeRect(padding + 290, y, 110, 20);
    [content addSubview:_intervalValueLabel];
    
    // ── Buttons ──
    y -= 50;
    NSButton *saveBtn = [[NSButton alloc] initWithFrame:NSMakeRect(440 - padding - 90, y, 90, 32)];
    saveBtn.bezelStyle = NSBezelStyleRounded;
    saveBtn.title = @"Save";
    saveBtn.target = self;
    saveBtn.action = @selector(saveSettings:);
    saveBtn.keyEquivalent = @"\r";
    [content addSubview:saveBtn];
    
    NSButton *cancelBtn = [[NSButton alloc] initWithFrame:NSMakeRect(440 - padding - 190, y, 90, 32)];
    cancelBtn.bezelStyle = NSBezelStyleRounded;
    cancelBtn.title = @"Cancel";
    cancelBtn.target = self;
    cancelBtn.action = @selector(cancelSettings:);
    cancelBtn.keyEquivalent = @"\033"; // Escape
    [content addSubview:cancelBtn];
}

#pragma mark - Load / Save

- (void)loadCurrentValues {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    
    _scheduleCheckbox.state = [defs boolForKey:kScheduleEnabled]
        ? NSControlStateValueOn : NSControlStateValueOff;
    
    // Build an NSDate from the stored hour/minute for the date picker
    NSInteger hour = [defs integerForKey:kStopHour];
    NSInteger minute = [defs integerForKey:kStopMinute];
    NSDateComponents *comps = [[NSDateComponents alloc] init];
    comps.hour = hour;
    comps.minute = minute;
    comps.second = 0;
    NSDate *pickerDate = [[NSCalendar currentCalendar] dateFromComponents:comps];
    if (pickerDate) {
        _timePicker.dateValue = pickerDate;
    }
    
    double idle = [defs doubleForKey:kIdleThreshold];
    if (idle <= 0) idle = 120.0;
    _idleSlider.doubleValue = idle;
    _idleValueLabel.stringValue = [self formatDuration:idle];
    
    double interval = [defs doubleForKey:kJiggleInterval];
    if (interval <= 0) interval = 30.0;
    _intervalSlider.doubleValue = interval;
    _intervalValueLabel.stringValue = [self formatDuration:interval];
    
    [self updateFieldsEnabled];
}

- (void)showWindow:(id)sender {
    [super showWindow:sender];
    [self loadCurrentValues]; // Refresh every time window opens
}

#pragma mark - Actions

- (void)scheduleToggled:(id)sender {
    [self updateFieldsEnabled];
}

- (void)idleSliderChanged:(id)sender {
    _idleValueLabel.stringValue = [self formatDuration:_idleSlider.doubleValue];
}

- (void)intervalSliderChanged:(id)sender {
    _intervalValueLabel.stringValue = [self formatDuration:_intervalSlider.doubleValue];
}

- (void)saveSettings:(id)sender {
    BOOL enabled = (_scheduleCheckbox.state == NSControlStateValueOn);
    
    // Extract hour and minute from the date picker
    NSDateComponents *comps = [[NSCalendar currentCalendar]
        components:(NSCalendarUnitHour | NSCalendarUnitMinute)
          fromDate:_timePicker.dateValue];
    NSInteger hour = comps.hour;
    NSInteger minute = comps.minute;
    
    [_appDelegate applyScheduleEnabled:enabled
                                  hour:hour
                                minute:minute
                         idleThreshold:_idleSlider.doubleValue
                        jiggleInterval:_intervalSlider.doubleValue];
    
    [self.window close];
}

- (void)cancelSettings:(id)sender {
    [self.window close];
}

#pragma mark - Helpers

- (void)updateFieldsEnabled {
    BOOL on = (_scheduleCheckbox.state == NSControlStateValueOn);
    _timePicker.enabled = on;
}

- (NSString *)formatDuration:(double)seconds {
    int total = (int)seconds;
    int mins = total / 60;
    int secs = total % 60;
    if (mins > 0 && secs > 0)
        return [NSString stringWithFormat:@"%d min %d sec", mins, secs];
    else if (mins > 0)
        return [NSString stringWithFormat:@"%d min", mins];
    else
        return [NSString stringWithFormat:@"%d sec", secs];
}

- (void)addLabel:(NSString *)text bold:(BOOL)bold at:(NSPoint)origin width:(CGFloat)w to:(NSView *)parent {
    [self addLabel:text bold:bold size:13 color:[NSColor labelColor] at:origin width:w to:parent];
}

- (void)addLabel:(NSString *)text bold:(BOOL)bold size:(CGFloat)size
           color:(NSColor *)color at:(NSPoint)origin width:(CGFloat)w to:(NSView *)parent {
    NSTextField *label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:size] : [NSFont systemFontOfSize:size];
    label.textColor = color;
    label.frame = NSMakeRect(origin.x, origin.y, w, 18);
    [parent addSubview:label];
}

- (void)addSeparatorAt:(CGFloat)y padding:(CGFloat)p width:(CGFloat)w to:(NSView *)parent {
    NSBox *sep = [[NSBox alloc] initWithFrame:NSMakeRect(p, y, w, 1)];
    sep.boxType = NSBoxSeparator;
    [parent addSubview:sep];
}

- (NSTextField *)makeLabelField {
    NSTextField *f = [NSTextField labelWithString:@""];
    f.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    f.textColor = [NSColor secondaryLabelColor];
    return f;
}

@end
