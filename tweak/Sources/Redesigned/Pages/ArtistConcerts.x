// An artist's concerts (LiveEvents_ArtistLiveEventsPageImpl.ArtistLiveEventsPageViewController, from the artist popup):
// the redesign's bar over the list, as Recents has it (Pages/PageBar.m).
//
// Tree: the list (ArtistLiveEventsPage.ContentScrollView) is the size of the screen on #000000, so it already runs
// under the bar; over it the navigation controller's blur (390x91, #1C1C1C@0.73) and SPNavigationBar with Back, the
// artist's name as a label and a trailing Share. So the blur goes, the name sits white on a glass capsule, Back and
// Share are glass circles pinned to the corners.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"LiveEvents_ArtistLiveEventsPageImpl", @"ArtistLiveEventsPageViewController");
    if (!page) SGLog(@"class LiveEvents_ArtistLiveEventsPageImpl.ArtistLiveEventsPageViewController not found, the artist's concerts page keeps Spotify's bar");
    SGRDressBarPagesOf(page, YES);
}
