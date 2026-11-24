// Live Events, the concerts hub (LiveEvents_LiveEventsPageImpl.LiveEventsPageViewController): the header's title and
// buttons on glass over the header's own gradient, and the list run on under the tab bar.
//
// Tree: the page is a plain view holding the list (LiveEventsPage.ContentScrollView, a UICollectionView on #000000) and
// the header, a LegacyUI_ECMCoreKit.HeaderLayout (Components.UI.EventHeaderHubPage) with the gradient behind it and, in
// its foreground, the HeaderNavigationBar the playlist, album and artist pages have: its own GradientView, the name "Live
// Events" as a label, Back (Components.Header.UI.BackButton) and, in a stack at the trailing edge, Saved and
// Notifications (Encore Tertiary buttons, 48x48). The list was 689pt high, ending where the now playing bar begins, so
// under the glass tab bar there was the page's black instead of the last events.
//
// The header keeps its gradient. Its buttons are the page's pinned glass circles (Back at the leading corner,
// Notifications in the trailing one and Saved beside it), as on the playlist, album and artist pages: Spotify's own are
// concealed and fired by them, since a circle glassed in place fought the header's collapse. The name in the bar sits on
// the glass capsule those pages' bars give theirs (Playlist/PlaylistBar.x), here without taking the gradient off.
//
// The list is made as tall as the page, and what the bars below took of it goes to its bottom inset, so the last event
// clears them and the rows run on under the glass, as Recents' (Pages/Recents.x) do. Spotify's constraints put the frame
// back after each pass of the page's view, so it is set again after every one.
//
// The pages Live Events opens (LiveEvents_GalleryPageImpl.GalleryPageViewController: Popular events in ..., Your top pop
// events, Venues, All events, Live events just for you) have the same header and a list of their own
// (GalleryPage.ContentScrollView, 705pt of a 844pt page). They get the playlist pages' look: Back on the pinned glass
// circle, the header's gradients gone (Playlist/PlaylistBar.x refuses them on a Gallery page, SGRGalleryPageOf), the
// name in the bar on the glass capsule, and the list as tall as the page, under the bars.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static char kListKey, kBellKey, kSavedKey, kBellPinKey, kSavedPinKey, kTitleGlassKey;

static Class sg_galleryPage;

UIView *SGRGalleryPageOf(UIView *view) {
    if (!sg_galleryPage) return nil;
    for (UIView *v = view; v; v = v.superview) {
        if ([v.nextResponder isKindOfClass:sg_galleryPage]) return v;
    }
    return nil;
}

static UIScrollView *listIn(UIView *page, NSString *identifier) {
    UIView *list = SGRFindByIdentifier(page, identifier, &kListKey);
    return [list isKindOfClass:UIScrollView.class] ? (UIScrollView *)list : nil;
}

static void extendList(UIScrollView *list) {
    CGFloat pageHeight = list.superview.bounds.size.height;
    CGRect frame = list.frame;
    if (pageHeight < 1 || frame.size.width < 1 || frame.size.height < pageHeight * 0.5) return;
    // At most 40% of the page goes to the bars below: more is a list Spotify has not sized yet.
    CGFloat taken = MIN(SGRListRoomOf(list).below, pageHeight * 0.4);
    SGRSetOwnFrame(list, CGRectMake(frame.origin.x, frame.origin.y, frame.size.width, pageHeight - frame.origin.y));
    // The list's own safe area at the bottom is counted again once it reaches the bottom edge, so it is taken off.
    CGFloat safe = list.contentInsetAdjustmentBehavior == UIScrollViewContentInsetAdjustmentNever ? 0 : list.safeAreaInsets.bottom;
    CGFloat bottom = MAX(taken - safe, 0);
    UIEdgeInsets inset = list.contentInset;
    if (fabs(inset.bottom - bottom) < 0.5) return;
    inset.bottom = bottom;
    list.contentInset = inset;
    UIEdgeInsets bar = list.verticalScrollIndicatorInsets;
    bar.bottom = bottom;
    list.verticalScrollIndicatorInsets = bar;
}

// The name in the header's bar: the SPTEncoreLabel directly under the HeaderNavigationBar that holds text (the Back
// button's is a glyph in a button of its own, deeper down). The capsule is its child, so it follows the label's alpha.
static void glassTitle(UIView *page) {
    static Class barClass;
    if (!barClass) barClass = NSClassFromString(@"_TtC28EncoreConsumerMobile_BaseKit19HeaderNavigationBar");
    if (!barClass) return;
    __block UIView *bar = nil;
    SGForEachView(page, ^(UIView *v) {
        if (!bar && [v isKindOfClass:barClass]) bar = v;
    });
    for (UIView *sub in bar.subviews) {
        if (![NSStringFromClass(sub.class) hasSuffix:@"EncoreLabel"]) continue;
        UILabel *text = nil;
        for (UIView *inner in sub.subviews) {
            if ([inner isKindOfClass:UILabel.class] && ((UILabel *)inner).text.length) text = (UILabel *)inner;
        }
        if (!text || sub.bounds.size.width < 1) continue;
        SGRGlassTitleCapsule(sub, &kTitleGlassKey, SGRTitleWidth(text), sub.bounds.size.width, ^BOOL(UIView *v) { return v.superview == page; });
        return;
    }
}

// The page's list run on under the bars, and again after each layout pass of the view it is in.
static void listUnderBars(UIViewController *controller, NSString *identifier) {
    UIScrollView *list = listIn(controller.viewIfLoaded, identifier);
    if (!list) return;
    extendList(list);
    __weak UIViewController *weakPage = controller;
    SGRWatchLayout(list.superview, ^(UIView *laidOut) {
        UIScrollView *found = listIn(weakPage.viewIfLoaded, identifier);
        if (found) extendList(found);
    });
}

static void dress(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (!view.window || view.bounds.size.width < 1) return;

    static UIImage *heart, *bell;
    if (!heart) heart = [UIImage systemImageNamed:@"heart"];
    if (!bell) bell = [UIImage systemImageNamed:@"bell"];
    // Back is found under the page (Components.Header.UI.BackButton) and concealed by the pin.
    SGRPinnedBack(view, view);
    UIView *notifications = SGRFindByIdentifier(view, @"Components.UI.EventHeaderHubPage.Notifications", &kBellKey);
    UIView *saved = SGRFindByIdentifier(view, @"Components.UI.EventHeaderHubPage.Saved", &kSavedKey);
    SGRConceal(notifications);
    SGRConceal(saved);
    SGRPinnedTrailing(view, &kBellPinKey, notifications, 0, bell);
    SGRPinnedTrailing(view, &kSavedPinKey, saved, 1, heart);
    glassTitle(view);
    listUnderBars(controller, @"LiveEventsPage.ContentScrollView");
}

// A Gallery page: Back pinned and the name on glass; the gradients are refused by PlaylistBar.x.
static void dressGallery(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (!view.window || view.bounds.size.width < 1) return;
    SGRPinnedBack(view, view);
    glassTitle(view);
    listUnderBars(controller, @"GalleryPage.ContentScrollView");
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The header's buttons and the list's rows are made after the first layout.
    SGRPassSwiftController(@"LiveEvents_LiveEventsPageImpl", @"LiveEventsPageViewController", ^(UIViewController *c) { dress(c); });
    sg_galleryPage = SGRSwiftClass(@"LiveEvents_GalleryPageImpl", @"GalleryPageViewController");
    SGRPassController(sg_galleryPage, ^(UIViewController *c) { dressGallery(c); });
}
