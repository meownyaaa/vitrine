// The profile page over a Mirage background. Spotify paints the page's header with the profile picture's
// dominant color (a fill and a gradient across the whole top) and the sections under it on opaque black,
// which over a background reads as a colored slab and a black band. With "Profile picture glow" on, the
// page-wide color goes and the same color is drawn as a soft glow and ring just around the picture; the
// black page bands are cleared either way. Only while the page sits over a visible Mirage background
// (Everywhere), and all of it is put back when that or the toggle goes.
//
// Spotify 9.1.90 (class dump): Profile_CommonImpl.ProfileViewController > ProfileView (an
// SPTEntityHeaderViewController header whose content is Profile_CommonImpl.ProfileHeaderViewController,
// and componentsCollectionView). The header's views are Swift components with no recorded tree yet, so
// they are found by shape: page-wide gradient views/layers and colored fills in the header, and the
// picture as the largest round, square image view in it.
#import "MRGPrefs.h"
#import "MRGBackgroundView.h"
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>

@interface MRGGlowView : UIView
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, weak) UIView *picture;
- (void)placeAround:(UIView *)picture;
@end

static char kProfileKey, kGlowKey, kSavedAlphaKey, kSavedColorKey, kSavedHiddenKey, kTintKey;
// Everything changed on profile pages, to put back.
static NSHashTable *sg_touched;

static NSHashTable *touched(void) {
    if (!sg_touched) sg_touched = [NSHashTable weakObjectsHashTable];
    return sg_touched;
}

#pragma mark - colors

static BOOL rgba(UIColor *c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!c) return NO;
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w;
    if ([c getWhite:&w alpha:a]) { *r = *g = *b = w; return YES; }
    return NO;
}

static BOOL isDark(UIColor *c) {
    CGFloat r, g, b, a;
    return rgba(c, &r, &g, &b, &a) && a > 0.9 && MAX(r, MAX(g, b)) < 0.22;
}

// A fill that carries the header's color: opaque enough and not black, white or grey.
static BOOL isTint(UIColor *c) {
    CGFloat r, g, b, a;
    if (!rgba(c, &r, &g, &b, &a) || a < 0.3) return NO;
    CGFloat hi = MAX(r, MAX(g, b)), lo = MIN(r, MIN(g, b));
    return hi >= 0.15 && hi - lo > 0.06;
}

// Bright and saturated enough to glow over a dimmed background.
static UIColor *glowColor(UIColor *c) {
    CGFloat h, s, v, a;
    if (![c getHue:&h saturation:&s brightness:&v alpha:&a]) return c;
    return [UIColor colorWithHue:h saturation:MAX(s, 0.45) brightness:MAX(v, 0.8) alpha:1];
}

static UIColor *averageColor(UIImage *image) {
    static NSMapTable *cache;
    if (!cache) cache = [NSMapTable weakToStrongObjectsMapTable];
    UIColor *known = [cache objectForKey:image];
    if (known || !image) return known;
    CIImage *input = image.CIImage ?: (image.CGImage ? [CIImage imageWithCGImage:image.CGImage] : nil);
    if (!input) return nil;
    CIFilter *avg = [CIFilter filterWithName:@"CIAreaAverage"];
    [avg setValue:input forKey:kCIInputImageKey];
    [avg setValue:[CIVector vectorWithCGRect:input.extent] forKey:kCIInputExtentKey];
    static CIContext *ctx;
    if (!ctx) ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: NSNull.null}];
    uint8_t px[4] = {0};
    if (!avg.outputImage) return nil;
    [ctx render:avg.outputImage toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:nil];
    UIColor *c = [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
    [cache setObject:c forKey:image];
    return c;
}

static UIColor *firstTint(NSArray *cgColors) {
    for (id cg in cgColors) {
        UIColor *c = [UIColor colorWithCGColor:(__bridge CGColorRef)cg];
        if (isTint(c)) return c;
    }
    return nil;
}

#pragma mark - the glow

@implementation MRGGlowView {
    CAGradientLayer *_glow;
    CAShapeLayer *_ring;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.backgroundColor = UIColor.clearColor;
    _glow = [CAGradientLayer layer];
    _glow.type = kCAGradientLayerRadial;
    _glow.startPoint = CGPointMake(0.5, 0.5);
    _glow.endPoint = CGPointMake(1, 1);
    _glow.locations = @[@0, @0.42, @0.62, @1];
    [self.layer addSublayer:_glow];
    _ring = [CAShapeLayer layer];
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.lineWidth = 3;
    _ring.shadowOpacity = 1;
    _ring.shadowRadius = 10;
    _ring.shadowOffset = CGSizeZero;
    [self.layer addSublayer:_ring];
    return self;
}

- (void)setColor:(UIColor *)color {
    _color = color;
    UIColor *c = color ?: UIColor.whiteColor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _glow.colors = @[(id)[c colorWithAlphaComponent:0.95].CGColor, (id)[c colorWithAlphaComponent:0.7].CGColor,
                     (id)[c colorWithAlphaComponent:0.25].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
    _ring.strokeColor = [c colorWithAlphaComponent:0.9].CGColor;
    _ring.shadowColor = c.CGColor;
    [CATransaction commit];
}

// The glow is twice the picture's size, centred on it, in whatever view it stands in.
- (void)placeAround:(UIView *)picture {
    UIView *host = self.superview;
    if (!host || !picture.window) return;
    CGRect p = [host convertRect:picture.bounds fromView:picture];
    CGFloat side = MAX(p.size.width, p.size.height);
    CGRect frame = CGRectInset(p, -side * 0.5, -side * 0.5);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{ self.frame = frame; }];
    _glow.frame = self.bounds;
    CGRect ringRect = CGRectInset(CGRectMake(side * 0.5, side * 0.5, p.size.width, p.size.height), -3, -3);
    _ring.frame = self.bounds;
    _ring.path = [UIBezierPath bezierPathWithOvalInRect:ringRect].CGPath;
    [CATransaction commit];
}

@end

#pragma mark - page

static BOOL overMirageBackground(UIView *page) {
    if (!MRGBackgroundEnabled() || MRGCurrentKind() == MRGMediaNone) return NO;
    for (UIView *v = page; v; v = v.superview) {
        UIView *first = v.subviews.firstObject;
        if ([first isKindOfClass:MRGBackgroundView.class] && !first.hidden) return YES;
    }
    return NO;
}

static void saveAlpha(UIView *v) {
    if (!objc_getAssociatedObject(v, &kSavedAlphaKey)) objc_setAssociatedObject(v, &kSavedAlphaKey, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [touched() addObject:v];
}

static void saveColor(UIView *v) {
    if (!objc_getAssociatedObject(v, &kSavedColorKey))
        objc_setAssociatedObject(v, &kSavedColorKey, v.backgroundColor ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [touched() addObject:v];
}

static void hideLayer(CALayer *l) {
    if (!objc_getAssociatedObject(l, &kSavedHiddenKey)) objc_setAssociatedObject(l, &kSavedHiddenKey, @(l.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [touched() addObject:l];
    if (!l.hidden) l.hidden = YES;
}

static char kSavedColorsKey;
static void saveGradient(CAGradientLayer *l) {
    if (!objc_getAssociatedObject(l, &kSavedColorsKey))
        objc_setAssociatedObject(l, &kSavedColorsKey, l.colors ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [touched() addObject:l];
    if (l.colors.count) l.colors = nil;
}

static BOOL isGlowTouch(id o) { return objc_getAssociatedObject(o, &kTintKey) != nil; }

static void restoreObject(id o, BOOL glowOnly) {
    if (glowOnly && !isGlowTouch(o)) return;
    if ([o isKindOfClass:CALayer.class]) {
        NSNumber *h = objc_getAssociatedObject(o, &kSavedHiddenKey);
        if (h) ((CALayer *)o).hidden = h.boolValue;
        objc_setAssociatedObject(o, &kSavedHiddenKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id colors = objc_getAssociatedObject(o, &kSavedColorsKey);
        if (colors && [o isKindOfClass:CAGradientLayer.class]) ((CAGradientLayer *)o).colors = colors == NSNull.null ? nil : colors;
        objc_setAssociatedObject(o, &kSavedColorsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if ([o isKindOfClass:UIView.class]) {
        UIView *v = o;
        NSNumber *a = objc_getAssociatedObject(v, &kSavedAlphaKey);
        if (a) v.alpha = a.doubleValue;
        id c = objc_getAssociatedObject(v, &kSavedColorKey);
        if (c) v.backgroundColor = c == NSNull.null ? nil : c;
        objc_setAssociatedObject(v, &kSavedAlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(v, &kSavedColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    objc_setAssociatedObject(o, &kTintKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void removeGlow(UIView *page) {
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    [glow removeFromSuperview];
    objc_setAssociatedObject(page, &kGlowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void restorePage(UIView *page, BOOL glowOnly) {
    removeGlow(page);
    for (id o in touched().allObjects) {
        if ([o isKindOfClass:UIView.class] && ![(UIView *)o isDescendantOfView:page]) continue;
        if ([o isKindOfClass:CALayer.class]) {
            UIView *owner = (UIView *)((CALayer *)o).delegate;
            for (CALayer *l = o; !owner && l; l = l.superlayer) if ([l.delegate isKindOfClass:UIView.class]) owner = (UIView *)l.delegate;
            if (owner && ![owner isDescendantOfView:page]) continue;
        }
        restoreObject(o, glowOnly);
    }
}

static BOOL isHeaderController(UIResponder *r) {
    NSString *name = NSStringFromClass(r.class);
    return [name containsString:@"EntityHeaderViewController"] || [name containsString:@"ProfileHeaderViewController"];
}

static UIView *headerIn(UIView *page) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:page.subviews];
    NSUInteger seen = 0;
    UIView *found = nil;
    while (stack.count && seen++ < 1500) {
        UIView *v = stack.firstObject; [stack removeObjectAtIndex:0];   // breadth first: the outermost header
        if ([v isKindOfClass:UICollectionViewCell.class]) continue;
        if ([v.nextResponder isKindOfClass:UIViewController.class] && isHeaderController(v.nextResponder)) { found = v; break; }
        [stack addObjectsFromArray:v.subviews];
    }
    return found;
}

static void styleProfile(UIView *page) {
    if (!page.window) return;
    if (!overMirageBackground(page)) { restorePage(page, NO); return; }
    objc_setAssociatedObject(page, &kProfileKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL glowOn = MRGProfileGlow();
    if (!glowOn) restorePage(page, YES);

    CGFloat W = page.bounds.size.width;
    UIView *header = headerIn(page);
    CGFloat headerBottom = header ? CGRectGetMaxY([page convertRect:header.bounds fromView:header]) : page.bounds.size.height * 0.5;
    UIColor *tint = nil;
    UIImageView *picture = nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:page.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 3000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGBackgroundView.class] || [v isKindOfClass:MRGGlowView.class] ||
            [v isKindOfClass:UIVisualEffectView.class] || v.hidden) continue;
        BOOL cell = [v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class];
        CGRect f = [page convertRect:v.bounds fromView:v];
        BOOL wide = f.size.width >= W * 0.9;
        BOOL inHeader = header ? [v isDescendantOfView:header] || v == header : CGRectGetMinY(f) < headerBottom;

        // The black bands: the page's own wide fills and the sections' (cells, headers) near-black fills.
        if (isDark(v.backgroundColor) && (wide || cell || [v isKindOfClass:UICollectionReusableView.class])) {
            saveColor(v);
            v.backgroundColor = UIColor.clearColor;
        }
        if (cell) {
            for (UIView *sub in ((UICollectionViewCell *)v).contentView.subviews) {
                if (isDark(sub.backgroundColor) && sub.bounds.size.width >= v.bounds.size.width * 0.9) {
                    saveColor(sub);
                    sub.backgroundColor = UIColor.clearColor;
                }
            }
            continue;   // nothing of the header lives in a cell
        }

        if (inHeader) {
            // The page-wide color: gradient views and layers, and colored fills.
            if (wide && glowOn) {
                BOOL gradientLayer = [v.layer isKindOfClass:CAGradientLayer.class];
                BOOL gradientView = gradientLayer || [NSStringFromClass(v.class) containsString:@"Gradient"];
                if (gradientLayer) tint = tint ?: firstTint(((CAGradientLayer *)v.layer).colors);
                if (gradientView && !v.subviews.count) {
                    // A leaf: faded out whole.
                    saveAlpha(v);
                    objc_setAssociatedObject(v, &kTintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    if (v.alpha != 0) v.alpha = 0;
                    continue;
                }
                if (gradientLayer) {
                    // It holds the header's content (maybe the picture): only its colors go.
                    saveGradient((CAGradientLayer *)v.layer);
                    objc_setAssociatedObject(v.layer, &kTintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                }
                if (isTint(v.backgroundColor)) {
                    tint = tint ?: v.backgroundColor;
                    saveColor(v);
                    objc_setAssociatedObject(v, &kTintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    v.backgroundColor = UIColor.clearColor;
                }
                for (CALayer *l in v.layer.sublayers) {
                    if (![l isKindOfClass:CAGradientLayer.class] || l.bounds.size.width < W * 0.9) continue;
                    tint = tint ?: firstTint(((CAGradientLayer *)l).colors);
                    objc_setAssociatedObject(l, &kTintKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                    hideLayer(l);
                }
            }
            // The picture: the largest square, round image view in the header.
            if ([v isKindOfClass:UIImageView.class] && ((UIImageView *)v).image) {
                CGSize s = v.bounds.size;
                CGFloat radius = MAX(v.layer.cornerRadius, v.superview.layer.cornerRadius);
                BOOL round = radius >= s.width * 0.4 || v.layer.mask || v.superview.layer.mask;
                if (fabs(s.width - s.height) < 2 && s.width >= 56 && s.width <= 240 && round &&
                    s.width > picture.bounds.size.width) picture = (UIImageView *)v;
            }
        }
        [stack addObjectsFromArray:v.subviews];
    }

    if (!glowOn || !picture) { removeGlow(page); return; }
    UIColor *color = glowColor(tint ?: averageColor(picture.image) ?: UIColor.whiteColor);
    // In the picture's container, under the picture; higher up past containers that clip and are too small.
    CGFloat need = MAX(picture.bounds.size.width, picture.bounds.size.height) * 2;
    UIView *below = picture, *container = picture.superview;
    for (int i = 0; i < 5 && container && container != page; i++) {
        if (!container.clipsToBounds || (container.bounds.size.width >= need && container.bounds.size.height >= need)) break;
        below = container;
        container = container.superview;
    }
    if (!container) return;
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    if (!glow) {
        glow = [[MRGGlowView alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(page, &kGlowKey, glow, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glow.superview != container || [container.subviews indexOfObject:glow] + 1 != [container.subviews indexOfObject:below])
        [container insertSubview:glow belowSubview:below];
    if (![glow.color isEqual:color]) glow.color = color;
    glow.picture = picture;
    [glow placeAround:picture];
}

// Between full passes (at most two a second) a header layout only re-applies what is already known: the
// page-wide color stays off and the glow follows the picture. A scroll lays the header out every frame.
static char kLastStyleKey;
static NSUInteger sg_settingsEpoch;
static char kEpochKey;

static void reapplyProfile(UIView *page) {
    for (id o in touched().allObjects) {
        if (!isGlowTouch(o)) continue;
        if ([o isKindOfClass:CAGradientLayer.class] && objc_getAssociatedObject(o, &kSavedColorsKey)) {
            if (((CAGradientLayer *)o).colors.count) ((CAGradientLayer *)o).colors = nil;
        } else if ([o isKindOfClass:CALayer.class]) {
            if (!((CALayer *)o).hidden) ((CALayer *)o).hidden = YES;
        } else if ([o isKindOfClass:UIView.class] && [(UIView *)o isDescendantOfView:page]) {
            UIView *v = o;
            if (objc_getAssociatedObject(v, &kSavedAlphaKey) && v.alpha != 0) v.alpha = 0;
            if (objc_getAssociatedObject(v, &kSavedColorKey) && CGColorGetAlpha(v.backgroundColor.CGColor) > 0) v.backgroundColor = UIColor.clearColor;
        }
    }
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    UIView *picture = glow.picture;
    if (glow.superview && picture) [glow placeAround:picture];
}

static void profileLaidOut(UIView *page) {
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(page, &kLastStyleKey);
    BOOL sameSettings = [objc_getAssociatedObject(page, &kEpochKey) unsignedIntegerValue] == sg_settingsEpoch;
    objc_setAssociatedObject(page, &kEpochKey, @(sg_settingsEpoch), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sameSettings && last && now - last.doubleValue < 0.5) {
        if (MRGProfileGlow() && overMirageBackground(page)) reapplyProfile(page);
        return;
    }
    objc_setAssociatedObject(page, &kLastStyleKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    styleProfile(page);
}

%group MRGProfile
%hook _TtC18Profile_CommonImpl21ProfileViewController
- (void)viewDidLayoutSubviews { %orig; profileLaidOut(((UIViewController *)self).view); }
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *page = ((UIViewController *)self).view;
    styleProfile(page);
    // The header's component fills in after the page appears (the picture and its color load).
    __weak UIView *weakPage = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakPage) styleProfile(weakPage);
    });
}
%end

// The header moves and repaints as the page scrolls (it is pinned and fades to its minimum height).
%hook SPTEntityHeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *page = ((UIViewController *)self).view.superview;
    for (; page; page = page.superview) if (objc_getAssociatedObject(page, &kProfileKey)) break;
    if (page) profileLaidOut(page);
}
%end
%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"_TtC18Profile_CommonImpl21ProfileViewController")) return;
        if (!NSClassFromString(@"SPTEntityHeaderViewController")) return;
        %init(MRGProfile);
        // A settings change lays every page out again (MRGBackgrounds.x relayoutAll); the next pass on a
        // profile page is a full one, so the toggle takes effect at once.
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            sg_settingsEpoch++;
        }];
    }
}
