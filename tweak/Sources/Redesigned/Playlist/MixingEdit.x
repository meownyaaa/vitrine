// Playlist redesign, iOS < 26: the Mix transition window, the full-screen page of a Smart Reorder transition with its
// manual effects (PlaylistMixing_MixingUIImpl.MixingEditViewController), on glass.
//
// Tree: a black page (id=MixingEditViewController.View) in a navigation controller of its own, under an SPNavigationBar
// that holds the Back arrow in a _UIButtonBarButton at the leading edge and, in a stack at the trailing one, the Beta
// tag and Encore Primary buttons More and Save. Spotify backs the bar twice, with a blur plate (#1C1C1C@0.73) and with
// the bar's own opaque black _UIBarBackground. In the page itself the Play button of the transition is a 48x32 plate
// (#464646, r=12) in the middle of the waveform, and the bar picker and the jog buttons are MixingBorderedButtons
// (#303030, r=12). Under the waveform sit the presets (Custom, Auto, Fade...) and, in a card, the "New effects are
// here" promo (MixingProductOptInPromo.Card, #1F1F1F r=16, with a Primary "Try out"). Each of the effect rows below
// (Volume, EQ, Looping, Effects, Filter) opens a pager of cards over the page: a black MixingDismissableView the width
// of the screen holding, one per effect, a MixingBottomSheetContainerElement whose MixingDismissableView is a 350pt
// card (#2A2A2A, r=16) with a grabber, the effect's title with a Tertiary Customize button and its presets. The bar
// picker (4 bars, 8 bars) opens the same container as a sheet the width of the screen (#1F1F1F, square) along the
// bottom.
//
//  - The bar's two backings go and the page shows through. Back is pinned over the bar as the glass circle every
//    redesigned page has (SGRPinnedBackOf), at the page's corner and level with the bar's buttons. It is pinned in the
//    navigation controller's view, over the bar, since the bar has to stay live for More and Save and would take the
//    touches of a button under it. Spotify's own arrow is concealed and fired by the mirror.
//  - More and Save are glass capsules where they are, as the filter chips are, Save with the accent over the glass,
//    since its label is black. They are dressed from the page's own passes too, not only from their layout: the
//    buttons are made after the page's first layout, before the navigation controller was known to this file, and
//    were never laid out again.
//  - The Play button is a glass capsule, brighter than the rest (prominent), around the same glyph in the same place.
//    Its element sits in the middle of the waveform's own container (a 370pt UIView) and goes up with it when the
//    page scrolls to make room for a card; Spotify moved it to the bottom of the container meanwhile (y=338 against
//    169), so it stayed under the card instead of on the effect. Its y is held at the middle.
//  - The bordered buttons are glass.
//  - The cards and the bar picker's sheet are glass the way the queue is (SGRThickenSheetGlass): the grey of their
//    MixingDismissableView goes and a glass pane of its own corners stands behind the grabber, the title and the
//    rows. Only that one view loses its fill: the buttons and the rows inside it keep theirs (the picked bar count
//    is a solid white pill, which a strip of the sheet's contents would have eaten).
//  - Customize sits in a glass capsule a little larger than its label.
//  - The promo card is a glass card, its Try out a glass capsule with the accent over it.
// Each is Spotify's own control with its action and its accessibility; the glass is a subview of it
// (Kit/SGRGlass.h), its own fill is cleared and kept clear as Encore paints it again.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kPlayGlassKey, kBorderGlassKey, kBarGlassKey;
static char kCardGlassKey, kPromoGlassKey, kCustomizeGlassKey, kPromoFindKey;

// The card of the promo and the cards of the pager: Spotify's radius.
static const CGFloat kCardRadius = 16;
// A little black over the body of the glass the cards and the sheet carry (SGRDimSheetGlass). The page behind them is
// black, so the queue's plain body would read as a light grey slab with the secondary text (#B3B3B3) on it hard to make
// out.
static const CGFloat kMixDim = 0.2;
// How far the glass of Customize reaches past its label.
static const CGFloat kCustomizePadX = 8, kCustomizePadY = 5;

static NSString *const kPromoCardIdentifier = @"MixingProductOptInPromo.Card";
static NSString *const kPromoButtonIdentifier = @"MixingProductOptInPromo.PrimaryButton";
static NSString *const kCustomizeIdentifier = @"MixingCurvesEditButton.Tertiary";
static NSString *const kPrimaryButtonClass = @"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button7Primary";

static void dressBarButtons(UIView *view, int depth);
static void dressPromoCard(UIView *card);
static void pinPlay(void);

// The navigation controller of the Mix transition window while it is up: what tells its bar's buttons from the other
// Primary buttons of the app.
static __weak UINavigationController *sg_mixNavigation;

// The Play button (MixingPlayButtonView) of the window while it is up; see "the Play button stays on the effect".
static __weak UIView *sg_mixPlay;

#pragma mark - the bar

static void dressBar(UIViewController *controller) {
    UINavigationController *navigation = controller.navigationController;
    UIView *root = controller.viewIfLoaded;
    if (!navigation || !root.window) return;
    if (sg_mixNavigation != navigation) sg_mixNavigation = navigation;

    UINavigationBar *bar = navigation.navigationBar;
    // Glass takes the appearance it inherits, light on a phone in light mode.
    if (bar.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) bar.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    // The bar's own black, and the blur plate beside it in the navigation controller's view: a mask survives Spotify
    // showing either again, which hidden does not.
    UIView *backing = SGRChildNamed(bar, @"_UIBarBackground");
    if (backing.alpha != 0) backing.alpha = 0;
    UIView *blur = SGRBarBlurOf(navigation);
    if (blur && !blur.layer.mask) blur.layer.mask = [CALayer layer];
    if (blur.userInteractionEnabled) blur.userInteractionEnabled = NO;

    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    UIView *back = SGRBarStackButton(content, YES);   // the Back arrow
    if (back) SGRPinnedBackOf(navigation.view, back);

    // More and Save were laid out before this file knew the navigation controller (see the header): dressed here as well.
    dressBarButtons(content, 0);
    UIView *promo = SGRFindByIdentifier(root, kPromoCardIdentifier, &kPromoFindKey);
    if (promo) dressPromoCard(promo);
    pinPlay();
}

#pragma mark - controls

// The shape Spotify's own plate is replaced by: its fill cleared, kept clear as it is painted again.
static void clearFill(UIView *control) {
    if (control.backgroundColor && ![control.backgroundColor isEqual:UIColor.clearColor]) control.backgroundColor = UIColor.clearColor;
    if (control.layer.backgroundColor) control.layer.backgroundColor = NULL;
}

static void dressPlay(UIView *button) {
    if (button.bounds.size.width < 1 || button.bounds.size.height < 1) return;
    if (sg_mixPlay != button) sg_mixPlay = button;
    pinPlay();
    clearFill(button);
    SGRGlassCapsuleInside(button, &kPlayGlassKey, button.bounds.size, YES);
    // The glass grows under a press and would be cut off at the button's edge.
    if (button.clipsToBounds) button.clipsToBounds = NO;
    // Spotify paints it again as it is pressed or let go: it stays clear.
    SGRHoldClear(button);
}

static void dressBordered(UIView *button) {
    if (button.bounds.size.width < 1 || button.bounds.size.height < 1) return;
    clearFill(button);
    SGRGlassFlatBox(button, &kBorderGlassKey, NO);
    // Spotify paints it again as it is pressed or let go: it stays clear.
    SGRHoldClear(button);
}

#pragma mark - the Play button stays on the effect

// The Play button of the transition in the middle of the waveform: the button inside its ElementView inside a
// LazyElementView, which Spotify's layout puts in the 370pt container of the waveform ({171, 169}, 48x32).
static UIView *playElement(void) {
    UIView *element = sg_mixPlay.superview.superview;
    if (!element || ![NSStringFromClass(element.class) containsString:@"MixingPlayButtonElement"]) return nil;
    return element;
}

// The middle of the container, whatever Spotify's layout meant by the bottom of it (y=338 with a card open, where the bar
// picker's slot is). The container is the one that scrolls up with the waveform, so a button held at its middle goes up
// with the effect. Rounded to the pixel as UIKit lays it out.
static CGRect pinnedPlayFrame(UIView *element, CGRect frame) {
    UIView *holder = element.superview;
    if (!holder || object_getClass(holder) != UIView.class || holder.bounds.size.height < 100) return frame;
    CGFloat scale = UIScreen.mainScreen.scale;
    frame.origin.y = round((holder.bounds.size.height - frame.size.height) / 2 * scale) / scale;
    return frame;
}

static IMP sg_playSetFrame;

static void pinnedSetFrame(UIView *self, SEL _cmd, CGRect frame) {
    if (sg_playSetFrame && sg_mixPlay && self == playElement()) frame = pinnedPlayFrame(self, frame);
    if (sg_playSetFrame) ((void (*)(id, SEL, CGRect))sg_playSetFrame)(self, _cmd, frame);
}

// The element is a generic Swift class (Element_UIKit's LazyElementView over the Play button's props) that exists
// once the page has made it, so it cannot be hooked at load: its setFrame: is overridden here, when the first Play
// button is in the window. UIView's own method is never replaced: the override is added to the element's class.
static void pinPlay(void) {
    UIView *element = playElement();
    if (!element || !element.window) return;
    if (!sg_playSetFrame) {
        Class cls = element.class;
        SEL sel = @selector(setFrame:);
        IMP inherited = class_getMethodImplementation(cls, sel);
        if (class_addMethod(cls, sel, (IMP)pinnedSetFrame, "v@:{CGRect={CGPoint=dd}{CGSize=dd}}")) {
            sg_playSetFrame = inherited;
        } else {
            Method method = class_getInstanceMethod(cls, sel);
            if (method) sg_playSetFrame = method_setImplementation(method, (IMP)pinnedSetFrame);
        }
    }
    CGRect now = element.frame;
    CGRect pinned = pinnedPlayFrame(element, now);
    if (!CGRectEqualToRect(now, pinned)) element.frame = pinned;
}

#pragma mark - the bar buttons

static BOOL inMixBar(UIView *view) {
    UINavigationBar *bar = sg_mixNavigation.navigationBar;
    if (!bar) return NO;
    for (UIView *v = view.superview; v; v = v.superview) {
        if (v == bar) return YES;
    }
    return NO;
}

// A Primary button on glass, the capsule the filter chips have: its fill cleared, the glass behind its label, and the
// accent over the glass for a button drawn with a black label.
static void glassPrimary(UIView *button, BOOL accent) {
    SGRGlassEncoreButton(button, &kBarGlassKey, accent);
    // Spotify paints it again as it is pressed or let go: it stays clear.
    SGRHoldClear(button);
}

// The card the promo's button is in, found from the button: it is dressed with it.
static UIView *promoCardAbove(UIView *view) {
    for (UIView *v = view.superview; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:kPromoCardIdentifier]) return v;
    }
    return nil;
}

// More and Save: the Primary buttons of the bar. Save is the last of the stack they are in (its label is in the
// app's language, so it is not told by its word). And Try out, the button of the promo card.
static void dressPrimary(UIView *button) {
    if (button.bounds.size.width < 1 || button.bounds.size.height < 1) return;
    if (inMixBar(button)) {
        glassPrimary(button, button.superview.subviews.lastObject == button);
    } else if ([button.accessibilityIdentifier isEqualToString:kPromoButtonIdentifier]) {
        glassPrimary(button, YES);
        UIView *card = promoCardAbove(button);
        if (card) dressPromoCard(card);
    }
}

static void dressBarButtons(UIView *view, int depth) {
    static Class primary;
    if (!primary) primary = NSClassFromString(kPrimaryButtonClass);
    if (!view || !primary || depth > 4) return;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:primary]) dressPrimary(sub);
        else dressBarButtons(sub, depth + 1);
    }
}

#pragma mark - the cards, the sheet, Customize and the promo

static const CACornerMask kAllCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner;
static const CACornerMask kTopCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;

// The glass of a card or a sheet of the window: the queue's pane (SGRThickenSheetGlass) of the view's own corners behind
// what the view holds, the view's own fill gone. Nothing inside the view is touched: the rows and the buttons keep their
// own fills (the picked bar count is a solid white pill).
static void glassBacking(UIView *view, const void *key, CGFloat radius, CACornerMask corners) {
    if (@available(iOS 26.0, *)) return;
    CGSize size = view.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    clearFill(view);
    // An opaque view with no fill is drawn over black, whatever the glass inside it shows (SGRGlass.m's clearListPaint).
    if (view.opaque) view.opaque = NO;
    if (view.layer.opaque) view.layer.opaque = NO;
    if (view.layer.cornerRadius != radius) view.layer.cornerRadius = radius;
    if (view.layer.cornerCurve != kCACornerCurveContinuous) view.layer.cornerCurve = kCACornerCurveContinuous;
    if (view.layer.maskedCorners != corners) view.layer.maskedCorners = corners;
    UIView *glass = SGRGlassPaneIn(view, key, radius);
    if (!SGRReduceTransparency()) SGRDimSheetGlass(glass, kMixDim);
    // Spotify paints the grey again as the card is picked up or let go: it stays clear.
    SGRHoldClear(view);
}

// The MixingDismissableView of a MixingBottomSheetContainerElement: the card of one effect in the pager (350pt, r=16), or
// the sheet of the bar picker (the width of the screen). The pager's own black MixingDismissableView, behind the cards,
// is in another element and stays black.
static void dressSheetCard(UIView *view) {
    if (![NSStringFromClass(view.superview.class) containsString:@"MixingBottomSheetContainerElement"]) return;
    CGFloat width = view.bounds.size.width;
    if (width < 1) return;
    if (width >= UIScreen.mainScreen.bounds.size.width - 1) {
        glassBacking(view, &kCardGlassKey, SGRSheetCornerRadius(), kTopCorners);
    } else {
        glassBacking(view, &kCardGlassKey, kCardRadius, kAllCorners);
    }
}

// Customize (the Tertiary button of a card's title): a glass capsule a little larger than the label, which keeps its
// place. The glass is the button's own first subview and reaches past its bounds, so the button must not clip it.
static void dressCustomize(UIView *button) {
    if (![button.accessibilityIdentifier isEqualToString:kCustomizeIdentifier]) return;
    CGSize size = button.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    SGRGlassCapsuleInside(button, &kCustomizeGlassKey, CGSizeMake(size.width + kCustomizePadX * 2, size.height + kCustomizePadY * 2), NO);
    if (button.clipsToBounds) button.clipsToBounds = NO;
}

// "New effects are here": the card the promo sits in, #1F1F1F r=16.
static void dressPromoCard(UIView *card) {
    glassBacking(card, &kPromoGlassKey, kCardRadius, kAllCorners);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    // The bar's buttons are made after the first layout.
    SGRPassSwiftController(@"PlaylistMixing_MixingUIImpl", @"MixingEditViewController", ^(UIViewController *c) { dressBar(c); });
    Class play = SGRSwiftClass(@"PlaylistMixing_MixingUIImpl", @"MixingPlayButtonView") ?: SGRPrivateSwiftClass(@"PlaylistMixing_MixingUIImpl", @"MixingPlayButtonView");
    if (!play) SGLog(@"class PlaylistMixing_MixingUIImpl MixingPlayButtonView not found, the Mix transition's Play button keeps Spotify's plate");
    SGRPassView(play, ^(UIView *v) { dressPlay(v); });
    Class bordered = SGRSwiftClass(@"PlaylistMixing_MixingUIImpl", @"MixingBorderedButton");
    if (!bordered) SGLog(@"class PlaylistMixing_MixingUIImpl.MixingBorderedButton not found, the Mix transition's buttons keep Spotify's plates");
    SGRPassView(bordered, ^(UIView *v) { dressBordered(v); });
    Class primary = NSClassFromString(kPrimaryButtonClass);
    if (!primary) SGLog(@"class Encore.Button.Primary not found, the Mix transition's More, Save and the promo's Try out keep Spotify's fills");
    SGRPassView(primary, ^(UIView *v) { dressPrimary(v); });
    Class dismissable = SGRSwiftClass(@"PlaylistMixing_MixingUIImpl", @"MixingDismissableView");
    if (!dismissable) SGLog(@"class PlaylistMixing_MixingUIImpl.MixingDismissableView not found, the Mix transition's effect cards and bar picker keep Spotify's grey");
    SGRPassView(dismissable, ^(UIView *v) { dressSheetCard(v); });
    Class tertiary = NSClassFromString(@"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary");
    if (!tertiary) SGLog(@"class Encore.Button.Tertiary not found, Customize stays without its glass");
    SGRPassView(tertiary, ^(UIView *v) { dressCustomize(v); });
}
