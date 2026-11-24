// What the redesign's two tab bars do to Spotify's own bar the same way, whichever of them is in place (TabBar.x from
// iOS 26, TabBarLegacy.x below it; only one is per launch): the hold on Home that opens Mod Settings, the room made
// under Spotify's bar for the taller bar of the mod's, and whether Create's menu is up.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Navbar.h"
#import "Settings/SGPage.h"

#pragma mark - the hold on Home

@interface SGRHomeHold : UILongPressGestureRecognizer
@end

@implementation SGRHomeHold
+ (void)held:(SGRHomeHold *)hold {
    if (hold.state == UIGestureRecognizerStateBegan) SGOpenModSettings(hold.view);
}
@end

// On Spotify's own bar a hold that begins fails the item's tap recognizer, so Home is not tapped too.
void SGRHoldHomeForModSettings(UIView *stockBar) {
    UIView *home = SGRowIn(stockBar).arrangedSubviews.firstObject;
    if (!home) return;
    for (UIGestureRecognizer *recognizer in home.gestureRecognizers) {
        if ([recognizer isKindOfClass:SGRHomeHold.class]) return;
    }
    [home addGestureRecognizer:[[SGRHomeHold alloc] initWithTarget:SGRHomeHold.class action:@selector(held:)]];
}

#pragma mark - room for the glass bar

// UIKit's glass bar asks for 83 pt, the platter the top 62 of it, over no more safe area than a Face ID
// phone's 34 (simulator, iOS 26.5 and 27). Spotify's bar is its 49 pt row over the bottom safe area of
// TabBarContainerImpl's view: a guide from 49 pt above the safe area's bottom to the view's bottom sets
// its height (its viewDidLoad, 0x100840a2c), the now playing bar stands on that guide's top
// (MainUIContainer's chrome bottom anchor, 0x100ae0178), the bar slides away by the inset plus 49 when
// Spotify hides it (0x1037169a4) and the pages get 49 on top of the inset (0x10707bde4). A Face ID
// phone gives the view 34 and the two bars match. A phone with a home button gives it none, and so does
// Spotify's message bar (LimitedExperienceIndicatorBar: Offline, Private Session) coming in under the
// tab bar, which takes the home indicator's inset for itself, so the glass bar would stand over the now
// playing bar. So the view gets the rest of the glass bar's height as safe area, and Spotify lays its bar,
// the now playing bar, the pages and the hide out for the glass bar itself, and moves them all with the
// message bar. The capsule bar below iOS 26 is a UITabBar too and is given its room the same way.
static const CGFloat kStockRow = 49;
static CGFloat sg_room, sg_glassHeight;

CGFloat SGRTabBarRoom(void) {
    return sg_room;
}

// UIKit asks for 62 + max(21, inset) on a phone with a home button, max(83, 49 + inset) on a Face ID
// phone, by the safe area of the view the bar stands in. The bar's host keeps the room out of that; if
// it ever reached the bar again, the bar would ask for more room every pass, so what it asks for with
// no room made is what is kept.
CGFloat SGRTabBarGlassHeight(UITabBar *bar, UIView *stockBar) {
    if (sg_room < 0.5 || sg_glassHeight <= 0) sg_glassHeight = [bar sizeThatFits:CGSizeMake(stockBar.bounds.size.width, kStockRow)].height;
    return sg_glassHeight;
}

void SGRMakeTabBarRoom(UIViewController *container, UIView *stockBar, UITabBar *bar) {
    if (!bar.window || !container.isViewLoaded || ![stockBar isDescendantOfView:container.view]) return;
    UIEdgeInsets extra = container.additionalSafeAreaInsets;
    CGFloat inset = container.view.safeAreaInsets.bottom - extra.bottom;
    CGFloat height = SGRTabBarGlassHeight(bar, stockBar);
    // Spotify's regular width bar is a fixed 76 pt that ignores the inset.
    BOOL compact = container.traitCollection.horizontalSizeClass == UIUserInterfaceSizeClassCompact;
    CGFloat room = compact ? MAX(0, ceil(height - kStockRow - inset)) : 0;
    if (fabs(extra.bottom - room) < 0.5) return;
    sg_room = extra.bottom = room;
    container.additionalSafeAreaInsets = extra;
    SGLog(@"tab bar: %.0f pt of room made under Spotify's bar for the glass bar's %.0f, over an inset of %.0f", room, height, inset);
}

#pragma mark - Create's menu

static char kCreateMenuKey;

// Matched by id and by class name, so one changed id does not hide it. The view found is remembered on the window and
// the tree is walked again only once it has left, which matters to the capsule bar's poll while the menu is up.
BOOL SGRCreateMenuUp(UIView *view) {
    UIView *root = view.window ?: view;
    return SGFindRemembered(root, &kCreateMenuKey, ^BOOL(UIView *v) {
        return [v.accessibilityIdentifier isEqualToString:@"CreateMenu"] || [NSStringFromClass(v.class) containsString:@"CreateMenuView"];
    }) != nil;
}
