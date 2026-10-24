#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
static NSInteger checks, failures, marks, targetCalls, actionCalls, accessibilityCalls;
static __weak UIView *marked;
static CFTimeInterval markedAt;
BOOL SGNativeUI(void) { return YES; }
BOOL SGHidden(NSString *key) { return YES; }
void SGAlbumQueueMarkSource(UIView *view) { marked = view; markedAt = CACurrentMediaTime(); marks++; }
static void check(BOOL ok, NSString *message) { checks++; if (!ok) failures++; NSLog(@"[album activation] %@ %@", ok ? @"PASS" : @"FAIL", message); }
static BOOL fresh(UIView *view) { return marked == view && CACurrentMediaTime() - markedAt < 0.25; }
@interface App : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UIButton *held, *primary, *accessible, *other;
@end
@implementation App
- (void)menu:(UIButton *)button { targetCalls++; check(fresh(button), @"target/selector sees a fresh marker before opening its menu"); }
- (void)down:(UIButton *)button { check(marks == 0, @"touch down alone does not mark an album source"); }
- (void)cancel:(UIButton *)button { check(marks == 0, @"cancellation alone does not mark an album source"); }
- (void)accessibleMenu:(UIButton *)button { accessibilityCalls++; check(fresh(button), @"target/selector without touch down sees the source before opening its menu"); }
- (void)otherMenu:(UIButton *)button { check(marks == 3, @"unrelated controls do not change the source"); }
- (UIButton *)buttonAt:(CGFloat)y {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(20, y, 300, 44);
    [button setTitle:@"Album menu" forState:UIControlStateNormal];
    button.accessibilityIdentifier = @"Components.UI.ContextMenuButton-testAlbum";
    [self.window.rootViewController.view addSubview:button];
    return button;
}
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = UIColor.blackColor;
    [self.window makeKeyAndVisible];
    self.held = [self buttonAt:100];
    [self.held addTarget:self action:@selector(down:) forControlEvents:UIControlEventTouchDown];
    [self.held addTarget:self action:@selector(cancel:) forControlEvents:UIControlEventTouchCancel];
    [self.held addTarget:self action:@selector(menu:) forControlEvents:UIControlEventTouchUpInside];
    self.primary = [self buttonAt:160];
    __weak App *weakSelf = self;
    [self.primary addAction:[UIAction actionWithHandler:^(UIAction *action) {
        App *me = weakSelf; actionCalls++; check(fresh(me.primary), @"UIAction sees the source before opening its menu");
    }] forControlEvents:UIControlEventPrimaryActionTriggered];
    self.accessible = [self buttonAt:220];
    [self.accessible addTarget:self action:@selector(accessibleMenu:) forControlEvents:UIControlEventTouchUpInside];
    self.other = [self buttonAt:280];
    self.other.accessibilityIdentifier = @"unrelated";
    [self.other addTarget:self action:@selector(otherMenu:) forControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.held sendActionsForControlEvents:UIControlEventTouchCancel];
        [self.held sendActionsForControlEvents:UIControlEventTouchDown];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [self.held sendActionsForControlEvents:UIControlEventTouchUpInside];
            check(targetCalls == 1 && marks == 1, @"a release after two seconds opens once with a newly recorded source");
            [self.primary sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            check(actionCalls == 1 && marks == 2, @"primary action works without a preceding touch down");
            // Exercise the non-touch target/selector dispatch. Calling accessibilityActivate
            // directly on UIButton returns NO in this standalone simulator app; it is not
            // an end-to-end VoiceOver test.
            [self.accessible sendActionsForControlEvents:UIControlEventTouchUpInside];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                check(accessibilityCalls == 1 && marks == 3, @"target/selector dispatches once without touch down");
                [self.other sendActionsForControlEvents:UIControlEventTouchUpInside];
                NSLog(@"[album activation] done: %ld checks, %ld failures", (long)checks, (long)failures);
                exit(failures ? 1 : 0);
            });
        });
    });
    return YES;
}
@end
int main(int argc, char **argv) { @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(App.class)); } }
