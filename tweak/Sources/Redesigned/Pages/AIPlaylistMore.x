// Redesign, iOS < 26: the popup the AI playlist's ⋯ opens (Report a problem, Clear conversation) as the queue's glass.
//
// AIPlaylist_PlaylistCreationPageImpl.PlaylistCreationMoreOptionsViewController, presented by the page's own
// BottomSheetPresentationController, not by Navigation's sheet: in a UITransitionView of the window, a 60% black
// dim, the controller's view (PlaylistCreationMoreOptionsView, 390 x 174 at the foot, #1F1F1F r=16) and, beside it, a 28pt strip with
// the grabber that lies over the card's top. So the sheet pass of SGRSheetPopups.x never met it. The controller's view is the card
// itself and gets the queue's pane and the screen's top corners (SGRGlassSheetView), as the podcast speed popup's card does; the
// grabber stays Spotify's, over the glass. Its two rows have no paint of their own.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static NSString *const kCardSuffix = @"PlaylistCreationMoreOptionsView";

static void moreChrome(UIViewController *controller) {
    UIView *card = controller.viewIfLoaded;
    if (!card || card.bounds.size.width < 1) return;
    if (![NSStringFromClass(card.class) hasSuffix:kCardSuffix]) return;
    if (card.layer.mask) card.layer.mask = nil;
    SGRGlassSheetView(card);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The rows are built after the first layout, and the grey comes back with them.
    SGRPassSwiftController(@"AIPlaylist_PlaylistCreationPageImpl", @"PlaylistCreationMoreOptionsViewController", ^(UIViewController *c) { moreChrome(c); });
}
