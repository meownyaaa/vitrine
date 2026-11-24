// What minimizes the glass bar and what brings it back (TabBar.x draws it): a page scrolled down by a
// finger or the fling after it, and scrolled back up or to its top (MinimizeStep.h; the capsule bar of iOS < 26 only at the top,
// unless SGRKeyNavbarExpandOnScrollUp is on). After the bar changes some
// other way (a tap on its circle, a tab, the player), only a new touch minimizes it again: the fling still
// running would otherwise undo the tap at once; another tab (TabBar.x);
// and the full screen player opening or closing, which takes Spotify's pictures of the bars to move with it
// and would have moved the card from the tab bar's row back up to its place above the bar.
//
// Only a page's own scroll views count: those inside Spotify's tab bar container. The player and the now
// playing bar are outside it, and a shelf scrolling sideways has nothing to scroll down.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "MinimizeStep.h"
#import "Shared/Player/PlayerEvents.h"

static Class sg_containerClass;
static __weak UIScrollView *sg_page, *sg_other;
static SGRMinimizeTrack sg_track;
static BOOL sg_waitForTouch;

static BOOL inContainer(UIView *view) {
    for (UIResponder *r = view.nextResponder; r; r = r.nextResponder) if ([r isKindOfClass:sg_containerClass]) return YES;
    return NO;
}

static void scrolled(UIScrollView *scrollView, CGFloat before) {
    if (!scrollView.isTracking && !scrollView.isDecelerating) {
        // The capsule bar only comes back at the top of the page, and a scroll to the top that no finger made (a tap
        // on the status bar, Home tapped again) gets there too. That is a page that was off its top and now is on it:
        // any scroll view of the container laid out again at its own top (a shelf, a page of another tab) is not.
        if (!SGRTabBarMinimized() || !SGRLegacyTabBarOn()) return;
        UIEdgeInsets inset = scrollView.adjustedContentInset;
        CGFloat top = -inset.top, bottom = scrollView.contentSize.height + inset.bottom - scrollView.bounds.size.height;
        if (before > top + 1 && scrollView.contentOffset.y <= top + 1 && bottom - top >= kSGRMinimizeRange && inContainer(scrollView)) {
            SGRSetTabBarMinimized(NO, YES);
        }
        return;
    }
    if (scrollView == sg_other) return;
    CGFloat offset = scrollView.contentOffset.y;
    if (scrollView != sg_page) {
        if (!inContainer(scrollView)) {
            sg_other = scrollView;
            return;
        }
        sg_page = scrollView;
        sg_track = (SGRMinimizeTrack){offset, SGRTabBarMinimized()};
    }
    // The bar changed some other way (a tab, the player): the scroll counts from here.
    if (sg_track.minimized != SGRTabBarMinimized()) {
        sg_track = (SGRMinimizeTrack){offset, SGRTabBarMinimized()};
        sg_waitForTouch = YES;
    }
    if (scrollView.isTracking) sg_waitForTouch = NO;
    UIEdgeInsets inset = scrollView.adjustedContentInset;
    CGFloat top = -inset.top, bottom = scrollView.contentSize.height + inset.bottom - scrollView.bounds.size.height;
    BOOL expandsOnUp = !SGRLegacyTabBarOn() || SGHidden(SGRKeyNavbarExpandOnScrollUp);
    BOOL minimized = SGRMinimizeStepEx(&sg_track, offset, top, bottom, expandsOnUp);
    if (minimized == SGRTabBarMinimized() || (minimized && !SGEnabled(SGRKeyNavbarMinimize))) return;
    if (minimized && sg_waitForTouch) return;
    SGRSetTabBarMinimized(minimized, YES);
}

%hook UIScrollView
- (void)setContentOffset:(CGPoint)offset {
    CGFloat before = self.contentOffset.y;
    %orig;
    scrolled(self, before);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_containerClass = NSClassFromString(@"_TtC23NavigationUI_TabBarImpl19TabBarContainerImpl");
    if (!sg_containerClass) return;
    %init;
    [NSNotificationCenter.defaultCenter addObserverForName:SGPlayerTransitionNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        // The capsule bar (iOS < 26) stays as it is: Spotify's pictures of the bars are of the minimized row, and
        // growing the real bar back under them drew a full bar beneath the circles (two bars in the swipe that
        // opens the player from the minimized bar).
        if (SGRLegacyTabBarOn()) return;
        SGRSetTabBarMinimized(NO, NO);
    }];
}
