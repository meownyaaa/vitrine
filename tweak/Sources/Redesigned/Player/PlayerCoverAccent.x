// Player redesign: Follow the cover, the player's accent from the cover of the song playing.
//
// Spotify draws its lit controls with the accent baked in (Kit/SGRAccent.x swaps it where a color is made): the
// shuffle and repeat icons are images drawn in it, the repeat dot is a view with it as its background, and the like
// checkmark is a Lottie animation whose shape layers are filled with it. None of them asks for the color again, so
// the player paints them itself, over Spotify's bottom stack (the title row with the like, the progress bar, the
// controls and the footer): an image drawn in the accent is tinted from its own shape, a background or a shape layer
// in the accent takes the color, and every original is kept to give back. It paints whenever the cover's color
// changes and whenever the stack or one of its buttons lays out, which is when Spotify hands a button its new state.
//
// The mini player's lit buttons, its device glyph and its like (trees: t-home17e 1916-1945), are painted the same way,
// those two alone so the cover on the card is never judged: when the cover's color changes, which reaches here with the
// player never opened (PlayerField.x), when the bar or one of the two buttons lays out, and when the device glyph is
// handed a new image, which lays nothing out. Only the tab bar's bar (sgr_nowPlayingRoot), not the one on Spotify's sheets.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Kit/SGRRepaint.h"
#import "Player.h"

static NSInteger sg_cover = -1;   // 0xRRGGBB while a cover gives one, else -1
static __weak UIView *sg_stack;   // the bottom stack last painted
static char kOriginalKey, kTintedKey, kTintedCoverKey, kAccentImageKey, kInkKey, kOriginalFillKey, kOriginalStrokeKey, kObservedKey;
static NSString *const kBarConnectId = @"Components.ConnectButtonOutputSwitcher", *const kBarLikeId = @"Components.UI.AddToButton";

BOOL SGRPlayerFollowsCover(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGHidden(SGRKeyPlayerFollowsCover); });
    return on;
}

static void unpack(NSInteger rgb, CGFloat *r, CGFloat *g, CGFloat *b) {
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
}

// Made once per cover color: every pass over the stack hands it out.
static UIColor *coverColor(void) {
    static NSInteger madeFor = -1;
    static UIColor *made;
    if (made && madeFor == sg_cover) return made;
    CGFloat r, g, b;
    unpack(sg_cover, &r, &g, &b);
    made = [UIColor colorWithRed:r green:g blue:b alpha:1];
    madeFor = sg_cover;
    return made;
}

// -[UIColor getHue:saturation:brightness:alpha:] worked out from the components, without making a color for it.
static void hsv(CGFloat r, CGFloat g, CGFloat b, CGFloat *h, CGFloat *s, CGFloat *v) {
    CGFloat high = MAX(r, MAX(g, b)), low = MIN(r, MIN(g, b)), range = high - low;
    *v = high;
    *s = high > 0 ? range / high : 0;
    if (range <= 0 || high <= 0) *h = 0;
    else if (high == r) *h = (g - b) / range;
    else if (high == g) *h = 2 + (b - r) / range;
    else *h = 4 + (r - g) / range;
    *h /= 6;
    if (*h < 0) *h += 1;
}

// Whether a color is the accent's: its hue within kHueNear, and colorful. Darker shades of it count (a pressed state).
// A color made from Spotify's green comes out as the accent (Kit/SGRAccent.x), so that green is judged as the accent.
static const CGFloat kHueNear = 0.05, kColorful = 0.35;
static BOOL accentLike(CGFloat r, CGFloat g, CGFloat b) {
    static CGFloat accentHue = -1;
    if (accentHue < 0) {
        CGFloat ar, ag, ab, s, v;
        unpack(SGRAccentRGB(), &ar, &ag, &ab);
        SGRAccentSwap(&ar, &ag, &ab);
        hsv(ar, ag, ab, &accentHue, &s, &v);
    }
    CGFloat h, s, v;
    SGRAccentSwap(&r, &g, &b);
    hsv(r, g, b, &h, &s, &v);
    CGFloat d = fabs(h - accentHue);
    return MIN(d, 1 - d) < kHueNear && s > kColorful && v > 0.2;
}

BOOL SGRPlayerAccentLike(UIColor *color) {
    CGFloat r, g, b, a;
    return color && [color getRed:&r green:&g blue:&b alpha:&a] && a > 0.5 && accentLike(r, g, b);
}

static BOOL cgAccentLike(CGColorRef color) {
    if (!color || CGColorGetNumberOfComponents(color) != 4) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    return c[3] > 0.5 && accentLike(c[0], c[1], c[2]);
}

UIColor *SGRPlayerImageInk(UIImage *image) {
    id known = objc_getAssociatedObject(image, &kInkKey);
    if (known) return known == NSNull.null ? nil : known;
    enum { kSide = 16 };
    uint8_t pixels[kSide * kSide * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, kSide, kSide, 8, kSide * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    UIColor *ink = nil;
    if (context && image.CGImage) {
        CGContextDrawImage(context, CGRectMake(0, 0, kSide, kSide), image.CGImage);
        double r = 0, g = 0, b = 0, n = 0;
        for (int i = 0; i < kSide * kSide; i++) {
            uint8_t alpha = pixels[i * 4 + 3];
            if (alpha < 128) continue;
            r += pixels[i * 4] / (double)alpha;
            g += pixels[i * 4 + 1] / (double)alpha;
            b += pixels[i * 4 + 2] / (double)alpha;
            n++;
        }
        if (n >= 4) ink = [UIColor colorWithRed:r / n green:g / n blue:b / n alpha:1];
    }
    if (context) CGContextRelease(context);
    objc_setAssociatedObject(image, &kInkKey, ink ?: NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return ink;
}

// Whether an image is drawn in the accent, judged once and kept on it.
static BOOL imageAccentLike(UIImage *image) {
    NSNumber *known = objc_getAssociatedObject(image, &kAccentImageKey);
    if (known) return known.boolValue;
    BOOL accent = SGRPlayerAccentLike(SGRPlayerImageInk(image));
    objc_setAssociatedObject(image, &kAccentImageKey, @(accent), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return accent;
}

static void paintImageView(UIImageView *view) {
    UIImage *image = view.image, *tinted = objc_getAssociatedObject(view, &kTintedKey);
    UIImage *original = image == tinted ? objc_getAssociatedObject(view, &kOriginalKey) : image;
    if (!original) return;
    // A UIButton puts its own image back on every layout pass: the tint made for this cover goes back, not a new one.
    if (tinted && image != tinted && image == objc_getAssociatedObject(view, &kOriginalKey)
        && sg_cover >= 0 && [objc_getAssociatedObject(view, &kTintedCoverKey) integerValue] == sg_cover) {
        view.image = tinted;
        return;
    }
    if (sg_cover < 0 || !imageAccentLike(original)) {
        if (image == tinted && tinted) view.image = original;
        objc_setAssociatedObject(view, &kTintedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    // A tint made for an earlier cover is drawn again in this one; Spotify's icons only change on a state change.
    if (image == tinted && tinted && [objc_getAssociatedObject(view, &kTintedCoverKey) integerValue] == sg_cover) return;
    UIImage *made = [original imageWithTintColor:coverColor() renderingMode:UIImageRenderingModeAlwaysOriginal];
    objc_setAssociatedObject(view, &kOriginalKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kTintedKey, made, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kTintedCoverKey, @(sg_cover), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.image = made;
}

static void paintBackground(UIView *view) {
    UIColor *original = objc_getAssociatedObject(view, &kOriginalKey);
    UIColor *current = view.backgroundColor;
    if (!original && !SGRPlayerAccentLike(current)) return;
    if (!original) {
        original = current;
        objc_setAssociatedObject(view, &kOriginalKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    UIColor *color = sg_cover < 0 ? original : coverColor();
    if (![view.backgroundColor isEqual:color]) view.backgroundColor = color;
}

static void paintShape(CAShapeLayer *layer) {
    for (int stroke = 0; stroke < 2; stroke++) {
        void *key = stroke ? &kOriginalStrokeKey : &kOriginalFillKey;
        id original = objc_getAssociatedObject(layer, key);
        CGColorRef current = stroke ? layer.strokeColor : layer.fillColor;
        if (!original && !cgAccentLike(current)) continue;
        if (!original) {
            original = (__bridge id)current;
            objc_setAssociatedObject(layer, key, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CGColorRef color = sg_cover < 0 ? (__bridge CGColorRef)original : coverColor().CGColor;
        if (CGColorEqualToColor(current, color)) continue;
        if (stroke) layer.strokeColor = color;
        else layer.fillColor = color;
    }
}

static char kOriginalAnimationsKey;
static NSString *const kPaintedKey = @"spotifyglass.coverPainted";

// Lottie's Core Animation renderer colors a shape with a keyframe animation on fillColor or strokeColor, which shows
// over the layer's own value: those keyframes in the accent take the cover's color, the animations as Lottie made
// them kept by key to give back.
static void paintAnimations(CALayer *layer) {
    NSMutableDictionary<NSString *, CAAnimation *> *originals = objc_getAssociatedObject(layer, &kOriginalAnimationsKey);
    for (NSString *key in layer.animationKeys) {
        CAAnimation *animation = [layer animationForKey:key];
        if (![animation isKindOfClass:CAKeyframeAnimation.class]) continue;
        CAKeyframeAnimation *keyframes = (CAKeyframeAnimation *)animation;
        if (![keyframes.keyPath isEqualToString:@"fillColor"] && ![keyframes.keyPath isEqualToString:@"strokeColor"]) continue;
        // A layer copies what it is given, so a painted animation is told by the cover it carries, not by identity.
        NSNumber *painted = [animation valueForKey:kPaintedKey];
        CAKeyframeAnimation *base = keyframes;
        if (painted) {
            CAKeyframeAnimation *original = (CAKeyframeAnimation *)originals[key];
            if (!original) continue;
            if (sg_cover < 0) {
                [layer addAnimation:original forKey:key];
                [originals removeObjectForKey:key];
                continue;
            }
            if (painted.integerValue == sg_cover) continue;
            base = original;
        } else {
            if (sg_cover < 0) continue;
            if (!originals) {
                originals = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(layer, &kOriginalAnimationsKey, originals, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            originals[key] = keyframes;
        }
        BOOL any = NO;
        NSMutableArray *values = [NSMutableArray arrayWithCapacity:base.values.count];
        for (id value in base.values) {
            BOOL accent = CFGetTypeID((__bridge CFTypeRef)value) == CGColorGetTypeID() && cgAccentLike((__bridge CGColorRef)value);
            any |= accent;
            [values addObject:accent ? (__bridge id)coverColor().CGColor : value];
        }
        if (!any) {
            [originals removeObjectForKey:key];
            continue;
        }
        CAKeyframeAnimation *made = [base copy];
        made.values = values;
        [made setValue:@(sg_cover) forKey:kPaintedKey];
        [layer addAnimation:made forKey:key];
    }
}

static void paintLayers(CALayer *layer) {
    if ([layer isKindOfClass:CAShapeLayer.class]) paintShape((CAShapeLayer *)layer);
    if (layer.animationKeys.count) paintAnimations(layer);
    for (CALayer *sublayer in layer.sublayers) paintLayers(sublayer);
}

static void paintTree(UIView *root) {
    static Class lottie;
    if (!lottie) lottie = NSClassFromString(@"Lottie.LottieAnimationView");
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    SGForEachView(root, ^(UIView *view) {
        if ([view.accessibilityIdentifier isEqualToString:SGRPlainCheckIdentifier]) view.tintColor = sg_cover < 0 ? SGRAccent() : coverColor();
        else if ([view isKindOfClass:UIImageView.class]) paintImageView((UIImageView *)view);
        else if (lottie && [view isKindOfClass:lottie]) paintLayers(view.layer);
        else paintBackground(view);
    });
    [CATransaction commit];
}

void SGRPlayerPaintCover(UIView *stack) {
    if (!SGRPlayerFollowsCover() || !stack) return;
    if (stack.superview && [stack isKindOfClass:UIStackView.class]) sg_stack = stack;
    paintTree(stack);
}

static BOOL isBarButton(UIView *view) {
    NSString *name = view.accessibilityIdentifier;
    return name && ([name isEqualToString:kBarConnectId] || [name isEqualToString:kBarLikeId]);
}

// The bar's two buttons, found once per bar and cover and again only when one is gone from it: the bar lays out on
// every track change, page swipe and Jam strip move, and a walk of its hundred views on each of those was #96's kind
// of cost. A bar with one of them, or neither (an ad, an episode), is not walked again on each layout either.
static __weak UIView *sg_barConnect, *sg_barLike, *sg_barSearched;

static BOOL findBarButtons(UIView *bar) {
    UIView *connect = sg_barConnect, *like = sg_barLike;
    if (bar == sg_barSearched && (!connect || [connect isDescendantOfView:bar]) && (!like || [like isDescendantOfView:bar]))
        return connect || like;
    sg_barSearched = bar;
    __block UIView *foundConnect = nil, *foundLike = nil;
    SGForEachView(bar, ^(UIView *view) {
        NSString *name = view.accessibilityIdentifier;
        if (!foundConnect && [name isEqualToString:kBarConnectId]) foundConnect = view;
        else if (!foundLike && [name isEqualToString:kBarLikeId]) foundLike = view;
    });
    sg_barConnect = foundConnect;
    sg_barLike = foundLike;
    SGForEachView(foundConnect, ^(UIView *inner) {
        if (![inner isKindOfClass:UIImageView.class] || objc_getAssociatedObject(inner, &kObservedKey)) return;
        objc_setAssociatedObject(inner, &kObservedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        // The tint set back reports too, and stops there: the image is the tint made for this cover.
        SGRObserveImage((UIImageView *)inner, ^(UIImageView *changed) { paintImageView(changed); });
    });
    return foundConnect || foundLike;
}

static void paintBar(UIView *bar) {
    if (!bar || !findBarButtons(bar)) return;
    UIView *connect = sg_barConnect, *like = sg_barLike;
    if (connect) paintTree(connect);
    if (like) paintTree(like);
}

void SGRPlayerSetCoverAccent(UIColor *cover) {
    NSInteger rgb = -1;
    CGFloat h, s, v, a;
    if ([cover getHue:&h saturation:&s brightness:&v alpha:&a] && s >= 0.15) {
        // Bright and clear enough to read on the dark player, the hue kept.
        UIColor *bright = [UIColor colorWithHue:h saturation:MIN(0.85, MAX(0.45, s)) brightness:MAX(0.9, v) alpha:1];
        CGFloat r, g, b;
        [bright getRed:&r green:&g blue:&b alpha:&a];
        rgb = ((NSInteger)lround(r * 255) << 16) | ((NSInteger)lround(g * 255) << 8) | (NSInteger)lround(b * 255);
    }
    if (rgb == sg_cover) return;
    sg_cover = rgb;
    SGLog(@"redesign player: follow the cover %@", rgb < 0 ? @"gives the accent back (a gray cover)" : [NSString stringWithFormat:@"paints #%06lX", (long)rgb]);
    SGRPlayerPaintCover(sg_stack);
    sg_barSearched = nil; // a new cover looks again, for a button the last bar state did not have
    paintBar(sgr_nowPlayingRoot);
}

// A button in the player's stack, or the mini player's device or like button, laid out: Spotify hands it a new state's
// icon or animation this way.
%hook UIButton
- (void)layoutSubviews {
    %orig;
    if (sg_cover < 0 && !objc_getAssociatedObject(self, &kTintedKey)) return;
    UIView *stack = sg_stack, *bar = sgr_nowPlayingRoot, *button = (UIView *)self;
    // A descendant shares the stack's window, so a button in another (or the stack off screen) skips the walk up.
    if (stack && button.window == stack.window && [button isDescendantOfView:stack]) SGRPlayerPaintCover(button);
    else if (bar && (isBarButton(button) || isBarButton(button.superview)) && [button isDescendantOfView:bar]) paintTree(button);
}
%end

%hook _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLayoutSubviews {
    %orig;
    // A gray cover was given back to the accent when it came (SGRPlayerSetCoverAccent), which left nothing to paint.
    if (sg_cover < 0) return;
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (view && view == sgr_nowPlayingRoot) paintBar(view);
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGRPlayerFollowsCover()) return;
    %init;
}
