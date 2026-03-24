// AppDelegate.h
// ScheduledJiggler

#import <Cocoa/Cocoa.h>

@interface AppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

- (void)applyScheduleEnabled:(BOOL)enabled
                        hour:(NSInteger)hour
                      minute:(NSInteger)minute
               idleThreshold:(double)idle
              jiggleInterval:(double)interval;

@end
