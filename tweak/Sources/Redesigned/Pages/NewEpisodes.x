// The Library's New Episodes (SPTYourLibraryPodcastNewEpisodesViewController, from the podcasts filter): the redesign's
// bar over the list (Pages/PageBar.m).
//
// Tree: the page holds SPTPodcastYourLibraryEpisodesViewController, whose list (a UITableView) is the size of the screen
// on #000000, so it already runs under the bar; over it the navigation controller's blur (390x91, #1C1C1C@0.73) and
// SPNavigationBar with Back and the title "New Episodes" as a label, nothing at the trailing edge. So the blur goes, the
// title sits white on a glass capsule and Back is a glass circle pinned to the corner, as on Recents.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = NSClassFromString(@"SPTYourLibraryPodcastNewEpisodesViewController");
    if (!page) SGLog(@"class SPTYourLibraryPodcastNewEpisodesViewController not found, New Episodes keeps Spotify's bar");
    SGRDressBarPagesOf(page, NO);
}
