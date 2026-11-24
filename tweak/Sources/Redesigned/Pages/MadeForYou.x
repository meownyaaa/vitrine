// Made For You (SPTMadeForYouHubViewController, a Hub page): the redesign's bar over the list (Pages/PageBar.m),
// Spotify's header gone, the title "Made For You" on a glass capsule and Back a glass circle.
//
// Tree: HUBContainerView holds a HUBCollectionView the size of the screen on #000000 with the rows of cards (a
// HUGSCarouselComponentView each), and over it the navigation controller's blur (390x91, #1C1C1C@0.73) and
// SPNavigationBar with Back and the title control, a UILabel "Made For You". The list already runs under the bar, so
// only the bar changes.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = NSClassFromString(@"SPTMadeForYouHubViewController");
    if (!page) {
        SGLog(@"class SPTMadeForYouHubViewController not found, Made For You keeps Spotify's bar");
        return;
    }
    SGRDressBarPagesOf(page, YES);
}
