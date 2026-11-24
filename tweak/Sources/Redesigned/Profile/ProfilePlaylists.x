// Profile, iOS < 26: the page that adds playlists to a person's profile ("Add playlist" in one's own profile), the same page
// that removes them again. A SwiftUI page, PlaylistEditing_PlaylistsProfileVisibilityPageImpl, under UIKit's own navigation
// bar.
//
// Tree: the hosting view holds the list on #000000 at the full height of the screen. In the navigation controller's view over
// it, a plain UIView 390x91 painted #000000 with Spotify's blur in it (the black header), then SPNavigationBar with Back
// (_UIButtonBarButton) and a _UINavigationBarTitleControl 172x22 holding a SwiftUI bar item (UIKitBarItemHost) with nothing in
// it: the page has no title. And, once something is chosen, at the foot of the hosting view: a fade 390x24, a
// SwiftUI._UIGraphicsView 390x94, and over it the green capsule with "Remove from profile", 8 below the top of the plate and 38
// above its bottom edge (the plate runs through the home indicator's inset). While the plate slides in it is 390x60,
// painted #000000, and its bottom edge is still below the screen's.
//
//  - The bar is the bar of Pages/PageBar.m, as the profile's lists have it (ProfileListBar.x): the black header gone, Back a
//    glass circle pinned to the corner. The title control held a capsule 209x44 all the same, wrapped round the empty item, so
//    the page is dressed without a title (SGRDressBarPageTitleless) and the control carries none.
//  - The black plate at the foot is cleared and carries the pane the queue's sheet has (SGRThickenSheetGlass) in its place, and
//    the fade above it, which only faded the list into that black, goes. The plate is a view of SwiftUI's, laid out and painted
//    again as the selection changes, so it is dressed from its own passes (SwiftUI._UIGraphicsView) and its fill is kept clear.
//    It is dressed from the first pass, while it is still below the screen, or the black shows for as long as it slides in. The
//    pane reaches up past the plate until the capsule has as much glass over it as under it.
//
// Both only below iOS 26 and while Redesigned UI is on.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

// A part of the name of the page's own controller (the hosting controller of PlaylistsProfileVisibilityContentView) and
// of the hosting view that holds its list.
static NSString *const kPageMarker = @"PlaylistsProfileVisibilityPageImpl";

static char kPlateKey;

#pragma mark - the bar

// Whether `controller` is the page's controller or holds it among its children (the hosting controller of Navigation's page API
// and the page template's loader are in between).
static BOOL holdsPage(UIViewController *controller, int depth) {
    if ([NSStringFromClass(controller.class) containsString:kPageMarker]) return YES;
    if (depth > 6) return NO;
    for (UIViewController *child in controller.childViewControllers) {
        if (holdsPage(child, depth + 1)) return YES;
    }
    return NO;
}

#pragma mark - the plate at the foot

// The fade above the plate: a view of the plate's width that ends where the plate starts, nothing painted on it.
static void hideFadeAbove(UIView *plate) {
    UIView *host = plate.superview;
    for (UIView *sub in host.subviews) {
        if (sub == plate || sub.bounds.size.height > 48) continue;
        if (fabs(sub.frame.size.width - plate.frame.size.width) > 1) continue;
        if (fabs(CGRectGetMaxY(sub.frame) - CGRectGetMinY(plate.frame)) > 1) continue;
        if (![NSStringFromClass(sub.class) containsString:@"ShapeHitTestingView"]) continue;
        if (sub.alpha != 0) sub.alpha = 0;
    }
}

// The green capsule of the action: a view of SwiftUI's inside the plate's frame, taller than a label and narrower than the
// page. Its label is a drawing view of 22 and does not pass.
static UIView *actionIn(UIView *plate) {
    for (UIView *sub in plate.superview.subviews) {
        if (sub == plate) continue;
        CGRect f = sub.frame;
        if (f.size.height < 32 || f.size.width > plate.frame.size.width - 32) continue;
        if (f.origin.y < CGRectGetMinY(plate.frame) - 1 || CGRectGetMaxY(f) > CGRectGetMaxY(plate.frame) + 1) continue;
        return sub;
    }
    return nil;
}

// `view` is the black plate behind the page's action at the foot of the hosting view: as wide as it, a plate and not a screen
// high, painted the base black, ending at its bottom edge or, as it slides in, below it. Nothing else of SwiftUI's is all of
// these, and the hosting view's name says whose it is. Called from every layout pass of such a view, so the cheap tests come
// first.
static void dressPlate(UIView *view) {
    BOOL dressed = objc_getAssociatedObject(view, &kPlateKey) != nil;
    if (!dressed) {
        CGColorRef fill = view.layer.backgroundColor;
        if (!fill || !SGIsBaseSurface(fill)) return;
    }
    UIView *host = view.superview;
    if (!host || !view.window) return;
    CGSize size = view.bounds.size;
    if (size.width < 1 || size.height < 1 || size.height > 160) return;
    if (fabs(size.width - host.bounds.size.width) > 1) return;
    CGFloat below = CGRectGetMaxY(view.frame) - host.bounds.size.height;
    if (below < -1 || below > 160) return;
    if (!dressed && ![NSStringFromClass(host.class) containsString:kPageMarker]) return;
    if (!SGBelowiOS26()) return;

    // The capsule sits 8 under the plate's top and, with the home indicator's inset, 38 over its bottom: the pane goes up by the
    // difference so that it is centred in the glass.
    CGFloat reach = 0;
    UIView *action = actionIn(view);
    if (action) {
        CGFloat above = CGRectGetMinY(action.frame) - CGRectGetMinY(view.frame);
        CGFloat under = CGRectGetMaxY(view.frame) - CGRectGetMaxY(action.frame);
        reach = MAX(0, under - above);
    }

    UIView *glass = SGGlassFor(view, &kPlateKey);
    CGRect frame = CGRectMake(0, -reach, size.width, size.height + reach);
    if (!CGRectEqualToRect(glass.frame, frame)) glass.frame = frame;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CGFloat radius = MIN(SGRSheetCornerRadius(), frame.size.height / 2);
    SGShapeGlass(glass, radius, NO);
    SGRThickenSheetGlass(glass, radius);
    if (view.layer.backgroundColor) view.layer.backgroundColor = NULL;
    SGRHoldClear(view);
    hideFadeAbove(view);
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    SGRDressBarPagesFound(^UIViewController *(UINavigationController *navigation) {
        UIViewController *top = navigation.topViewController;
        return top && holdsPage(top, 0) ? top : nil;
    }, SGRBarStyleTitleless);
    Class graphics = SGRSwiftClass(@"SwiftUI", @"_UIGraphicsView");
    if (graphics) {
        SGRPassView(graphics, ^(UIView *v) { dressPlate(v); });
    } else {
        SGLog(@"class SwiftUI._UIGraphicsView not found, the playlists page's Remove from profile keeps its black plate");
    }
}
