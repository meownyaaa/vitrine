// Playlist redesign, iOS < 26: the Add songs sheet's own search (the "What would you like to add?" page behind the
// Add songs row, and the Find page it opens) on glass, the way the Search tab's field is.
//
// Tree: a plain UIView 358x48 bg=#282828 r=24 id=AssistedCuration.SearchBar, pinned over the bottom of
// the sheet inside an AssistedCurationSearchBarElement, holding the magnifier, the label (on the Find page the text
// field) and the clear button. It is the grey box a search field is elsewhere in the redesign, so it gets the same glass
// (SGRGlassFlatBox): cleared, round, glass inside it, its contents above. Spotify paints the grey again as the field is
// focused, so SGRRepaint.x keeps it clear (sgr_addSongsSearchBar).
//
// The Find page's navigation bar is UIKit's: a _UIButtonBarButton with a bare chevron
// (_UIModernBarButton) and the title. It is dressed the way the profile lists' is (Profile/ProfileListBar.x): the
// bar of Pages/PageBar.m, whose Back is the glass circle the playlist, album and artist pages pin to their corner.
// (Glass put inside UIKit's own button, 40x20 in a 48pt one, threw its layout off.) The bar belongs to the sheet's
// own navigation controller (AssistedCuration_PageImpl.AssistedCurationNavigationController), and is given back as
// the page goes. UIKit builds the buttons again while it lays the content view out, after the bar's own pass, so the
// dressing runs from both.
//
// The chips of the Find page (Songs / Artists / Albums) are the library's FilterChipView: Library/LibraryHeader.x
// gives them their glass (inLibraryChips takes this row too).
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Pages/Pages.h"

static char kBarKey, kBarGlassKey;

// The Find page's container (SGRFind, below), once it is hooked: the page the bar is dressed for.
static Class sg_findClass;

#pragma mark - the search bar

// The grey wash Spotify lays over the list behind the pinned bar (AssistedCuration_RecommendationsImpl.GradientView on
// the add songs page, AssistedCuration_SearchImpl.GradientView on the Find page, 120pt, a sibling of the bar's element):
// the bar is glass now, and the wash showed as a dark band under it. Drawn by nothing, as the album's gradients are: an
// empty mask survives Spotify fading it by alpha.
static void clearWash(UIView *bar) {
    UIView *level = bar;
    for (int i = 0; level && i < 5; i++, level = level.superview) {
        for (UIView *sibling in level.superview.subviews) {
            NSString *name = NSStringFromClass(sibling.class);
            if (sibling == level || ![name hasPrefix:@"AssistedCuration_"] || ![name hasSuffix:@"GradientView"]) continue;
            if (!sibling.layer.mask) sibling.layer.mask = [CALayer layer];
            sibling.accessibilityElementsHidden = YES;
        }
    }
}

static void glassSearchBar(UIViewController *controller) {
    UIView *root = controller.viewIfLoaded;
    if (!root || root.bounds.size.width < 1) return;
    UIView *bar = SGRFindByIdentifier(root, @"AssistedCuration.SearchBar", &kBarKey);
    if (!bar || bar.bounds.size.height < 1) return;
    if (sgr_addSongsSearchBar != bar) sgr_addSongsSearchBar = bar;
    if (bar.layer.backgroundColor) bar.layer.backgroundColor = NULL;
    SGRGlassFlatBox(bar, &kBarGlassKey, NO);
    clearWash(bar);

    static BOOL logged;
    if (!logged && bar.window) {
        logged = YES;
        SGLog(@"redesign playlist: add songs search bar %@ in glass", NSStringFromCGRect(bar.bounds));
    }
}

#pragma mark - the Find page's Back

// The Find page inside the sheet's navigation stack: the controller of SGRFind's class on top of the stack, however
// many hosting controllers it is wrapped in.
static UIViewController *findPageIn(UIViewController *controller, int depth) {
    if (sg_findClass && [controller isKindOfClass:sg_findClass]) return controller;
    if (depth <= 0) return nil;
    for (UIViewController *child in controller.childViewControllers) {
        UIViewController *found = findPageIn(child, depth - 1);
        if (found) return found;
    }
    return nil;
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The bar is made after the page's first layout, and its grey comes back with the rows.
    SGRPassSwiftController(@"AssistedCuration_RecommendationsImpl", @"RecommendationsViewController", ^(UIViewController *c) { glassSearchBar(c); });
    sg_findClass = SGRSwiftClass(@"AssistedCuration_SearchImpl", @"AssistedCurationSearchContainerViewController");
    SGRPassController(sg_findClass, ^(UIViewController *c) { glassSearchBar(c); });
    SGRDressBarPagesFound(^UIViewController *(UINavigationController *navigation) {
        if (![NSStringFromClass(navigation.class) containsString:@"AssistedCurationNavigationController"]) return nil;
        return findPageIn(navigation.topViewController, 4);
    }, SGRBarStyleFull);
}
