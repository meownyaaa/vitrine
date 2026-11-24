// Redesign: the list under "Find on this page" (Liked Songs and any other playlist) runs on under the bars.
//
// Tree: the page (ListUXPlatform_FreeTierPlaylistImpl.FTPSearchViewController) is a plain view on #000000 holding one
// UICollectionView, id=SPTFreeTierPlaylistSearchTableView, which Spotify makes 689pt tall on an 844pt page: it stops where
// the now playing bar begins. Under the glass tab bar and the glass now playing bar that left a black slab the page shows
// through, a backing behind the bars, where every other redesigned list runs on beneath them and shows through the glass.
//
// So the list is made as tall as the page, and what Spotify took off its foot goes to the list as its bottom inset: the
// last row still clears the bars. The top stays Spotify's own (the bar's height, from the safe area), read once and set
// as an inset so that dropping the automatic adjustment, which would add the bars' safe area to the bottom twice,
// leaves the top where it was. The frame is set again after each pass of the page, since Spotify's constraints
// put it back (the same as Pages/Recents.x).
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kListKey, kTopKey;

static UICollectionView *findListIn(UIView *view) {
    UICollectionView *cached = objc_getAssociatedObject(view, &kListKey);
    if (cached && [cached isDescendantOfView:view]) return cached;
    __block UICollectionView *list = nil;
    SGForEachView(view, ^(UIView *v) {
        if (list || ![v isKindOfClass:UICollectionView.class]) return;
        if ([v.accessibilityIdentifier isEqualToString:@"SPTFreeTierPlaylistSearchTableView"]) list = (UICollectionView *)v;
    });
    if (list) objc_setAssociatedObject(view, &kListKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return list;
}

static void extendFindList(UIView *page, UICollectionView *list) {
    if (!page.window || list.superview != page) return;
    CGFloat pageHeight = page.bounds.size.height;
    if (pageHeight < 1 || list.bounds.size.width < 1) return;

    // The top as Spotify had it, before the automatic adjustment goes.
    NSNumber *top = objc_getAssociatedObject(list, &kTopKey);
    if (!top) {
        if (list.contentInsetAdjustmentBehavior == UIScrollViewContentInsetAdjustmentNever) return;
        CGFloat adjusted = list.adjustedContentInset.top;
        if (adjusted < 1) return;
        top = @(adjusted - list.contentInset.top);
        objc_setAssociatedObject(list, &kTopKey, top, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    SGRRunListToFoot(list, page, top.doubleValue, NO);
}

static void dress(UIViewController *controller) {
    UIView *page = controller.viewIfLoaded;
    if (!page.window) return;
    UICollectionView *list = findListIn(page);
    if (!list) return;
    extendFindList(page, list);
    SGRWatchLayout(page, ^(UIView *laidOut) {
        UICollectionView *found = findListIn(laidOut);
        if (found) extendFindList(laidOut, found);
    });
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The list is sized by Spotify's constraints after the first layout.
    SGRPassSwiftController(@"ListUXPlatform_FreeTierPlaylistImpl", @"FTPSearchViewController", ^(UIViewController *c) { dress(c); });
}
