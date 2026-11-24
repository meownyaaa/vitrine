// Redesign: glass for the controls of three small screens that were still Spotify's flat ones.
//
//   Eat this playlist   PlaylistCuration_CoverArtSnakeImpl.SnakeViewController: the two
//                       buttons of its navigation bar become the playlist's own glass circles (Kit/SGRActionRow.h:
//                       SGRPinnedBackOf and SGRPinnedTrailing, pinned to the page's corners and firing Spotify's
//                       buttons), and the green Try again button becomes green glass. The circles were once glass
//                       laid inside the bar's buttons, where the cross sat 1.5pt off the middle of its circle: the
//                       bar button is 51pt wide with its glyph inset to one side of it, and the glass is centred in
//                       the button. Copying Spotify's own cross into the mirror left it off the middle too (its canvas
//                       is padded unevenly), so the cross is the system's, drawn centred (SGRMirrorButton.ownGlyph).
//   Spotify code        Scannables_ScannablesImpl.ScannablesImageViewController, in the ⋯ sheet: Save to
//                       photos becomes white glass.
//   Create cover art    PlaylistArtwork_EditPlaylistCoverArtPageImpl.EditPlaylistCoverArtView: the Back
//                       cross becomes a glass circle and Create cover art white glass.
//
// Not here: the third window of Create cover art with its Save popup and its Text / Image labels. That screen is a web
// page (TheStage_VtecImpl, a WKWebView whose whole content is WKCompositingViews), so there is no native control to
// put glass behind and nothing is done to it.
//
// Every control is Spotify's own and keeps its action and its accessibility: the glass is a subview of the control
// (Kit/SGRGlass.h), the control's own fill is cleared, and the label is recolored for the material. The bar buttons of
// the snake are dressed only below iOS 26, where the bars are not the system's.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kButtonGlassKey, kTintKey, kSnakeCloseKey;

// The film over a shape's glass, in the effect's content view so the corners clip it: white for the white buttons,
// green for Try again. Kept on the shape's frame and cheap to call on every pass.
static void tintGlass(UIView *shape, UIColor *color) {
    if (!shape) return;
    UIView *content = shape;
    if ([shape isKindOfClass:UIVisualEffectView.class]) content = ((UIVisualEffectView *)shape).contentView;
    else if ([shape isKindOfClass:SGLegacyGlassView.class]) content = ((SGLegacyGlassView *)shape).contentView;
    UIView *film = objc_getAssociatedObject(shape, &kTintKey);
    if (!film) {
        film = [UIView new];
        film.userInteractionEnabled = NO;
        film.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(shape, &kTintKey, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (film.superview != content) [content addSubview:film];
    if (![film.backgroundColor isEqual:color]) film.backgroundColor = color;
    if (!CGRectEqualToRect(film.frame, content.bounds)) {
        film.frame = content.bounds;
        film.layer.cornerRadius = MIN(content.bounds.size.width, content.bounds.size.height) / 2;
        film.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

// Spotify's own fill of an Encore button: the button's color, its layer's, and the plain wrapper view inside it.
// Cleared on every pass, since Encore paints it again as the button changes state.
static void clearFill(UIView *control, UIView *shape) {
    if (control.backgroundColor && ![control.backgroundColor isEqual:UIColor.clearColor]) control.backgroundColor = UIColor.clearColor;
    if (control.layer.backgroundColor) control.layer.backgroundColor = NULL;
    for (UIView *sub in control.subviews) {
        if (sub == shape || ![sub isMemberOfClass:UIView.class]) continue;
        if (sub.backgroundColor && ![sub.backgroundColor isEqual:UIColor.clearColor]) sub.backgroundColor = UIColor.clearColor;
        if (sub.layer.backgroundColor) sub.layer.backgroundColor = NULL;
    }
    // The grown glass of a press (SGGlassInteractive) would be cut off at the button's edge.
    if (control.clipsToBounds) control.clipsToBounds = NO;
}

static void recolorLabels(UIView *control, UIColor *color) {
    SGForEachView(control, ^(UIView *v) {
        if (![v isKindOfClass:UILabel.class]) return;
        UILabel *label = (UILabel *)v;
        if (label.text.length && ![label.textColor isEqual:color]) label.textColor = color;
    });
}

// A button of Spotify's on a glass capsule, `film` over the glass (nil for the plain glass) and its label `text`.
static void glassCapsule(UIView *control, UIColor *film, UIColor *text) {
    if (!control || control.bounds.size.width < 1 || control.bounds.size.height < 1) return;
    UIView *shape = SGRGlassCapsuleInside(control, &kButtonGlassKey, control.bounds.size, NO);
    clearFill(control, shape);
    if (film) tintGlass(shape, film);
    if (text) recolorLabels(control, text);
}

static BOOL nameHasSuffix(UIView *view, NSString *suffix) {
    return [NSStringFromClass(view.class) hasSuffix:suffix];
}

static UIColor *whiteFilm(void) { return [UIColor colorWithWhite:1 alpha:0.8]; }
static UIColor *greenFilm(void) { return [UIColor colorWithRed:0.215 green:0.949 blue:0 alpha:0.42]; }

#pragma mark - Eat this playlist

static void dressSnakeBar(UIViewController *page) {
    if (!SGBelowiOS26()) return;
    UINavigationBar *bar = page.navigationController.navigationBar;
    UIView *view = page.viewIfLoaded;
    if (!bar || !view.window) return;
    UIView *content = SGRChildNamed(bar, @"_UINavigationBarContentView");
    if (!content) return;
    // The bar is above the page and would take the touches meant for the buttons pinned to it.
    if (bar.userInteractionEnabled) bar.userInteractionEnabled = NO;
    // Add to the left (a plus, or a check once saved: the mirror draws the state Spotify reports), the cross at the
    // corner on the right.
    UIView *add = SGRBarStackButton(content, YES);
    if (add) SGRPinnedBackOf(view, add);
    UIView *close = SGRBarStackButton(content, NO);
    if (close) {
        // Spotify's own cross has uneven padding in its canvas and sat off the middle of the circle once copied, so the
        // mirror draws the system cross at its own size, centred.
        static UIImage *closeGlyph;
        if (!closeGlyph) {
            closeGlyph = [UIImage systemImageNamed:@"xmark"
                                 withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold]];
        }
        // Out of sight and out of reach: the mirror fires it.
        SGRConceal(close);
        SGRMirrorButton *pinned = SGRPinnedTrailing(view, &kSnakeCloseKey, close, 0, closeGlyph);
        if (pinned && !pinned.ownGlyph) {
            pinned.ownGlyph = YES;
            [pinned feedFrom:close];
        }
    }
}

static void dressSnake(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root.window) return;
    dressSnakeBar(page);
    SGForEachView(root, ^(UIView *v) {
        if (nameHasSuffix(v, @"CallToActionButton") || [v.accessibilityIdentifier isEqualToString:@"Components.UI.PrimaryButton"]) {
            glassCapsule(v, greenFilm(), UIColor.whiteColor);
        }
    });
}

#pragma mark - Spotify code

static void dressCode(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (!root.window) return;
    SGForEachView(root, ^(UIView *v) {
        if (nameHasSuffix(v, @"Button7Primary")) glassCapsule(v, whiteFilm(), nil);
    });
}

#pragma mark - Create cover art

static void dressCoverArt(UIView *page) {
    if (!page.window) return;
    for (UIView *sub in page.subviews) {
        // The cross: the Tertiary button at the top-left of the page, the one directly under it.
        if (nameHasSuffix(sub, @"Button8Tertiary") && CGRectGetMinY(sub.frame) < 120 && sub.bounds.size.width < 80) {
            SGRGlassInside(sub, &kButtonGlassKey, SGRGlassCircleSize);
            if (sub.clipsToBounds) sub.clipsToBounds = NO;
        }
    }
    SGForEachView(page, ^(UIView *v) {
        if (nameHasSuffix(v, @"Button7Primary")) glassCapsule(v, whiteFilm(), nil);
    });
}

%ctor {
    if (!SGRedesignedUI()) return;
    // Below iOS 26 only: on iOS 26 these screens keep the look they have on main.
    if (!SGBelowiOS26()) return;
    // Again as Spotify builds the screen: the Try again button only exists once the game is lost, and the bar's
    // buttons are laid out after the controller's own pass.
    SGRPassSwiftController(@"PlaylistCuration_CoverArtSnakeImpl", @"SnakeViewController", ^(UIViewController *c) { dressSnake(c); });
    SGRPassSwiftController(@"Scannables_ScannablesImpl", @"ScannablesImageViewController", ^(UIViewController *c) { dressCode(c); });
    Class cover = SGRSwiftClass(@"PlaylistArtwork_EditPlaylistCoverArtPageImpl", @"EditPlaylistCoverArtView");
    if (cover) {
        SGRPassView(cover, ^(UIView *v) { dressCoverArt(v); });
    } else {
        SGLog(@"class PlaylistArtwork_EditPlaylistCoverArtPageImpl.EditPlaylistCoverArtView not found, Create cover art keeps Spotify's buttons");
    }
}
