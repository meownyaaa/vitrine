// The welcome tour and the What's new sheet on the simulator, over a plain screen standing in for Home:
// Tour.m and WhatsNew.m as the tweak builds them, the notes being a CHANGELOG.md section build.sh wrote.
//
//   tour        the tour, as on a first launch (the default)
//   old         the tour as below iOS 26: the redesign card untested, Legacy picked
//   whatsnew    the What's new sheet
//   pick        taps the other look's card three seconds in, to see the note change
//   environment loads a stand-in EeveeSpotify.dylib and runs the install check (the harness's own
//               version, 1.0, is not Spotify's either), whose alert follows about 5 s in
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import "App/Onboarding/Onboarding.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Core/SGPrefs.h"

static BOOL sg_old;

// Core/SGUIMode.m, with the OS the tour believes it runs on taken from the arguments.
BOOL SGRedesignAvailable(void) { return !sg_old; }
BOOL SGRedesignFellBack(void) { return NO; }
BOOL SGRedesignedUIStored(void) { return NO; }
BOOL SGRedesignedUI(void) { return NO; }
BOOL SGNativeUI(void) { return YES; }

// App/Pages.m and App/About/Signing.m, which bring the rest of the tweak with them.
void SGSetRedesignedUI(BOOL on) { NSLog(@"harness: redesign %@", on ? @"on" : @"off"); }
NSString *SGRedesignUntestedWarning(void) {
    return [NSString stringWithFormat:@"The redesign is built on iOS 26's Liquid Glass. iOS %@ draws a blur in its place, and nobody has tested the redesign there: pages can be laid out wrongly, and Spotify can freeze as it starts. If Spotify does not start with it, the next launch goes back to Legacy.", @"17.5"];
}
void SGShowSigningFixIfPending(void) {}
// Settings/SGModPage.m, for the Mod Settings rows, which the harness does not show.
SGModRow *SGWarningRow(NSString *title, NSString *subtitle, void (^action)(void)) { return nil; }
// Shared/Lyrics/KaraokeSource.x's look for EeveeSpotify, by the loaded image's name alone.
BOOL SGEeveeSpotifyInjected(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *image = _dyld_get_image_name(i);
        if (image && [@(image).lastPathComponent caseInsensitiveCompare:@"EeveeSpotify.dylib"] == NSOrderedSame) return YES;
    }
    return NO;
}
// LiveActivitySettings.m and HapticsSettings.m: what the install's Info.plist says.
BOOL SGLiveActivityAllowedByInstall(void) { return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"NSSupportsLiveActivities"] boolValue]; }
BOOL SGMusicHapticsListedByInstall(void) { return [[NSBundle.mainBundle objectForInfoDictionaryKey:@"MusicHapticsSupported"] boolValue]; }

@interface Delegate : UIResponder <UIApplicationDelegate>
@end
@implementation Delegate
@end

@interface Scene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation Scene

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    sg_old = [arguments containsObject:@"old"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyOnboardingSeen];

    UIViewController *home = [UIViewController new];
    home.view.backgroundColor = [UIColor colorWithRed:0.12 green:0.2 blue:0.16 alpha:1];
    UILabel *label = [UILabel new];
    label.text = @"Home";
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:34 weight:UIFontWeightBold];
    label.frame = CGRectMake(20, 120, 300, 44);
    [home.view addSubview:label];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = home;
    [self.window makeKeyAndVisible];

    if ([arguments containsObject:@"environment"]) {
        [NSUserDefaults.standardUserDefaults removeObjectForKey:@"spotifyglass.environment.told"];
        NSString *eevee = [NSBundle.mainBundle pathForResource:@"EeveeSpotify" ofType:@"dylib"];
        NSLog(@"harness: EeveeSpotify.dylib %@", dlopen(eevee.UTF8String, RTLD_NOW) ? @"loaded" : @"not loaded");
        NSLog(@"harness: injected %d, Spotify %@", SGEeveeSpotifyInjected(), SGSpotifyVersion());
        SGCheckEnvironmentOnce();
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:SGKeyOnboardingSeen];
        return;
    }
    BOOL whatsNew = [arguments containsObject:@"whatsnew"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NSLog(@"harness: %lu changes in the notes", (unsigned long)SGWhatsNewChanges().count);
        if (whatsNew) SGShowWhatsNew();
        else SGShowOnboarding();
    });
    if ([arguments containsObject:@"pick"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIViewController *tour = home.presentedViewController;
            NSMutableArray<UIControl *> *cards = [NSMutableArray array];
            NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:tour.view];
            while (queue.count) {
                UIView *view = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([NSStringFromClass(view.class) isEqualToString:@"SGLookCard"]) [cards addObject:(UIControl *)view];
                [queue addObjectsFromArray:view.subviews];
            }
            for (UIControl *card in cards) {
                if (!card.selected) {
                    [card sendActionsForControlEvents:UIControlEventTouchUpInside];
                    break;
                }
            }
        });
    }
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(Delegate.class));
    }
}
