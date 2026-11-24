// Playlist redesign, iOS < 26: the Edit playlist page sheet on glass, the way the queue and the other sheets are.
//
// Tree: a page sheet whose pane is the black view of Tome_PageTemplateImpl's loader (the navigation
// controller's superview), holding SPNavigationController with EditItemsViewController: the list (#1F1F1F) under a 56pt
// SPNavigationBar (Cancel, the title, Save) that Spotify backs with its own blur plate (#1C1C1C@0.73), and a
// StackedActionToolbarElement along the bottom (ToolbarContainerView, #1F1F1F) with Encore Primary buttons: Select and
// Smart Reorder, then in select mode the exit cross, Move and Remove, then Back, To top and To bottom. While tracks are
// dragged the bar's title holds an undo / redo pill (UndoRedoBarElement, #FFFFFF@0.10).
//
//  - The pane gets the queue's glass and the screen's top corners (SGRGlassSheetView), darkened a little (kEditDim) so
//    the bright page under it does not wash out the rows. The grey of the list and of the
//    toolbar goes with it (SGRRepaint.x keeps it clear).
//  - The bar's blur plate goes, and the bar and the list are moved down 10pt: with the screen's corner radius on the
//    pane the Cancel and Save at 8pt from the edge, 6pt from the top, would be cut.
//  - With the plate gone the rows scrolled up under Cancel, the title and Save, and everything ran together
//    (the table is the whole height of the sheet under the bar). The view holding the table
//    and the toolbar is masked from the bar's bottom down, so the rows end where the header does.
//  - Every button of the toolbar and the undo / redo pill is a glass capsule (SGRGlassFlatBox).
//  - The two Smart Reorder popups (get smoother transitions, you have custom transitions) are Navigation sheets and are
//    glassed by SGRSheetPopups.x (the PlaylistMixing_MessagingImpl marker); their big Primary button (Continue, Keep
//    custom transitions) is glass tinted with the accent here, since its label is black.
//  - The undo / redo pill is dressed from its own layout passes (PillStackView), not only from the bar's: it is made
//    inside the title control as the first track is dragged, after the bar's pass that would have found it, so its glass
//    came only once the list was scrolled and the bar laid out again.
//  - The row that is being dragged is lifted on a #2A2A2A plate, r=8 (a plain UIView in the main
//    window, scaled up a little, around a UIView with that fill that clips and holds a copy of the row). The plate's
//    color is a preview parameter of Spotify's, set clear while the sheet is up; that alone does not take, so the
//    plate itself is cleared as well, when it comes into the window and as it is painted.
//    The track is lifted bare.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Redesigned/Pages/Pages.h"

static const CGFloat kEditShift = 10;

// How much black the pane's glass carries over its body (SGRDimSheetGlass). The sheet floats over the playlist page,
// whose artwork field is bright, and the plain glass read nearly white with the rows on it hard to make out; the
// same dim the dialogs carry, a little lighter.
static const CGFloat kEditDim = 0.4;

static char kToolbarGlassKey, kPopupGlassKey, kPillKey, kPillGlassKey;
static char kListKey, kListClipKey;

static __weak UINavigationController *sg_editNavigation;

#pragma mark - the pane, the bar and the list

// Spotify's blur behind the bar goes, by alpha, not hidden.
static void hideBarPlate(UINavigationController *navigation) {
    UIView *blur = SGRBarBlurOf(navigation);
    if (blur.alpha != 0) blur.alpha = 0;
}

static void moveBar(UINavigationController *navigation) {
    UIView *content = SGRChildNamed(navigation.navigationBar, @"_UINavigationBarContentView");
    CGAffineTransform shift = CGAffineTransformMakeTranslation(0, kEditShift);
    if (content && !CGAffineTransformEqualToTransform(content.transform, shift)) content.transform = shift;
}

// The rows stop at the bottom of the bar. The mask is on the table's superview, which does not scroll, so it holds
// still while the rows move under it; the toolbar below is inside it whole.
static void clipListBelowBar(UIViewController *controller, UINavigationController *navigation) {
    UIView *table = SGRFindByIdentifier(controller.viewIfLoaded, @"EditItemsViewController.TableView", &kListKey);
    UIView *host = table.superview;
    if (!host || host.bounds.size.height < 1) return;
    CGFloat top = navigation.navigationBar.bounds.size.height + kEditShift;
    CALayer *mask = objc_getAssociatedObject(host, &kListClipKey);
    if (!mask) {
        mask = [CALayer layer];
        mask.backgroundColor = UIColor.blackColor.CGColor;
        objc_setAssociatedObject(host, &kListClipKey, mask, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (host.layer.mask != mask) host.layer.mask = mask;
    CGRect frame = CGRectMake(0, top, host.bounds.size.width, MAX(0, host.bounds.size.height - top));
    if (CGRectEqualToRect(mask.frame, frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mask.frame = frame;
    [CATransaction commit];
}

static void dressPill(UIView *pill) {
    if (pill.bounds.size.width < 1 || pill.bounds.size.height < 1) return;
    if (pill.layer.backgroundColor) pill.layer.backgroundColor = NULL;
    SGRGlassFlatBox(pill, &kPillGlassKey, NO);
    // Encore paints its fill again: it stays clear.
    SGRHoldClear(pill);
}

static void glassPill(UIView *root) {
    UIView *pill = SGRFindByIdentifier(root, @"UndoRedoBarElement", &kPillKey);
    if (pill) dressPill(pill);
}

static void chrome(UIViewController *controller) {
    UINavigationController *navigation = controller.navigationController;
    UIView *pane = SGRSheetPaneOfNavigation(navigation);
    if (!pane) return;
    if (sg_editNavigation != navigation) sg_editNavigation = navigation;
    if (pane.layer.mask) pane.layer.mask = nil;
    UIView *glass = SGRGlassSheetView(pane);
    if (glass && !SGRReduceTransparency()) SGRDimSheetGlass(glass, kEditDim);
    hideBarPlate(navigation);
    moveBar(navigation);
    UIEdgeInsets extra = controller.additionalSafeAreaInsets;
    if (extra.top != kEditShift) {
        extra.top = kEditShift;
        controller.additionalSafeAreaInsets = extra;
    }
    glassPill(navigation.navigationBar);
    clipListBelowBar(controller, navigation);
}

// The bar lays its buttons out again as the title changes (the undo / redo pill comes in while tracks are dragged).
%group SGREditBar
%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *bar = ((UIView *)self).superview;
    if (!sg_editNavigation || bar != sg_editNavigation.navigationBar) return;
    hideBarPlate(sg_editNavigation);
    moveBar(sg_editNavigation);
    glassPill(bar);
}
%end
%end

#pragma mark - the buttons

static BOOL inToolbar(UIView *view) {
    int depth = 0;
    for (UIView *v = view.superview; v && depth < 8; v = v.superview, depth++) {
        if ([NSStringFromClass(v.class) hasSuffix:@"ToolbarContainerView"]) return YES;
    }
    return NO;
}

static void dressButton(UIView *button) {
    if (button.bounds.size.width < 1 || button.bounds.size.height < 1) return;
    if (inToolbar(button)) {
        SGRGlassEncoreButton(button, &kToolbarGlassKey, NO);
        SGRHoldClear(button);
    } else if ([button.accessibilityIdentifier isEqualToString:@"Messaging.PrimaryButton"]) {
        // Continue and Keep are drawn with a black label: the accent goes under it.
        SGRGlassEncoreButton(button, &kPopupGlassKey, YES);
        SGRHoldClear(button);
    }
}

// The plate a dragged row is lifted on, cleared at its source (UIPreviewParameters is where UIDragPreviewParameters has
// its backgroundColor) and on the plate itself, found in the windows as the drag sets its parameters. Only Spotify's
// grey, and only while the Edit playlist sheet is up.
static char kLiftPlateKey;

// The plate in the main window: a plain UIView that clips, r=8, inside a plain UIView that is a child of the window
// itself (the holder the drag scales up). Nothing else of the app sits like that.
static BOOL isLiftPlate(UIView *view) {
    if (!sg_editNavigation.viewIfLoaded.window) return NO;
    if (object_getClass(view) != UIView.class) return NO;
    UIView *holder = view.superview;
    if (!holder || object_getClass(holder) != UIView.class || ![holder.superview isKindOfClass:UIWindow.class]) return NO;
    return view.layer.masksToBounds && view.layer.cornerRadius > 0 && view.layer.cornerRadius <= 12;
}

// The plate cleared and held clear from then on: a paint of it later is dropped by the layer hook (SGRHoldClear).
static void clearLiftPlate(UIView *view) {
    if (!isLiftPlate(view) || objc_getAssociatedObject(view, &kLiftPlateKey)) return;
    objc_setAssociatedObject(view, &kLiftPlateKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRHoldClear(view);
    if (view.layer.backgroundColor) view.backgroundColor = UIColor.clearColor;
}

// The plates in the windows now: the children of each window's plain holders.
static void findLiftPlates(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            for (UIView *holder in window.subviews) {
                if (object_getClass(holder) != UIView.class) continue;
                for (UIView *plate in holder.subviews) clearLiftPlate(plate);
            }
        }
    }
}

// A drag in the sheet sets its preview's parameters as a row is lifted or dropped, and UIKit puts the plate in the window
// in the frames that follow: the windows are looked at then, a few times, instead of every view of the app being watched.
static void lookForLiftPlates(void) {
    for (NSNumber *delay in @[@0, @0.05, @0.15, @0.3, @0.6]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (sg_editNavigation.viewIfLoaded.window) findLiftPlates();
        });
    }
}

%group SGREditDrag
%hook UIPreviewParameters
- (void)setBackgroundColor:(UIColor *)color {
    if (color && sg_editNavigation.viewIfLoaded.window && SGRIsSheetSurface(color.CGColor)) {
        color = UIColor.clearColor;
        lookForLiftPlates();
    }
    %orig(color);
}
%end
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassSwiftController(@"PlaylistEditing_EditPlaylistImpl", @"EditItemsViewController", ^(UIViewController *c) { chrome(c); });
    if (NSClassFromString(@"_UINavigationBarContentView")) %init(SGREditBar);
    Class primary = NSClassFromString(@"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button7Primary");
    if (!primary) SGLog(@"class Encore.Button.Primary not found, the Edit playlist buttons and the Smart Reorder popups keep Spotify's fills");
    // Encore paints a button again as it is pressed or let go; a dressed one is held clear (SGRHoldClear).
    SGRPassView(primary, ^(UIView *v) { dressButton(v); });
    Class toolbar = SGRSwiftClass(@"PlaylistEditing_ElementsKit", @"ToolbarContainerView") ?: SGRPrivateSwiftClass(@"PlaylistEditing_ElementsKit", @"ToolbarContainerView");
    if (!toolbar) SGLog(@"class PlaylistEditing_ElementsKit ToolbarContainerView not found, the Edit playlist toolbar may keep Spotify's grey");
    // The toolbar's grey comes back with its content, as the queue's bars do.
    SGRPassView(toolbar, ^(UIView *bar) {
        if (SGRIsSheetSurface(bar.layer.backgroundColor)) bar.backgroundColor = UIColor.clearColor;
    });
    Class pill = SGRSwiftClass(@"PlaylistEditing_ElementsKit", @"PillStackView") ?: SGRPrivateSwiftClass(@"PlaylistEditing_ElementsKit", @"PillStackView");
    if (!pill) SGLog(@"class PlaylistEditing_ElementsKit PillStackView not found, the undo / redo pill gets its glass from the bar's passes only");
    // The pill is made inside the bar's title control after the bar's own passes, so it is dressed by its own too.
    SGRPassView(pill, ^(UIView *v) { dressPill(v); });
    if (NSClassFromString(@"UIPreviewParameters")) %init(SGREditDrag);
}
