// The profile page over a Mirage background. Spotify paints the page's header with the profile picture's
// dominant color (a fill and a gradient across the top), shows a collapsed header bar in that color once the
// picture has mostly scrolled away, and lays the sections under it on opaque dark gray, which over a
// background reads as a colored slab, a box that snaps in on scroll, and a gray band. With "Profile picture
// glow" on the page-wide color goes and the same color is drawn as a soft glow and ring just around the
// picture; the dark bands are cleared either way. Only while the page sits over a visible Mirage background
// (Everywhere), and all of it is put back when that or the toggle goes.
//
// Spotify 9.1.90 (class dump): Profile_CommonImpl.ProfileViewController > ProfileView (an
// SPTEntityHeaderViewController header whose content is Profile_CommonImpl.ProfileHeaderViewController,
// and componentsCollectionView). The header's views are Swift components with no recorded tree, so they are
// found by shape.
//
// 0.1.2 cleared those views once per pass, and Spotify set them again on every scroll frame and at the
// collapse threshold: the box came back and the glow flickered against the repaint. Now the layers are
// suppressed at their setters: each one Mirage takes over gets a runtime subclass of its own layer class
// (the way KVO does it) whose setBackgroundColor:, setOpacity:, setHidden: and setColors: keep Mirage's value
// and remember Spotify's for later. Wide views across the top of the page are taken over before Spotify
// paints them, so the collapsed bar's fill never shows. Nothing else in the app is touched.
#import "MRGPrefs.h"
#import "MRGBackgroundView.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreImage/CoreImage.h>

#pragma mark - suppressing a layer's setters

// What Mirage holds on a layer. The associated value is Spotify's latest value, boxed (NSNull for nil).
static char kSupBG, kSupOpacity, kSupHidden, kSupColors, kSupBase, kGlowRelated;
static NSHashTable *sg_suppressed;
static NSMutableDictionary<NSString *, Class> *sg_subclasses;

static BOOL isSuppressing(CALayer *l, const void *key) { return objc_getAssociatedObject(l, key) != nil; }

static Class suppressingClass(Class base) {
    NSString *name = NSStringFromClass(base);
    if ([name hasPrefix:@"MRGSup_"]) return base;
    if ([name hasPrefix:@"NSKVONotifying_"] || [name containsString:@"<"]) return Nil;
    if (!sg_subclasses) sg_subclasses = [NSMutableDictionary dictionary];
    Class sub = sg_subclasses[name];
    if (sub) return sub;
    NSString *subName = [@"MRGSup_" stringByAppendingString:name];
    sub = objc_allocateClassPair(base, subName.UTF8String, 0);
    if (!sub) return Nil;

    class_addMethod(sub, @selector(setBackgroundColor:), imp_implementationWithBlock(^(CALayer *self, CGColorRef color) {
        struct objc_super sup = {self, base};
        if (isSuppressing(self, &kSupBG)) {
            objc_setAssociatedObject(self, &kSupBG, color ? (id)[UIColor colorWithCGColor:color] : (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            color = NULL;
        }
        ((void (*)(struct objc_super *, SEL, CGColorRef))objc_msgSendSuper)(&sup, @selector(setBackgroundColor:), color);
    }), "v@:^{CGColor=}");
    class_addMethod(sub, @selector(setOpacity:), imp_implementationWithBlock(^(CALayer *self, float opacity) {
        struct objc_super sup = {self, base};
        if (isSuppressing(self, &kSupOpacity)) {
            objc_setAssociatedObject(self, &kSupOpacity, @(opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            opacity = 0;
        }
        ((void (*)(struct objc_super *, SEL, float))objc_msgSendSuper)(&sup, @selector(setOpacity:), opacity);
    }), "v@:f");
    class_addMethod(sub, @selector(setHidden:), imp_implementationWithBlock(^(CALayer *self, BOOL hidden) {
        struct objc_super sup = {self, base};
        if (isSuppressing(self, &kSupHidden)) {
            objc_setAssociatedObject(self, &kSupHidden, @(hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            hidden = YES;
        }
        ((void (*)(struct objc_super *, SEL, BOOL))objc_msgSendSuper)(&sup, @selector(setHidden:), hidden);
    }), "v@:B");
    if ([base isSubclassOfClass:CAGradientLayer.class]) {
        class_addMethod(sub, @selector(setColors:), imp_implementationWithBlock(^(CALayer *self, NSArray *colors) {
            struct objc_super sup = {self, base};
            if (isSuppressing(self, &kSupColors)) {
                objc_setAssociatedObject(self, &kSupColors, colors ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                colors = nil;
            }
            ((void (*)(struct objc_super *, SEL, NSArray *))objc_msgSendSuper)(&sup, @selector(setColors:), colors);
        }), "v@:@");
    }
    // Still reports the class it was, as a KVO subclass does.
    class_addMethod(sub, @selector(class), imp_implementationWithBlock(^Class(id self) { return base; }), "#@:");
    objc_registerClassPair(sub);
    sg_subclasses[name] = sub;
    return sub;
}

static BOOL adopt(CALayer *l) {
    if ([NSStringFromClass(object_getClass(l)) hasPrefix:@"MRGSup_"]) return YES;
    Class base = object_getClass(l);
    Class sub = suppressingClass(base);
    if (!sub) return NO;
    objc_setAssociatedObject(l, &kSupBase, base, OBJC_ASSOCIATION_ASSIGN);
    object_setClass(l, sub);
    if (!sg_suppressed) sg_suppressed = [NSHashTable weakObjectsHashTable];
    [sg_suppressed addObject:l];
    return YES;
}

// Each takes the current value as Spotify's and applies Mirage's at once, without an animation.
static void suppressBG(CALayer *l, BOOL glow) {
    if (isSuppressing(l, &kSupBG) || !adopt(l)) return;
    CGColorRef c = l.backgroundColor;
    objc_setAssociatedObject(l, &kSupBG, c ? (id)[UIColor colorWithCGColor:c] : (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (glow) objc_setAssociatedObject(l, &kGlowRelated, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    l.backgroundColor = NULL;
    [CATransaction commit];
}

static void suppressOpacity(CALayer *l) {
    if (isSuppressing(l, &kSupOpacity) || !adopt(l)) return;
    objc_setAssociatedObject(l, &kSupOpacity, @(l.opacity), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kGlowRelated, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    l.opacity = 0;
    [CATransaction commit];
}

static void suppressHidden(CALayer *l) {
    if (isSuppressing(l, &kSupHidden) || !adopt(l)) return;
    objc_setAssociatedObject(l, &kSupHidden, @(l.hidden), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kGlowRelated, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    l.hidden = YES;
}

static void suppressColors(CAGradientLayer *l) {
    if (isSuppressing(l, &kSupColors) || !adopt(l)) return;
    objc_setAssociatedObject(l, &kSupColors, l.colors ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kGlowRelated, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    l.colors = nil;
    [CATransaction commit];
}

// Spotify's latest values back, and the layer its own class again.
static void release_(CALayer *l) {
    id bg = objc_getAssociatedObject(l, &kSupBG), op = objc_getAssociatedObject(l, &kSupOpacity);
    id hid = objc_getAssociatedObject(l, &kSupHidden), cols = objc_getAssociatedObject(l, &kSupColors);
    objc_setAssociatedObject(l, &kSupBG, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kSupOpacity, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kSupHidden, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kSupColors, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(l, &kGlowRelated, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (bg) l.backgroundColor = bg == NSNull.null ? NULL : ((UIColor *)bg).CGColor;
    if (op) l.opacity = [op floatValue];
    if (hid) l.hidden = [hid boolValue];
    if (cols && [l isKindOfClass:CAGradientLayer.class]) ((CAGradientLayer *)l).colors = cols == NSNull.null ? nil : cols;
    [CATransaction commit];
    Class base = objc_getAssociatedObject(l, &kSupBase);
    if (base) object_setClass(l, base);
    objc_setAssociatedObject(l, &kSupBase, nil, OBJC_ASSOCIATION_ASSIGN);
    [sg_suppressed removeObject:l];
}

static UIView *ownerView(CALayer *l) {
    for (CALayer *x = l; x; x = x.superlayer) if ([x.delegate isKindOfClass:UIView.class]) return (UIView *)x.delegate;
    return nil;
}

static void releaseIn(UIView *page, BOOL glowOnly) {
    for (CALayer *l in sg_suppressed.allObjects) {
        if (glowOnly && !objc_getAssociatedObject(l, &kGlowRelated)) continue;
        UIView *owner = ownerView(l);
        if (owner && page && ![owner isDescendantOfView:page]) continue;
        release_(l);
    }
}

#pragma mark - colors

static BOOL rgba(UIColor *c, CGFloat *r, CGFloat *g, CGFloat *b, CGFloat *a) {
    if (!c) return NO;
    if ([c getRed:r green:g blue:b alpha:a]) return YES;
    CGFloat w;
    if ([c getWhite:&w alpha:a]) { *r = *g = *b = w; return YES; }
    return NO;
}

// The page's dark grays: opaque, and darker than Spotify's elevated surfaces' lightest.
static BOOL isDarkGray(UIColor *c) {
    CGFloat r, g, b, a;
    return rgba(c, &r, &g, &b, &a) && a > 0.85 && MAX(r, MAX(g, b)) < 0.3 && MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.08;
}

static BOOL isTint(UIColor *c) {
    CGFloat r, g, b, a;
    if (!rgba(c, &r, &g, &b, &a) || a < 0.3) return NO;
    CGFloat hi = MAX(r, MAX(g, b)), lo = MIN(r, MIN(g, b));
    return hi >= 0.15 && hi - lo > 0.06;
}

static UIColor *glowColor(UIColor *c) {
    CGFloat h, s, v, a;
    if (![c getHue:&h saturation:&s brightness:&v alpha:&a]) return c;
    return [UIColor colorWithHue:h saturation:MAX(s, 0.45) brightness:MAX(v, 0.8) alpha:1];
}

static UIColor *averageColor(UIImage *image) {
    if (!image) return nil;
    CIImage *input = image.CIImage ?: (image.CGImage ? [CIImage imageWithCGImage:image.CGImage] : nil);
    if (!input) return nil;
    CIFilter *avg = [CIFilter filterWithName:@"CIAreaAverage"];
    [avg setValue:input forKey:kCIInputImageKey];
    [avg setValue:[CIVector vectorWithCGRect:input.extent] forKey:kCIInputExtentKey];
    static CIContext *ctx;
    if (!ctx) ctx = [CIContext contextWithOptions:@{kCIContextWorkingColorSpace: NSNull.null}];
    if (!avg.outputImage) return nil;
    uint8_t px[4] = {0};
    [ctx render:avg.outputImage toBitmap:px rowBytes:4 bounds:CGRectMake(0, 0, 1, 1) format:kCIFormatRGBA8 colorSpace:nil];
    return [UIColor colorWithRed:px[0] / 255.0 green:px[1] / 255.0 blue:px[2] / 255.0 alpha:1];
}

static UIColor *firstTint(NSArray *cgColors) {
    if (![cgColors isKindOfClass:NSArray.class]) return nil;
    for (id cg in cgColors) {
        UIColor *c = [UIColor colorWithCGColor:(__bridge CGColorRef)cg];
        if (isTint(c)) return c;
    }
    return nil;
}

#pragma mark - the glow

// One per page, made once. It sits under the picture in the picture's container and follows it frame by frame
// through a display link that moves it only when the picture moved; every change is made with actions off,
// so nothing animates or pulses.
@interface MRGGlowView : UIView
@property (nonatomic, weak) UIView *picture;
- (void)setGlowColor:(UIColor *)color;
@end

@implementation MRGGlowView {
    CAGradientLayer *_glow;
    CAShapeLayer *_ring;
    CADisplayLink *_link;
    UIColor *_color;
    CGRect _placed;
    CGFloat _alpha;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.accessibilityElementsHidden = YES;
    self.backgroundColor = UIColor.clearColor;
    _placed = CGRectNull;
    _alpha = -1;
    _glow = [CAGradientLayer layer];
    _glow.type = kCAGradientLayerRadial;
    _glow.startPoint = CGPointMake(0.5, 0.5);
    _glow.endPoint = CGPointMake(1, 1);
    _glow.locations = @[@0, @0.42, @0.62, @1];
    _ring = [CAShapeLayer layer];
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.lineWidth = 3;
    _ring.shadowOpacity = 1;
    _ring.shadowRadius = 10;
    _ring.shadowOffset = CGSizeZero;
    // No implicit animation on anything of the glow's, ever.
    NSDictionary *none = @{@"bounds": NSNull.null, @"position": NSNull.null, @"frame": NSNull.null, @"colors": NSNull.null,
                           @"path": NSNull.null, @"strokeColor": NSNull.null, @"shadowColor": NSNull.null, @"opacity": NSNull.null,
                           @"shadowPath": NSNull.null, @"contents": NSNull.null};
    _glow.actions = none;
    _ring.actions = none;
    [self.layer addSublayer:_glow];
    [self.layer addSublayer:_ring];
    return self;
}

- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event { return (id<CAAction>)NSNull.null; }

- (void)setGlowColor:(UIColor *)color {
    if ([color isEqual:_color]) return;
    _color = color;
    UIColor *c = color ?: UIColor.whiteColor;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _glow.colors = @[(id)[c colorWithAlphaComponent:0.95].CGColor, (id)[c colorWithAlphaComponent:0.7].CGColor,
                     (id)[c colorWithAlphaComponent:0.25].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
    _ring.strokeColor = [c colorWithAlphaComponent:0.9].CGColor;
    _ring.shadowColor = c.CGColor;
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (self.window) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(follow)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [self follow];
    }
}

- (void)removeFromSuperview {
    [_link invalidate];
    _link = nil;
    [super removeFromSuperview];
}

// The picture's own fade (the header fades it out as it collapses), up to the glow's container.
static CGFloat alphaUpTo(UIView *view, UIView *stop) {
    CGFloat a = 1;
    for (UIView *v = view; v && v != stop; v = v.superview) a *= v.hidden ? 0 : v.alpha;
    return a;
}

- (void)follow {
    UIView *picture = self.picture, *host = self.superview;
    if (!picture.window || !host) return;
    CGRect p = [host convertRect:picture.bounds fromView:picture];
    CGFloat alpha = alphaUpTo(picture, host);
    BOOL moved = !CGRectEqualToRect(p, _placed);
    if (!moved && fabs(alpha - _alpha) < 0.01) return;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    if (moved) {
        _placed = p;
        CGFloat side = MAX(p.size.width, p.size.height);
        CGRect frame = CGRectInset(p, -side * 0.5, -side * 0.5);
        [UIView performWithoutAnimation:^{ self.frame = frame; }];
        _glow.frame = self.bounds;
        _ring.frame = self.bounds;
        _ring.path = [UIBezierPath bezierPathWithOvalInRect:CGRectInset(CGRectMake(side * 0.5, side * 0.5, p.size.width, p.size.height), -3, -3)].CGPath;
    }
    if (fabs(alpha - _alpha) >= 0.01) {
        _alpha = alpha;
        [UIView performWithoutAnimation:^{ self.alpha = alpha; }];
    }
    [CATransaction commit];
}

- (void)dealloc { [_link invalidate]; }

@end

#pragma mark - page

@interface MRGWeakBox : NSObject
@property (nonatomic, weak) id object;
@end
@implementation MRGWeakBox
@end

static char kProfileKey, kGlowKey, kPictureKey, kColorKey, kColorImageKey, kLastStyleKey, kEpochKey;
static NSUInteger sg_settingsEpoch;

static BOOL overMirageBackground(UIView *page) {
    if (!MRGBackgroundEnabled() || MRGCurrentKind() == MRGMediaNone) return NO;
    for (UIView *v = page; v; v = v.superview) {
        UIView *first = v.subviews.firstObject;
        if ([first isKindOfClass:MRGBackgroundView.class] && !first.hidden) return YES;
    }
    return NO;
}

static void removeGlow(UIView *page) {
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    [glow removeFromSuperview];
    objc_setAssociatedObject(page, &kGlowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL isHeaderController(UIResponder *r) {
    NSString *name = NSStringFromClass(r.class);
    return [name containsString:@"EntityHeaderViewController"] || [name containsString:@"ProfileHeaderViewController"];
}

static UIView *headerIn(UIView *page) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:page.subviews];
    for (NSUInteger i = 0; i < queue.count && i < 1500; i++) {
        UIView *v = queue[i];
        if ([v isKindOfClass:UICollectionViewCell.class]) continue;
        if ([v.nextResponder isKindOfClass:UIViewController.class] && isHeaderController(v.nextResponder)) return v;
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

static BOOL isRoundPicture(UIView *v) {
    if (![v isKindOfClass:UIImageView.class] || !((UIImageView *)v).image) return NO;
    CGSize s = v.bounds.size;
    CGFloat radius = MAX(v.layer.cornerRadius, v.superview.layer.cornerRadius);
    BOOL round = radius >= s.width * 0.4 || v.layer.mask || v.superview.layer.mask;
    return fabs(s.width - s.height) < 2 && s.width >= 56 && s.width <= 240 && round;
}

static void styleProfile(UIView *page) {
    if (!page.window) return;
    if (!overMirageBackground(page)) { releaseIn(page, NO); removeGlow(page); return; }
    objc_setAssociatedObject(page, &kProfileKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL glowOn = MRGProfileGlow();
    if (!glowOn) { releaseIn(page, YES); removeGlow(page); }

    CGSize P = page.bounds.size;
    UIView *header = headerIn(page);
    UIImageView *picture = ((MRGWeakBox *)objc_getAssociatedObject(page, &kPictureKey)).object;
    if (picture && (!picture.window || ![picture isDescendantOfView:page])) picture = nil;
    BOOL findPicture = glowOn && !picture;
    UIColor *tint = objc_getAssociatedObject(page, &kColorKey);

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:page.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 3000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGBackgroundView.class] || [v isKindOfClass:MRGGlowView.class] ||
            [v isKindOfClass:UIVisualEffectView.class]) continue;
        // Cells are Mirage's list clearing's (MRGBackgrounds.x); nothing of the header lives in one.
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) continue;
        CGRect f = [page convertRect:v.bounds fromView:v];
        BOOL wide = f.size.width >= P.width * 0.9;
        BOOL list = [v isKindOfClass:UIScrollView.class];
        BOOL inHeader = header && (v == header || [v isDescendantOfView:header]);
        // Across the top of the page: the header at rest and the collapsed bar that shows on scroll.
        BOOL topBar = wide && !list && CGRectGetMinY(f) < P.height * 0.25 && f.size.height <= 200;

        // The dark gray bands, from "Playlists" down and under the header: page-wide fills and section headers.
        if (!list && (wide || [v isKindOfClass:UICollectionReusableView.class]) && isDarkGray(v.backgroundColor) && !inHeader && !topBar)
            suppressBG(v.layer, NO);
        if (list && isDarkGray(v.backgroundColor)) suppressBG(v.layer, NO);

        if (glowOn && (inHeader || topBar) && wide && !list) {
            CALayer *layer = v.layer;
            BOOL gradientLayer = [layer isKindOfClass:CAGradientLayer.class];
            if (gradientLayer) tint = tint ?: firstTint(objc_getAssociatedObject(layer, &kSupColors) ?: ((CAGradientLayer *)layer).colors);
            if (isTint(v.backgroundColor)) tint = tint ?: v.backgroundColor;
            if ((gradientLayer || [NSStringFromClass(v.class) containsString:@"Gradient"]) && !v.subviews.count) {
                suppressOpacity(layer);
                continue;
            }
            if (gradientLayer) suppressColors((CAGradientLayer *)layer);
            // Taken over before Spotify paints it, so the collapsed bar's fill never shows.
            suppressBG(layer, YES);
            for (CALayer *sub in layer.sublayers) {
                if (![sub isKindOfClass:CAGradientLayer.class] || sub.bounds.size.width < P.width * 0.9) continue;
                tint = tint ?: firstTint(((CAGradientLayer *)sub).colors);
                suppressHidden(sub);
            }
        }
        if (findPicture && (inHeader || CGRectGetMinY(f) < P.height * 0.5) && isRoundPicture(v) &&
            v.bounds.size.width > picture.bounds.size.width) picture = (UIImageView *)v;
        [stack addObjectsFromArray:v.subviews];
    }

    if (!glowOn || !picture) { if (!picture) removeGlow(page); return; }
    MRGWeakBox *box = [MRGWeakBox new];
    box.object = picture;
    objc_setAssociatedObject(page, &kPictureKey, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // The color, once per picture: Spotify's own from the header, or the picture's average.
    if (objc_getAssociatedObject(page, &kColorImageKey) != picture.image || !tint) {
        if (!tint) tint = averageColor(picture.image);
        objc_setAssociatedObject(page, &kColorImageKey, picture.image, OBJC_ASSOCIATION_ASSIGN);
    }
    if (tint) objc_setAssociatedObject(page, &kColorKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

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
    glow.picture = picture;
    [glow setGlowColor:glowColor(tint ?: UIColor.whiteColor)];
    if (glow.superview != container) [container insertSubview:glow belowSubview:below];
    else {
        NSUInteger gi = [container.subviews indexOfObject:glow], bi = [container.subviews indexOfObject:below];
        if (bi != NSNotFound && gi > bi) [container insertSubview:glow belowSubview:below];
    }
}

// Full passes at most four times a second; the setters keep everything in place between them and the glow
// follows the picture on its own.
static void profileLaidOut(UIView *page, CFTimeInterval interval) {
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(page, &kLastStyleKey);
    BOOL sameSettings = [objc_getAssociatedObject(page, &kEpochKey) unsignedIntegerValue] == sg_settingsEpoch;
    if (sameSettings && last && now - last.doubleValue < interval) return;
    objc_setAssociatedObject(page, &kEpochKey, @(sg_settingsEpoch), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(page, &kLastStyleKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    styleProfile(page);
}

static UIView *profilePageAbove(UIView *view) {
    for (UIView *v = view; v; v = v.superview) if (objc_getAssociatedObject(v, &kProfileKey)) return v;
    return nil;
}

%group MRGProfile
%hook _TtC18Profile_CommonImpl21ProfileViewController
- (void)viewDidLayoutSubviews { %orig; profileLaidOut(((UIViewController *)self).view, 0.25); }
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *page = ((UIViewController *)self).view;
    profileLaidOut(page, 0);
    // The header fills in after the page appears (the picture and its color load).
    __weak UIView *weakPage = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakPage) profileLaidOut(weakPage, 0);
    });
}
%end

// The header reports every scroll frame here; a view Spotify adds at the collapse threshold is caught by the
// next pass, a quarter second at most.
%hook SPTEntityHeaderViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (page) profileLaidOut(page, 0.25);
}
- (void)parentScrollViewDidChangeContentOffset {
    %orig;
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (page) profileLaidOut(page, 0.25);
}
%end
%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"_TtC18Profile_CommonImpl21ProfileViewController")) return;
        if (!NSClassFromString(@"SPTEntityHeaderViewController")) return;
        %init(MRGProfile);
        // A settings change lays every page out again (MRGBackgrounds.x relayoutAll); the next pass on a
        // profile page is then a full one, so the toggle takes effect at once.
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            sg_settingsEpoch++;
        }];
    }
}
