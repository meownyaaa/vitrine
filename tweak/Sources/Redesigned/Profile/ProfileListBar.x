// Profile lists, iOS < 26: Followers, Following and the playlists of a person. The page is a table under
// SPNavigationBar, UIKit's bar, which Spotify backs with a dark blur of its own. Here the bar is dressed as the
// playlist's is: the blur gone, Back a glass circle pinned to the corner, the title on a glass capsule. That is the
// bar of Pages/PageBar.m, the one Recents and Your Updates have.
//
// Tree: the page is a plain view holding Profile_CommonImpl.ProfileListView, whose UITableView is the size of the
// screen on #000000, so the list already runs under the bar. In the navigation controller's view, over the page, a
// plain UIView 390x91 holding a UIVisualEffectView (#1C1C1C@0.73), then SPNavigationBar with Back
// (_UIButtonBarButton), the title in a _UINavigationBarTitleControl and an empty trailing stack: no page of these
// has a ⋯.
//
// The page is told by what it holds, ProfileListView in the top page's view (no controller of its own is named in the
// trees), and dressed from the bar's own passes (Pages.h, SGRDressBarPagesFound).
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"
#import "Profile.h"

// Whether `view` is, or holds within a few levels, the profile list's view.
static BOOL holdsProfileList(UIView *view, int depth) {
    if ([NSStringFromClass(view.class) hasSuffix:@"Profile_CommonImpl.ProfileListView"]
        || [NSStringFromClass(view.class) hasSuffix:@"Profile_CommonImpl15ProfileListView"]) return YES;
    if (depth <= 0) return NO;
    for (UIView *sub in view.subviews) {
        if (holdsProfileList(sub, depth - 1)) return YES;
    }
    return NO;
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRDressBarPagesFound(^UIViewController *(UINavigationController *navigation) {
        UIViewController *top = navigation.topViewController;
        return top.viewIfLoaded && holdsProfileList(top.viewIfLoaded, 4) ? top : nil;
    }, SGRBarStyleFull);
}
