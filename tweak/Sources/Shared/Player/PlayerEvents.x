// The player's open and close, told from the appearance callbacks of a controller inside the player,
// which UIKit sends as the presentation or the dismissal begins, whatever animates it; the transition
// coordinator says when it is over, a canceled swipe included. Spotify 9.1.78 presents the player
// through SPTBarInteractivePresentationController, never through NowPlaying_ViewPageImpl's
// Show/CloseFullscreenAnimatedTransitioning animators, whose hooks never once fired.
#import "Core/SGCore.h"
#import "PlayerEvents.h"

NSString *const SGPlayerTransitionNotification = @"spotifyglass.playerTransition";
NSString *const SGPlayerTransitionEndedNotification = @"spotifyglass.playerTransitionEnded";
static CFTimeInterval sg_transitionEnds;
static NSUInteger sg_transitionGeneration;
static BOOL sg_open;

BOOL SGPlayerIsOpen(void) {
    return sg_open;
}

CFTimeInterval SGPlayerTransitionEnds(void) {
    return sg_transitionEnds > CACurrentMediaTime() ? sg_transitionEnds : 0;
}

static void announceTransition(UIViewController *unit, BOOL animated, BOOL opens) {
    BOOL wasOpen = sg_open;
    sg_open = opens;
    id<UIViewControllerTransitionCoordinator> coordinator = unit.transitionCoordinator;
    if (!animated || !coordinator) return;
    NSTimeInterval duration = MAX(0.1, coordinator.transitionDuration);
    NSUInteger generation = ++sg_transitionGeneration;
    sg_transitionEnds = CACurrentMediaTime() + duration;
    [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionNotification object:nil];
    [coordinator animateAlongsideTransition:nil completion:^(id<UIViewControllerTransitionCoordinatorContext> context) {
        if (generation != sg_transitionGeneration) return;
        if (context.isCancelled) sg_open = wasOpen;
        sg_transitionEnds = 0;
        [NSNotificationCenter.defaultCenter postNotificationName:SGPlayerTransitionEndedNotification object:nil];
    }];
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"player %@ over %.2fs, by its appearance callbacks", opens ? @"opens" : @"closes", duration); });
}

%hook _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    announceTransition((UIViewController *)self, animated, YES);
}
- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    announceTransition((UIViewController *)self, animated, NO);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController"]);
}
