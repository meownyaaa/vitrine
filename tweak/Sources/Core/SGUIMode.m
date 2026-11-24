#import <UIKit/UIKit.h>
#import "SGUIMode.h"
#import "SGLog.h"
#import "SGPrefs.h"

BOOL SGRedesignAvailable(void) {
    if (@available(iOS 26.0, *)) return YES;
    return NO;
}

static NSString *const kStarting = @"spotifyglass.redesign.untested.starting";
static const NSTimeInterval kStarted = 15;
static BOOL sg_fellBack;

BOOL SGRedesignFellBack(void) {
    return sg_fellBack;
}

// Below iOS 26 a launch with the redesign leaves a mark that the main queue takes off once it has run
// for a while, or as Spotify first leaves the front, which only a main thread that answers is told of. A
// launch that hung (the watchdog of #37) gets to neither, so the next one finds the mark and starts
// native. A launch in the background (a push, a background refresh, the Live Activity) is not the hang:
// iOS suspends it within seconds, before the 15 s are up, and may then end it to free memory, which on a
// phone with little of it (an iPhone 11) happened often enough that the redesign kept turning itself
// off. So the mark goes as soon as the launch turns out to be in the background, and whenever Spotify
// enters it. ponytail: a force quit from the switcher in the first 15 s, with Spotify still in front until
// then, counts as a hang; a hang later on is not caught.
static BOOL startsUntested(void) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    // How far the launch with the mark got: "loaded", "launched" (didFinishLaunching, in front) or "active", so the
    // log of the next one tells a hang before the first frame from one later, or from a crash.
    id reached = [store objectForKey:kStarting];
    if (reached) {
        [store removeObjectForKey:kStarting];
        SGSetEnabled(SGKeyRedesign, NO);
        SGSetEnabled(SGKeyRedesignUntested, NO);
        sg_fellBack = YES;
        SGLog(@"ui: the last launch with the redesign on iOS %@ did not get going (it got as far as %@), so this one is native",
              NSProcessInfo.processInfo.operatingSystemVersionString, [reached isKindOfClass:NSString.class] ? reached : @"loaded");
        return NO;
    }
    [store setObject:@"loaded" forKey:kStarting];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kStarted * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [store removeObjectForKey:kStarting];
    });
    NSMutableArray *tokens = [NSMutableArray array];
    void (^started)(NSNotification *) = ^(NSNotification *note) {
        if ([note.name isEqualToString:UIApplicationDidFinishLaunchingNotification]
            && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
            if ([store objectForKey:kStarting]) [store setObject:@"launched" forKey:kStarting];
            return;
        }
        if ([note.name isEqualToString:UIApplicationDidBecomeActiveNotification]) {
            if ([store objectForKey:kStarting]) [store setObject:@"active" forKey:kStarting];
            return;
        }
        for (id token in tokens) [NSNotificationCenter.defaultCenter removeObserver:token];
        [tokens removeAllObjects];
        [store removeObjectForKey:kStarting];
    };
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification, UIApplicationDidBecomeActiveNotification, UIApplicationWillResignActiveNotification,
                                      UIApplicationDidEnterBackgroundNotification]) {
        [tokens addObject:[NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:started]];
    }
    return YES;
}

BOOL SGRedesignedUI(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        on = SGRedesignedUIStored() && (SGRedesignAvailable() || startsUntested());
        SGLog(@"ui: %@%@", on ? @"redesigned" : @"native", SGRedesignAvailable() ? @"" : on ? @" (untested below iOS 26)" : @" (the redesign needs iOS 26)");
    });
    return on;
}

BOOL SGNativeUI(void) {
    return !SGRedesignedUI();
}

BOOL SGRedesignedUIStored(void) {
    // The stored switch is left alone rather than turned off: a phone updated to iOS 26 gets the
    // redesign it was last asked for back. Below 26 it counts only with the warning accepted.
    return SGFlag(SGKeyRedesign, NO) && (SGRedesignAvailable() || SGFlag(SGKeyRedesignUntested, NO));
}
