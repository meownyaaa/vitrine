// Profile, iOS < 26: the Edit profile sheet on glass, as the Edit playlist sheet is (Playlist/PlaylistEdit.x).
//
// Tree: a page sheet whose pane is the black view of Tome_PageTemplateImpl's loader (the navigation
// controller's superview), holding a UINavigationController with Profile_CommonImpl.EditProfileViewController:
// EditProfileView (#000000) with the photo, the Name row and a 1pt rule, under a 56pt UINavigationBar that Spotify
// backs with a black _UIBarBackground. The bar holds Cancel (a _UIButtonBarButton at the leading edge), Save (the
// trailing one, #37F200@0.30 while there is nothing to save) and the title "Edit Profile" in a
// _UINavigationBarTitleControl, all plain text.
//
//  - The pane is left black, as Spotify draws it: it gets no glass and no corners (it had the queue's, which showed for a
//    beat and then gave way to black). Whatever glass the page loader put on it while it showed its spinner is taken off.
//  - The bar's black backing goes (alpha, never hidden), and the bar is moved down 10pt, clear of the sheet's top corners.
//  - Cancel, Save and the title are on glass capsules, wider than their labels, as the other pages' titles are. They
//    reach past their controls, so the views between them and the bar stop clipping.
// UIKit builds the bar's buttons and its title control again whenever the item changes, after the bar's own pass, so the
// content view's pass is watched too (as PlaylistEdit.x does for its pill).
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Pages/Pages.h"

static const CGFloat kEditShift = 10;
// Side padding of a capsule beside its label, and its height (the title's are the other pages': Pages/PageBar.m).
static const CGFloat kButtonPadding = 12, kButtonHeight = 36;

static char kButtonGlassKey, kTitleGlassKey;

static __weak UINavigationController *sg_profileNavigation;

static UILabel *labelIn(UIView *root) {
    __block UILabel *found = nil;
    SGForEachView(root, ^(UIView *v) {
        if (!found && [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length) found = (UILabel *)v;
    });
    return found;
}

static void glassCapsule(UIView *control, UILabel *label, const void *key, CGFloat padding, CGFloat height, UIView *bar) {
    if (!control || !label) return;
    CGFloat content = ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, height)].width);
    if (content < 1) return;
    // The capsule is a subview that reaches past its control.
    SGRUnclipUpTo(control, ^BOOL(UIView *v) { return v.superview == bar; });
    SGRGlassCapsuleInside(control, key, CGSizeMake(content + 2 * padding, height), NO);
}

static void dressBar(UINavigationController *navigation) {
    UINavigationBar *bar = navigation.navigationBar;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    if (!content) return;
    if (bar.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

    // Spotify's black behind the bar.
    UIView *backing = SGRChildNamed(bar, @"_UIBarBackground");
    if (backing && backing.alpha != 0) backing.alpha = 0;

    CGAffineTransform shift = CGAffineTransformMakeTranslation(0, kEditShift);
    if (!CGAffineTransformEqualToTransform(content.transform, shift)) content.transform = shift;

    // Cancel and Save: a _UIButtonBarButton in each _UIButtonBarStackView, the label in its _UIModernBarButton.
    for (UIView *stack in content.subviews) {
        if (![NSStringFromClass(stack.class) isEqualToString:@"_UIButtonBarStackView"]) continue;
        for (UIView *item in stack.subviews) {
            UIView *button = SGRChildNamed(item, @"_UIModernBarButton") ?: item;
            glassCapsule(button, labelIn(button), &kButtonGlassKey, kButtonPadding, kButtonHeight, bar);
        }
    }

    UIView *title = SGRChildNamed(content, @"_UINavigationBarTitleControl");
    if (title) SGRGlassTitleCapsule(title, &kTitleGlassKey, SGRTitleWidth(labelIn(title)), CGFLOAT_MAX, ^BOOL(UIView *v) { return v.superview == bar; });
}

static void chrome(UIViewController *controller) {
    UINavigationController *navigation = controller.navigationController;
    UIView *pane = SGRSheetPaneOfNavigation(navigation);
    if (!pane) return;
    if (sg_profileNavigation != navigation) {
        sg_profileNavigation = navigation;
        SGLog(@"redesign profile: Edit profile sheet dressed");
    }
    // The sheet stays Spotify's black: no glass, no corners of the mod's. The page loader the sheet opens on has been given
    // the queue's glass while it showed its spinner (Kit/SGRSheetPopups.x, loaderChrome) when this was not yet known to be
    // Edit profile; that is taken off here, so a sheet that got it ends black rather than glass.
    SGRRemoveSheetGlass(pane);
    if (sgr_sheetChromeRoot == pane) sgr_sheetChromeRoot = nil;
    UIEdgeInsets extra = controller.additionalSafeAreaInsets;
    if (extra.top != kEditShift) {
        extra.top = kEditShift;
        controller.additionalSafeAreaInsets = extra;
    }
    dressBar(navigation);
}

// The bar lays its buttons and title out again as the item changes (Save is lit once there is something to save).
%group SGREditProfileBar
%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *bar = ((UIView *)self).superview;
    UINavigationController *navigation = sg_profileNavigation;
    if (!navigation || bar != navigation.navigationBar) return;
    dressBar(navigation);
}
%end
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class edit = SGRSwiftClass(@"Profile_CommonImpl", @"EditProfileViewController");
    if (!edit) {
        SGLog(@"class Profile_CommonImpl.EditProfileViewController not found, the Edit profile sheet keeps Spotify's black");
        return;
    }
    SGRPassController(edit, ^(UIViewController *c) { chrome(c); });
    if (NSClassFromString(@"_UINavigationBarContentView")) %init(SGREditProfileBar);
}
