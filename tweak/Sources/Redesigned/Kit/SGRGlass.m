#import "Core/SGCore.h"
#import "SGRGlass.h"
#import "SGRTokens.h"
#import "SGRRestyle.h"
#import "SGRRepaint.h"

// iOS 26 gets the system's glass. Below it a shape is the legacy approximation when that is on and a thin
// material blur when it is not; Reduce Transparency gives a solid fill everywhere.
typedef NS_ENUM(NSInteger, SGRGlassMode) {
    SGRGlassModeGlass,
    SGRGlassModeLegacy,
    SGRGlassModeBlur,
    SGRGlassModeSolid,
};

static SGRGlassMode glassMode(void) {
    if (SGRReduceTransparency()) return SGRGlassModeSolid;
    if (@available(iOS 26.0, *)) return SGRGlassModeGlass;
    if (SGUseLegacyGlass()) return SGRGlassModeLegacy;
    return SGRGlassModeBlur;
}

static UIView *newShape(SGRGlassMode mode) {
    UIView *shape;
    switch (mode) {
        case SGRGlassModeGlass:
            shape = [[UIVisualEffectView alloc] initWithEffect:SGGlassEffect()];
            break;
        case SGRGlassModeLegacy:
            shape = [[SGLegacyGlassView alloc] initWithFrame:CGRectZero];
            break;
        case SGRGlassModeBlur:
            shape = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
            break;
        case SGRGlassModeSolid:
            shape = [UIView new];
            shape.backgroundColor = SGRSolidGlassFill();
            break;
    }
    shape.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    shape.userInteractionEnabled = NO;
    return shape;
}

#pragma mark - inside a control

static char kInsideModeKey, kFilmKey;

// Where a caller's own subviews go: the content view of a visual effect view or a legacy pane, the view itself otherwise.
static UIView *glassContent(UIView *glass) {
    if ([glass isKindOfClass:UIVisualEffectView.class]) return ((UIVisualEffectView *)glass).contentView;
    if ([glass isKindOfClass:SGLegacyGlassView.class]) return ((SGLegacyGlassView *)glass).contentView;
    return glass;
}

// The film that makes a shape prominent, inside the effect's own content view so the corners clip it.
static void keepFilm(UIView *shape, BOOL prominent, SGRGlassMode mode) {
    if (mode == SGRGlassModeSolid) {
        shape.backgroundColor = prominent ? [SGRSolidGlassFill() colorWithAlphaComponent:0.26] : SGRSolidGlassFill();
        return;
    }
    UIView *film = objc_getAssociatedObject(shape, &kFilmKey);
    if (!prominent) {
        film.hidden = YES;
        return;
    }
    UIView *content = glassContent(shape);
    if (!film) {
        film = [UIView new];
        // The prominent film is the system glass's step (0.14), as on main; with the legacy glass, the one film of the Kit's.
        film.backgroundColor = SGUseLegacyGlass() ? SGRGlassFilmColor() : [UIColor colorWithWhite:1 alpha:0.14];
        film.userInteractionEnabled = NO;
        film.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(shape, &kFilmKey, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    film.hidden = NO;
    if (film.superview != content) [content addSubview:film];
    // The effect's content view does not clip, so the film carries the shape's corners itself; square ones
    // drew a lighter rectangle around the playlist's Play capsule (harness, 2026-09-17).
    if (!CGRectEqualToRect(film.frame, content.bounds)) {
        film.frame = content.bounds;
        film.layer.cornerRadius = MIN(content.bounds.size.width, content.bounds.size.height) / 2;
        film.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

static UIView *glassInside(UIView *control, const void *key, CGSize size, BOOL capsule, BOOL prominent) {
    if (!control || !key) return nil;
    SGRGlassMode mode = glassMode();
    UIView *shape = objc_getAssociatedObject(control, key);
    if (shape && [objc_getAssociatedObject(shape, &kInsideModeKey) integerValue] != mode) {
        [shape removeFromSuperview];
        shape = nil;
    }
    if (!shape) {
        shape = newShape(mode);
        shape.accessibilityElementsHidden = YES;
        shape.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin
                               | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        objc_setAssociatedObject(shape, &kInsideModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(control, key, shape, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (shape.superview != control) [control addSubview:shape];
    // First among the control's subviews, so the glyph the control draws is genuinely after the shape in the
    // tree. The shape used to be added last and pushed back with zPosition -1 instead, which sorts the
    // compositing but not what glass takes for its backdrop: on the phone the glyph above it was captured
    // into it, so the button showed a soft ghost of its icon through the glass and no icon over it
    // (issue #39, iOS 26.1). The simulator's glass does not refract and shows neither order failing, so this
    // one is ordered the plain way rather than by depth. Re-asserted on every pass the caller makes, since a
    // control that rebuilds its content puts that in at index 0 too and would end up under the shape.
    if (control.subviews.firstObject != shape) [control insertSubview:shape atIndex:0];
    shape.hidden = size.width <= 0 || size.height <= 0;
    CGRect bounds = CGRectMake(0, 0, size.width, size.height);
    if (!CGRectEqualToRect(shape.bounds, bounds)) {
        shape.bounds = bounds;
        SGShapeGlass(shape, MIN(size.width, size.height) / 2, capsule);
    }
    keepFilm(shape, prominent, mode);
    // Every glass inside a control answers a press below iOS 26, as UIGlassEffect.isInteractive does on it.
    if (mode == SGRGlassModeLegacy) SGGlassInteractive(control, shape);
    CGPoint middle = CGPointMake(CGRectGetMidX(control.bounds), CGRectGetMidY(control.bounds));
    if (!CGPointEqualToPoint(shape.center, middle)) shape.center = middle;
    return shape;
}

UIView *SGRGlassInside(UIView *control, const void *key, CGFloat side) {
    return glassInside(control, key, CGSizeMake(side, side), YES, NO);
}

UIView *SGRGlassCapsuleInside(UIView *control, const void *key, CGSize size, BOOL prominent) {
    return glassInside(control, key, size, YES, prominent);
}

// How far apart two controls may stand and still share a group's capsule.
static const CGFloat kGroupGap = 16;

UIView *SGRGlassGroupPill(UIView *host, NSArray<UIView *> *controls, const void *key, CGFloat height, CGFloat pad) {
    if (@available(iOS 26.0, *)) return nil;
    if (!host || !key) return nil;
    UIView *holder = objc_getAssociatedObject(host, key);
    if (!holder) {
        holder = [UIView new];
        holder.userInteractionEnabled = NO;
        holder.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(host, key, holder, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The controls shown, where they are drawn (their frames, with the transform a page may move them by: the Library's
    // header moves its buttons to the trailing edge that way, and by their centres they stood far to the left, so the
    // capsule took the avatar alone), trailing first; the capsule takes the run of them that stand side by side from
    // the trailing one, so a control standing apart (the Library's Recents, parked at the row's leading edge while it
    // is hidden) does not stretch it across the title.
    NSMutableArray<NSValue *> *spans = [NSMutableArray array];
    for (UIView *control in controls) {
        if (control.bounds.size.width < 1 || control.hidden || control.alpha < 0.01) continue;
        CGRect drawn = [control.superview convertRect:control.frame toView:host];
        [spans addObject:[NSValue valueWithCGRect:CGRectMake(CGRectGetMinX(drawn), CGRectGetMidY(drawn), drawn.size.width, 0)]];
    }
    [spans sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat ax = CGRectGetMaxX(a.CGRectValue), bx = CGRectGetMaxX(b.CGRectValue);
        return ax > bx ? NSOrderedAscending : ax < bx ? NSOrderedDescending : NSOrderedSame;
    }];
    CGFloat minX = CGFLOAT_MAX, maxX = -CGFLOAT_MAX, midY = 0;
    NSUInteger counted = 0;
    for (NSValue *value in spans) {
        CGRect span = value.CGRectValue;
        if (counted && minX - CGRectGetMaxX(span) > kGroupGap) break;
        minX = MIN(minX, CGRectGetMinX(span));
        maxX = MAX(maxX, CGRectGetMaxX(span));
        midY += span.origin.y;
        counted++;
    }
    if (!counted) {
        holder.hidden = YES;
        return nil;
    }
    midY /= counted;
    if (holder.superview != host) [host insertSubview:holder atIndex:0];
    else if (host.subviews.firstObject != holder) [host sendSubviewToBack:holder];
    holder.hidden = NO;
    CGRect frame = CGRectMake(round(minX - pad), round(midY - height / 2), round(maxX - minX + 2 * pad), height);
    if (!CGRectEqualToRect(holder.frame, frame)) holder.frame = frame;
    return SGRGlassCapsuleInside(holder, key, frame.size, NO);
}

// The dimming SGRDarkenGlass puts inside a pane's content.
@interface SGRGlassDim : UIView
@end
@implementation SGRGlassDim
@end

void SGRShowGlass(UIView *shape, BOOL shown) {
    if ([shape isKindOfClass:UIVisualEffectView.class]) {
        UIVisualEffectView *glass = (UIVisualEffectView *)shape;
        if ((glass.effect != nil) != shown) glass.effect = shown ? SGGlassEffect() : nil;
        // A blur comes and goes by its effect, which leaves its content on screen: its dimming goes with it, or a dark
        // shape stays where the glass was.
        for (UIView *view in glass.contentView.subviews) {
            if ([view isKindOfClass:SGRGlassDim.class]) view.alpha = shown ? 1 : 0;
        }
    } else {
        shape.alpha = shown ? 1 : 0;
    }
}

#pragma mark - flat boxes and floating films

// A box of Spotify's made a clear capsule for the glass that goes in it.
static void clearCapsule(UIView *box, CGSize size) {
    if (box.backgroundColor != UIColor.clearColor) box.backgroundColor = UIColor.clearColor;
    if (box.layer.cornerRadius != size.height / 2) box.layer.cornerRadius = size.height / 2;
    if (box.layer.cornerCurve != kCACornerCurveContinuous) box.layer.cornerCurve = kCACornerCurveContinuous;
}

UIView *SGRGlassFlatBox(UIView *box, const void *key, BOOL prominent) {
    if (@available(iOS 26.0, *)) return nil;
    CGSize size = box.bounds.size;
    if (!box || size.width < 1 || size.height < 1) return nil;
    clearCapsule(box, size);
    // Not clipped below iOS 26 with the legacy glass: its press grows past the box, and the pane has its own corners.
    BOOL grows = SGUseLegacyGlass();
    if (box.layer.masksToBounds != !grows) box.layer.masksToBounds = !grows;
    return SGRGlassCapsuleInside(box, key, size, prominent);
}

static char kAccentFilmKey;

UIView *SGRGlassEncoreButton(UIView *button, const void *key, BOOL accent) {
    if (@available(iOS 26.0, *)) return nil;
    if (button.backgroundColor && ![button.backgroundColor isEqual:UIColor.clearColor]) button.backgroundColor = UIColor.clearColor;
    if (button.layer.backgroundColor) button.layer.backgroundColor = NULL;
    UIView *film = objc_getAssociatedObject(button, &kAccentFilmKey);
    UIView *inner = button.subviews.lastObject;
    if (inner && inner != film && CGSizeEqualToSize(inner.bounds.size, button.bounds.size)
        && inner.layer.backgroundColor && CGColorGetAlpha(inner.layer.backgroundColor) > 0.05) {
        inner.layer.backgroundColor = NULL;
    }
    UIView *glass = SGRGlassFlatBox(button, key, NO);
    if (!accent) return glass;
    if (!film) {
        film = [UIView new];
        film.userInteractionEnabled = NO;
        film.layer.cornerCurve = kCACornerCurveContinuous;
        objc_setAssociatedObject(button, &kAccentFilmKey, film, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *color = [SGRAccent() colorWithAlphaComponent:0.8];
    if (![film.backgroundColor isEqual:color]) film.backgroundColor = color;
    if (film.superview != button) [button insertSubview:film atIndex:glass ? 1 : 0];
    if (!CGRectEqualToRect(film.frame, button.bounds)) film.frame = button.bounds;
    CGFloat radius = button.bounds.size.height / 2;
    if (film.layer.cornerRadius != radius) film.layer.cornerRadius = radius;
    return glass;
}

UIView *SGRGlassFloatingCard(UIView *card, const void *glassKey, const void *filmKey, CGFloat maxRadius) {
    CGFloat radius = MIN(card.bounds.size.height / 2, maxRadius);
    if (card.layer.backgroundColor) card.layer.backgroundColor = NULL;
    if (card.layer.cornerRadius != radius) card.layer.cornerRadius = radius;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    BOOL clip = !SGUseLegacyGlass();
    if (card.layer.masksToBounds != clip) card.layer.masksToBounds = clip;
    UIView *glass = SGGlassFor(card, glassKey);
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (!CGRectEqualToRect(glass.frame, card.bounds)) glass.frame = card.bounds;
    SGShapeGlass(glass, radius, NO);
    SGRGlassFilm(card, filmKey, glass, radius);
    return glass;
}

static char kFillSizeKey;

UIView *SGRGlassFillBox(UIView *box, const void *key, BOOL prominent) {
    if (@available(iOS 26.0, *)) return nil;
    CGSize size = box.bounds.size;
    if (!box || !key || size.width < 1 || size.height < 1) return nil;
    SGRGlassMode mode = glassMode();
    clearCapsule(box, size);
    if (box.layer.masksToBounds) box.layer.masksToBounds = NO;

    UIView *shape = objc_getAssociatedObject(box, key);
    if (shape && [objc_getAssociatedObject(shape, &kInsideModeKey) integerValue] != mode) {
        [shape removeFromSuperview];
        shape = nil;
    }
    if (!shape) {
        shape = newShape(mode);
        shape.accessibilityElementsHidden = YES;
        objc_setAssociatedObject(shape, &kInsideModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(box, key, shape, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The size follows the box by autoresizing, not by a centre worked out from outside: a frame set on a pass goes stale the moment the
    // box is resized without that pass, as Create narrows the Refine field.
    shape.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (shape.superview != box) [box addSubview:shape];
    if (box.subviews.firstObject != shape) [box insertSubview:shape atIndex:0];
    shape.hidden = NO;
    if (!CGRectEqualToRect(shape.frame, box.bounds)) shape.frame = box.bounds;
    NSNumber *shaped = objc_getAssociatedObject(shape, &kFillSizeKey);
    if (!shaped || shaped.doubleValue != size.height) {
        SGShapeGlass(shape, size.height / 2, YES);
        objc_setAssociatedObject(shape, &kFillSizeKey, @(size.height), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    keepFilm(shape, prominent, mode);
    return shape;
}

void SGRGlassSetFilm(UIView *shape, BOOL on, CGFloat radius) {
    if (!shape) return;
    SGRGlassMode mode = glassMode();
    keepFilm(shape, on, mode);
    UIView *film = objc_getAssociatedObject(shape, &kFilmKey);
    if (film && on && film.layer.cornerRadius != radius) {
        film.layer.cornerRadius = radius;
        film.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

const CGFloat SGRBarDim = 0.45;

UIView *SGRDarkenGlass(UIView *pane, const void *key, CGFloat radius, CGFloat alpha) {
    if (@available(iOS 26.0, *)) return nil;
    UIView *content = [pane isKindOfClass:UIVisualEffectView.class] ? ((UIVisualEffectView *)pane).contentView
                    : [pane isKindOfClass:SGLegacyGlassView.class] ? ((SGLegacyGlassView *)pane).contentView : nil;
    if (!content) return nil;
    UIView *dim = SGLazyChild(content, key, ^UIView *{
        UIView *view = [SGRGlassDim new];
        view.userInteractionEnabled = NO;
        // Shown as the blur is (SGRShowGlass).
        if ([pane isKindOfClass:UIVisualEffectView.class] && !((UIVisualEffectView *)pane).effect) view.alpha = 0;
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        return view;
    });
    UIColor *color = [UIColor colorWithWhite:0 alpha:alpha];
    if (![dim.backgroundColor isEqual:color]) dim.backgroundColor = color;
    if (dim.superview != content) [content insertSubview:dim atIndex:0];
    if (!CGRectEqualToRect(dim.frame, content.bounds)) dim.frame = content.bounds;
    if (dim.layer.cornerRadius != radius) dim.layer.cornerRadius = radius;
    if (dim.layer.cornerCurve != pane.layer.cornerCurve) dim.layer.cornerCurve = pane.layer.cornerCurve;
    return dim;
}

UIView *SGRGlassFilm(UIView *host, const void *key, UIView *glass, CGFloat radius) {
    if (@available(iOS 26.0, *)) return nil;
    UIView *film = SGLazyChild(host, key, ^UIView *{
        UIView *view = [UIView new];
        view.backgroundColor = SGRGlassFilmColor();
        view.userInteractionEnabled = NO;
        view.layer.cornerCurve = kCACornerCurveContinuous;
        view.layer.masksToBounds = YES;
        return view;
    });
    if (film.superview != host) [host insertSubview:film aboveSubview:glass];
    if (!CGRectEqualToRect(film.frame, glass.frame)) film.frame = glass.frame;
    if (film.layer.cornerRadius != radius) film.layer.cornerRadius = radius;
    // The film covers its pane, and with it the pane's own highlight, so the film carries one.
    if ([glass isKindOfClass:SGLegacyGlassView.class]) {
        if (((SGLegacyGlassView *)glass).classic) SGLegacyGlassClassicSpecular(film.layer, film.bounds, radius);
        else SGLegacyGlassSpecular(film.layer, film.bounds, radius);
    }
    return film;
}

#pragma mark - a sheet's own chrome

// Whether `view` is sheet chrome rather than a row or card in the sheet's own list: it sits under `root`
// (sgr_sheetChromeRoot) with no scroll view between. The same footprint stripSheetChrome clears, so a
// view built after the first strip (the queue's footer) is cleared on its own repaint all the same.
BOOL SGRIsSheetChromeArea(UIView *view, UIView *root) {
    if (!root) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v != view && [v isKindOfClass:UIScrollView.class]) return NO;
        if (v == root) return YES;
    }
    return NO;
}

// A card the sheet draws on purpose, not a wrapper's leftover grey: the device picker's "this device" card
// and its Connect button.
// They are the sheet's content, and cleared they leave the picker a bare list with nothing marking the
// device that is playing.
BOOL SGRIsSheetCard(UIView *view) {
    if (SGRIsSwiftUICard(view)) return YES;
    return view.layer.cornerRadius >= 1 && view.bounds.size.height > 4 && view.bounds.size.width < 380;
}

// The device picker's cards are SwiftUI shapes painted an opaque #292929, which on the glass are the one
// grey left in the sheet. They become a translucent white, the same family as the Connect button's 10%.
CGColorRef SGRSheetCardFill(void) {
    static CGColorRef fill;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fill = CGColorRetain([UIColor colorWithWhite:1 alpha:0.12].CGColor); });
    return fill;
}

// A SwiftUI view of the sheet's content that is a card. The cards are inset from the page (374 of 390pt), while
// the page's own backdrop -- the full width _UIGraphicsView under a pushed page's scroll view, such as the Connect
// device menu's -- fills its host. That one is not a card: tinted like one it laid a white 12% film over the whole
// page, so it goes clear with the rest of the sheet's grey.
BOOL SGRIsSwiftUICard(UIView *view) {
    if (![NSStringFromClass(view.class) hasPrefix:@"SwiftUI"]) return NO;
    UIView *host = view.superview;
    CGSize size = view.bounds.size;
    if (host && size.width >= 1 && size.height >= 200 && size.width >= host.bounds.size.width - 1) return NO;
    return YES;
}

static void tintCard(UIView *view) {
    if (SGRIsSwiftUICard(view) && SGRIsSheetSurface(view.layer.backgroundColor)) view.layer.backgroundColor = SGRSheetCardFill();
}

static void clearFill(UIView *view) {
    tintCard(view);
    if (!SGKeepsColor(view) && !SGRIsSheetCard(view) && SGIsVisibleColor(view.layer.backgroundColor)) view.layer.backgroundColor = NULL;
}

// The opaque dark grey Spotify paints a sheet's rows and wrappers with (#1F1F1F: the queue's QueueCell, TrackRowQueue.Cell, SessionModifiersView and the ⋯ menu's table). Not SGIsBaseSurface:
// that stops at 0.10 for the #121212 page black, and this grey is 0.12.
BOOL SGRIsSheetSurface(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.95) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] <= 0.20;
    if (n < 3) return NO;
    return c[0] <= 0.20 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

// A row of the sheet's own list: every view nearly as wide as the sheet that carries the grey goes clear, the
// cell itself and the stacks the element framework wraps its content in. Narrow ones stay (an avatar's
// placeholder square, a badge): they are their own paint, not a band.
static void clearListPaint(UIView *view, CGFloat wide, int depth) {
    if (!view || depth > 12 || wide < 1) return;   // wide 0: the sheet is not laid out yet; the next pass does it
    tintCard(view);
    if (!SGKeepsColor(view) && !SGRIsSheetCard(view) && view.bounds.size.width >= wide && SGRIsSheetSurface(view.layer.backgroundColor)) {
        // Written through the view so its own backgroundColor and the layer say the same thing.
        view.backgroundColor = UIColor.clearColor;
    }
    // Spotify marks the wrappers and rows of Save in opaque. An opaque view with no fill is drawn over black, so
    // the glass behind the list stayed black with no paint left anywhere in the sheet.
    if (view.opaque && !SGKeepsColor(view) && view.bounds.size.width >= wide) {
        view.opaque = NO;
        view.layer.opaque = NO;
    }
    for (UIView *sub in view.subviews) clearListPaint(sub, wide, depth + 1);
}

void SGRClearSheetCellPaint(UIView *cell, UIView *root) {
    if (!cell || !root) return;
    clearListPaint(cell, root.bounds.size.width * SGRSheetBandShare, 0);
}

// Walked from the pane outward rather than by identifier, since sheets wrap their content a varying
// number of levels deep (the queue one, the ⋯ menu seven: its table sat one past the old cap of six and
// kept its grey). Any opaque fill goes: before the first list nothing here is a card, whatever grey
// Spotify paints it with. A scroll view or table is cleared itself, and so are the bands its rows paint
// (clearListPaint); its rows are otherwise left as every other list in the redesign leaves them
// (SGRRestyle.h). Gives up well down rather than walk into a sheet this has never seen.
static void stripSheetChrome(UIView *view, UIView *skip, CGFloat wide, int depth) {
    if (!view || view == skip || depth > 14) return;
    clearFill(view);
    if ([view isKindOfClass:UIScrollView.class]) {
        for (UIView *sub in view.subviews) clearListPaint(sub, wide, 0);
        return;
    }
    for (UIView *sub in view.subviews) stripSheetChrome(sub, skip, wide, depth + 1);
}

// A sheet is a big pane, and the glass of a small control is too thin for one: the page under it came through
// nearly sharp (blur 2) and took the eye off the sheet. So the pane blurs far more and carries a dark body
// and a hairline edge, which is what tells it from a plain blur -- the rim catching light, over a body dense
// enough to hold the content. Under Reduce Transparency the body is the solid fill alone.
static const CGFloat kSheetBlur = 10;
static char kSheetBodyKey, kSheetRimKey, kSheetDimKey;

// A layer of the pane's body (the tint, the rim, the dim): a plain view over the whole of `host`, made once under `key`.
static UIView *bodyLayer(UIView *host, const void *key) {
    UIView *view = SGLazyChild(host, key, ^UIView *{
        UIView *made = [UIView new];
        made.userInteractionEnabled = NO;
        made.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        return made;
    });
    if (!CGRectEqualToRect(view.frame, host.bounds)) view.frame = host.bounds;
    return view;
}

void SGRThickenSheetGlass(UIView *glass, CGFloat cornerRadius) {
    if ([glass isKindOfClass:SGLegacyGlassView.class]) ((SGLegacyGlassView *)glass).blurRadius = kSheetBlur;
    UIView *host = glassContent(glass);
    UIView *body = bodyLayer(host, &kSheetBodyKey);
    UIColor *tint = SGRReduceTransparency() ? SGRSolidGlassFill() : [UIColor colorWithWhite:1 alpha:0.24];
    if (![body.backgroundColor isEqual:tint]) body.backgroundColor = tint;
    // The rim: a hairline of light round the pane, drawn over the body.
    UIView *rim = bodyLayer(host, &kSheetRimKey);
    if (rim.layer.borderWidth == 0) {
        rim.layer.borderWidth = 1.0 / UIScreen.mainScreen.scale;
        rim.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.28].CGColor;
        rim.layer.cornerCurve = kCACornerCurveContinuous;
    }
    if (rim.layer.cornerRadius != cornerRadius) rim.layer.cornerRadius = cornerRadius;
    if (body.superview == host && host.subviews.firstObject != body) [host sendSubviewToBack:body];
    if (rim.superview == host && host.subviews.lastObject != rim) [host bringSubviewToFront:rim];
}

void SGRDimSheetGlass(UIView *glass, CGFloat alpha) {
    UIView *host = glassContent(glass);
    UIView *dim = bodyLayer(host, &kSheetDimKey);
    UIColor *tint = SGRReduceTransparency() ? UIColor.blackColor : [UIColor colorWithWhite:0 alpha:alpha];
    if (![dim.backgroundColor isEqual:tint]) dim.backgroundColor = tint;
    // Over the body, under the rim.
    UIView *body = objc_getAssociatedObject(host, &kSheetBodyKey);
    if (dim.superview != host) [host addSubview:dim];
    if (body.superview == host) [host insertSubview:dim aboveSubview:body];
    UIView *rim = objc_getAssociatedObject(host, &kSheetRimKey);
    if (rim.superview == host) [host bringSubviewToFront:rim];
}

UIView *SGRGlassPaneIn(UIView *host, const void *key, CGFloat radius) {
    UIView *glass = SGGlassFor(host, key);
    if (glass.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    if (!CGRectEqualToRect(glass.frame, host.bounds)) glass.frame = host.bounds;
    SGShapeGlass(glass, radius, NO);
    SGRThickenSheetGlass(glass, radius);
    return glass;
}

// The radius of the Genius meanings sheet: the screen's own corner radius, which the system sheet takes for its
// top corners. Every sheet the mod glasses takes the same one, so none of them has Spotify's smaller 12 or 16.
static const CGFloat kSheetRadiusFallback = 47;

CGFloat SGRSheetCornerRadius(void) {
    static CGFloat radius;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        radius = kSheetRadiusFallback;
        @try {
            id value = [UIScreen.mainScreen valueForKey:@"_displayCornerRadius"];
            if ([value respondsToSelector:@selector(doubleValue)] && [value doubleValue] > 0) radius = [value doubleValue];
        } @catch (__unused NSException *e) {}
    });
    return radius;
}

// The pane, the corners and the stripped grey of one sheet view `v`: what SGRGlassSheetChrome does once it has
// found the sheet by its identifier, and what a sheet with no such identifier (the share menu's) gets by name.
static char kSheetChromeGlassKey, kSheetOriginalKey, kShadowHeldKey;

// UIKit's shadow round a presented sheet: the UIDropShadowView the pane sits in, a few plain views up.
static UIView *dropShadowOf(UIView *v) {
    for (UIView *up = v.superview; up && ![up isKindOfClass:UIWindow.class]; up = up.superview) {
        if ([NSStringFromClass(up.class) isEqualToString:@"UIDropShadowView"]) return up;
    }
    return nil;
}

// How much black the glass carries over a page Spotify leaves undimmed: what its dimming puts behind the queue.
static const CGFloat kUndimmedSheetDim = 0.7;

// A sheet UIKit holds at its full height with no dimming behind it (Save in) carries UIDropShadowView's shadow: with no
// shadowPath it is the pane's own shape filled black at opacity 1 and blurred by 12, under the pane, and through the glass
// the whole sheet read black (shadowOpacity 1; the glass showed the player once it was 0). A glass pane
// has no shadow, and over a page with no dimming it takes the dimming's black itself.
//
// Taking it off once was not enough: UIKit writes the shadow again as the sheet moves between its detents and during its
// presentation, so Save in opened black and went to glass only on a later pass, and dragged up from its small detent it
// stayed black (shadowOpacity back at 1 after the drag). The shadow's layer is marked, and SGRSheetPopups.x's hook keeps
// it at 0 whenever UIKit writes it.
BOOL SGRSheetShadowHeld(CALayer *layer) {
    return objc_getAssociatedObject(layer, &kShadowHeldKey) != nil;
}

static void fitSheetSurroundings(UIView *v, UIView *glass) {
    UIView *shadow = dropShadowOf(v);
    if (shadow && !SGRSheetShadowHeld(shadow.layer)) objc_setAssociatedObject(shadow.layer, &kShadowHeldKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (shadow.layer.shadowOpacity > 0) shadow.layer.shadowOpacity = 0;
    UIView *dimming = nil;
    for (UIView *sibling in shadow.superview.subviews) {
        if ([sibling.accessibilityIdentifier isEqualToString:@"Components.UI.SheetPresentation.Dimming"]) dimming = sibling;
    }
    if (!dimming || SGRReduceTransparency()) return;
    CGColorRef fill = dimming.layer.backgroundColor;
    BOOL undimmed = !fill || CGColorGetAlpha(fill) < 0.05;
    SGRDimSheetGlass(glass, undimmed ? kUndimmedSheetDim : 0);
}

static UIView *chromeSheetView(UIView *v) {
    // What the pane looked like before the mod, so SGRRemoveSheetGlass can give it back.
    if (!objc_getAssociatedObject(v, &kSheetOriginalKey)) {
        id fill = v.layer.backgroundColor ? (id)[UIColor colorWithCGColor:v.layer.backgroundColor] : (id)[NSNull null];
        objc_setAssociatedObject(v, &kSheetOriginalKey, @{ @"radius": @(v.layer.cornerRadius), @"corners": @(v.layer.maskedCorners), @"fill": fill, @"shadow": @(dropShadowOf(v).layer.shadowOpacity) }, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIView *glass = SGGlassFor(v, &kSheetChromeGlassKey);
    glass.frame = v.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // Top corners only: the bottom of a sheet is off the screen's edge.
    CGFloat radius = SGRSheetCornerRadius();
    if (v.layer.cornerRadius != radius) v.layer.cornerRadius = radius;
    v.layer.cornerCurve = kCACornerCurveContinuous;
    v.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    SGShapeGlass(glass, radius, NO);
    SGRThickenSheetGlass(glass, radius);
    fitSheetSurroundings(v, glass);
    if (v.layer.backgroundColor) v.layer.backgroundColor = NULL;
    CGFloat wide = v.bounds.size.width * SGRSheetBandShare;
    for (UIView *sub in v.subviews) stripSheetChrome(sub, glass, wide, 0);
    // Spotify repaints the grey on later passes; SGRRepaint.x keeps clearing it under this root.
    if (sgr_sheetChromeRoot != v) {
        sgr_sheetChromeRoot = v;
        SGRWatchSheetPaint(v);
    }
    return glass;
}

UIView *SGRSheetPaneOf(UIView *view) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v.accessibilityIdentifier isEqualToString:@"sheet-view"]) return v;
    }
    return nil;
}

UIView *SGRGlassSheetChrome(UIView *content) {
    if (@available(iOS 26.0, *)) return nil;
    UIView *pane = SGRSheetPaneOf(content);
    return pane ? chromeSheetView(pane) : nil;
}

UIView *SGRGlassSheetView(UIView *sheet) {
    if (@available(iOS 26.0, *)) return nil;
    return sheet ? chromeSheetView(sheet) : nil;
}

void SGRRemoveSheetGlass(UIView *sheet) {
    if (!sheet) return;
    UIView *glass = objc_getAssociatedObject(sheet, &kSheetChromeGlassKey);
    NSDictionary *original = objc_getAssociatedObject(sheet, &kSheetOriginalKey);
    if (!glass && !original) return;
    if (glass) {
        [glass removeFromSuperview];
        objc_setAssociatedObject(sheet, &kSheetChromeGlassKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (original) {
        sheet.layer.cornerRadius = [original[@"radius"] doubleValue];
        sheet.layer.maskedCorners = (CACornerMask)[original[@"corners"] unsignedIntegerValue];
        id fill = original[@"fill"];
        // The pane's own paint was taken off for the glass, and with no glass behind it the page under the sheet shows through.
        sheet.backgroundColor = [fill isKindOfClass:UIColor.class] ? fill : UIColor.blackColor;
        CALayer *shadow = dropShadowOf(sheet).layer;
        objc_setAssociatedObject(shadow, &kShadowHeldKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        shadow.shadowOpacity = [original[@"shadow"] floatValue];
        objc_setAssociatedObject(sheet, &kSheetOriginalKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void SGRUnclipUpTo(UIView *view, BOOL (^isLast)(UIView *ancestor)) {
    for (UIView *v = view; v && ![v isKindOfClass:UIWindow.class]; v = v.superview) {
        if (v.clipsToBounds) v.clipsToBounds = NO;
        if (isLast(v)) return;
    }
}

#pragma mark - a name on glass

CGFloat SGRTitleWidth(UILabel *label) {
    return ceil([label sizeThatFits:CGSizeMake(CGFLOAT_MAX, SGRGlassCircleSize)].width);
}

UIView *SGRGlassTitleCapsule(UIView *holder, const void *key, CGFloat content, CGFloat room, BOOL (^isLast)(UIView *ancestor)) {
    if (!holder || content < 1) return nil;
    CGFloat width = MIN(MAX(content + 2 * SGRTitlePadding, SGRGlassCircleSize), room);
    if (isLast) SGRUnclipUpTo(holder, isLast);
    return SGRGlassCapsuleInside(holder, key, CGSizeMake(width, SGRGlassCircleSize), NO);
}

#pragma mark - a sheet's pane

UIView *SGRSheetPaneOfNavigation(UINavigationController *navigation) {
    UIView *pane = navigation.view.superview;
    if (!navigation || !pane || pane.bounds.size.width < 300) return nil;
    if (pane.bounds.size.height >= UIScreen.mainScreen.bounds.size.height - 1) return nil;
    return pane;
}
