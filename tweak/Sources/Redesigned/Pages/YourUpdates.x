// Your Updates, from the left menu: the redesign's bar over the list (Pages/PageBar.m).
//
// Tree: NotificationCenterView holds the list, a UICollectionView the size of the screen on #000000, and over it
// the navigation controller's blur, SPNavigationBar with Back, the title "Your Updates" and the Encore ⋯ of the
// page's own. The list already runs under the bar, so only the bar changes: no blur, the title on a glass
// capsule, Back and ⋯ glass circles. The ⋯ is the one in this page's bar, which is what it fires; the player's
// has nothing to do with it.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"YourUpdates_CommonImpl", @"NotificationCenterViewController");
    if (!page) SGLog(@"class YourUpdates_CommonImpl.NotificationCenterViewController not found, Your Updates keeps Spotify's bar");
    SGRDressBarPagesOf(page, NO);
}
