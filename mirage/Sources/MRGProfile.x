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
#import "MRGClearing.h"
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
- (void)setGlowColor:(UIColor *)color animated:(BOOL)animated;
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

- (void)setGlowColor:(UIColor *)color { [self setGlowColor:color animated:NO]; }

// A placeholder first, then the real color crossfading in over 0.2s; the only animation the glow ever runs,
// and an explicit one.
- (void)setGlowColor:(UIColor *)color animated:(BOOL)animated {
    if ([color isEqual:_color]) return;
    BOOL fade = animated && _color != nil;
    NSArray *oldColors = _glow.colors;
    id oldStroke = (__bridge id)_ring.strokeColor, oldShadow = (__bridge id)_ring.shadowColor;
    _color = color;
    UIColor *c = color ?: UIColor.whiteColor;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _glow.colors = @[(id)[c colorWithAlphaComponent:0.95].CGColor, (id)[c colorWithAlphaComponent:0.7].CGColor,
                     (id)[c colorWithAlphaComponent:0.25].CGColor, (id)[c colorWithAlphaComponent:0].CGColor];
    _ring.strokeColor = [c colorWithAlphaComponent:0.9].CGColor;
    _ring.shadowColor = c.CGColor;
    [CATransaction commit];
    if (!fade) return;
    void (^crossfade)(CALayer *, NSString *, id, id) = ^(CALayer *layer, NSString *key, id from, id to) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:key];
        a.fromValue = from;
        a.toValue = to;
        a.duration = 0.2;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [layer addAnimation:a forKey:[@"mrg." stringByAppendingString:key]];
    };
    crossfade(_glow, @"colors", oldColors, _glow.colors);
    crossfade(_ring, @"strokeColor", oldStroke, (__bridge id)_ring.strokeColor);
    crossfade(_ring, @"shadowColor", oldShadow, (__bridge id)_ring.shadowColor);
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
+ (instancetype)with:(id)object { MRGWeakBox *b = [self new]; b.object = object; return b; }
@end

static char kProfileKey, kGlowKey, kPictureKey, kColorKey, kImageColorKey, kHeaderKey, kHeaderPageKey, kLastPassKey, kLastHeaderKey,
            kEpochKey, kPictureOfKey;
static NSUInteger sg_settingsEpoch;
// The header roots of the profile pages being styled; the paint hooks below look only inside these.
static NSHashTable<UIView *> *sg_headers;

static id weakGet(id owner, const void *key) { return ((MRGWeakBox *)objc_getAssociatedObject(owner, key)).object; }
static void weakSet(id owner, const void *key, id object) {
    objc_setAssociatedObject(owner, key, object ? [MRGWeakBox with:object] : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL overMirageBackground(UIView *page) {
    for (UIView *v = page; v; v = v.superview) {
        UIView *first = v.subviews.firstObject;
        if ([first isKindOfClass:MRGBackgroundView.class] && !first.hidden) return YES;
    }
    return NO;
}

// Whether the page is, or is about to be, over a Mirage background. In viewWillAppear the page host has
// not put its background in yet (it does so after its children's appearance calls), so being a page in a
// page host with Everywhere on counts as well: the takeover then happens before the first frame.
static BOOL profileWanted(UIView *page) {
    if (!MRGBackgroundEnabled() || MRGCurrentKind() == MRGMediaNone) return NO;
    if (overMirageBackground(page)) return YES;
    if (!MRGWantsScreen(MRGScreenEverywhere)) return NO;
    UIResponder *r = page.nextResponder;
    UIViewController *vc = [r isKindOfClass:UIViewController.class] ? (UIViewController *)r : nil;
    for (UIViewController *p = vc; p; p = p.parentViewController)
        if ([NSStringFromClass(p.class) containsString:@"MusicAppPageHostingViewController"]) return YES;
    return NO;
}

static void removeGlow(UIView *page) {
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    [glow removeFromSuperview];
    objc_setAssociatedObject(page, &kGlowKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void forgetHeader(UIView *page) {
    UIView *header = weakGet(page, &kHeaderKey);
    if (header) [sg_headers removeObject:header];
}

static void releasePage(UIView *page, BOOL glowOnly) {
    releaseIn(page, glowOnly);
    removeGlow(page);
    if (!glowOnly) forgetHeader(page);
}

static BOOL isHeaderController(UIResponder *r) {
    NSString *name = NSStringFromClass(r.class);
    return [name containsString:@"EntityHeaderViewController"] || [name containsString:@"ProfileHeaderViewController"];
}

static UIView *findHeader(UIView *page) {
    UIView *known = weakGet(page, &kHeaderKey);
    if (known && [known isDescendantOfView:page]) return known;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithArray:page.subviews];
    for (NSUInteger i = 0; i < queue.count && i < 1500; i++) {
        UIView *v = queue[i];
        if ([v isKindOfClass:UICollectionViewCell.class] || [v isKindOfClass:UITableViewCell.class]) continue;
        if ([v.nextResponder isKindOfClass:UIViewController.class] && isHeaderController(v.nextResponder)) {
            weakSet(page, &kHeaderKey, v);
            weakSet(v, &kHeaderPageKey, page);
            if (!sg_headers) sg_headers = [NSHashTable weakObjectsHashTable];
            [sg_headers addObject:v];
            return v;
        }
        [queue addObjectsFromArray:v.subviews];
    }
    return nil;
}

// Round and square, about an avatar's size; the image may not be in yet (the glow comes up without it).
static BOOL isRoundPicture(UIView *v) {
    if (![v isKindOfClass:UIImageView.class]) return NO;
    CGSize s = v.bounds.size;
    CGFloat radius = MAX(v.layer.cornerRadius, v.superview.layer.cornerRadius);
    BOOL round = radius >= s.width * 0.4 || v.layer.mask || v.superview.layer.mask || v.superview.layer.cornerRadius >= s.width * 0.4;
    return fabs(s.width - s.height) < 2 && s.width >= 56 && s.width <= 240 && round;
}

#pragma mark - color and glow

static UIColor *pageColor(UIView *page) {
    // Spotify's own color first, then the picture's average; the placeholder until either is known.
    return objc_getAssociatedObject(page, &kColorKey) ?: objc_getAssociatedObject(page, &kImageColorKey);
}

static void updateGlowColor(UIView *page) {
    MRGGlowView *glow = objc_getAssociatedObject(page, &kGlowKey);
    if (!glow) return;
    UIColor *c = pageColor(page);
    // The neutral placeholder: a soft white, so the glow is there from the first frame.
    [glow setGlowColor:c ? glowColor(c) : [UIColor colorWithWhite:0.85 alpha:1] animated:YES];
}

static void noteSpotifyColor(UIView *page, NSArray *cgColors, UIColor *fill) {
    if (objc_getAssociatedObject(page, &kColorKey)) return;
    UIColor *c = firstTint(cgColors) ?: (isTint(fill) ? fill : nil);
    if (!c) return;
    objc_setAssociatedObject(page, &kColorKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    updateGlowColor(page);
}

static void noteImageColor(UIView *page, UIImage *image) {
    if (!image) return;
    UIColor *c = averageColor(image);
    if (!c) return;
    objc_setAssociatedObject(page, &kImageColorKey, c, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    updateGlowColor(page);
}

// Made the first time the picture is found, which is the header's first layout pass: in the picture's
// container, under the picture, higher up past containers that clip and are too small. Never made again.
static void ensureGlow(UIView *page, UIImageView *picture) {
    UIImageView *known = weakGet(page, &kPictureKey);
    if (known != picture) {
        weakSet(page, &kPictureKey, picture);
        weakSet(picture, &kPictureOfKey, page);
        objc_setAssociatedObject(page, &kImageColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (picture.image) noteImageColor(page, picture.image);
    }
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
        UIColor *c = pageColor(page);
        [glow setGlowColor:c ? glowColor(c) : [UIColor colorWithWhite:0.85 alpha:1] animated:NO];
    }
    glow.picture = picture;
    if (glow.superview != container) [container insertSubview:glow belowSubview:below];
    else {
        NSUInteger gi = [container.subviews indexOfObject:glow], bi = [container.subviews indexOfObject:below];
        if (bi != NSNotFound && gi > bi) [container insertSubview:glow belowSubview:below];
    }
    [glow follow];
}

#pragma mark - passes

// The header alone (a few dozen views), on every one of its layout passes and as the page is about to
// appear, so the page-wide color is taken over before the first frame Spotify paints it in. Views not laid
// out yet (width 0) count as wide for gradients, which are the header's color; fills wait for a width, so a
// button's fill is never taken.
static void headerPass(UIView *page) {
    if (!MRGProfileGlow()) return;
    UIView *header = findHeader(page);
    if (!header) return;
    CGFloat W = page.bounds.size.width ?: UIScreen.mainScreen.bounds.size.width;
    UIImageView *picture = weakGet(page, &kPictureKey);
    if (picture && ![picture isDescendantOfView:header]) picture = nil;
    UIImageView *found = nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:header];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 800) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGGlowView.class] || [v isKindOfClass:UIVisualEffectView.class]) continue;
        CGFloat w = v.bounds.size.width;
        BOOL unsized = w < 1;
        BOOL wide = w >= W * 0.9;
        CALayer *layer = v.layer;
        BOOL gradientLayer = [layer isKindOfClass:CAGradientLayer.class];
        BOOL gradientView = gradientLayer || [NSStringFromClass(v.class) containsString:@"Gradient"];
        if (gradientLayer) noteSpotifyColor(page, objc_getAssociatedObject(layer, &kSupColors) ?: ((CAGradientLayer *)layer).colors, nil);
        if (gradientView && (wide || unsized) && !v.subviews.count) {
            suppressOpacity(layer);
            continue;
        }
        if (gradientLayer && (wide || unsized)) suppressColors((CAGradientLayer *)layer);
        if (wide) {
            noteSpotifyColor(page, nil, v.backgroundColor);
            suppressBG(layer, YES);
        }
        for (CALayer *sub in layer.sublayers) {
            if (![sub isKindOfClass:CAGradientLayer.class]) continue;
            if (sub.bounds.size.width >= 1 && sub.bounds.size.width < W * 0.6) continue;
            noteSpotifyColor(page, ((CAGradientLayer *)sub).colors, nil);
            suppressHidden(sub);
        }
        if (!picture && isRoundPicture(v) && v.bounds.size.width > found.bounds.size.width) found = (UIImageView *)v;
        [stack addObjectsFromArray:v.subviews];
    }
    picture = picture ?: found;
    if (picture) ensureGlow(page, picture);
}

static BOOL isDarkish(UIColor *c) {
    CGFloat r, g, b, a;
    return rgba(c, &r, &g, &b, &a) && a > 0.5 && MAX(r, MAX(g, b)) < 0.3 && MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.08;
}

// The rest of the page, at most four times a second and on appear: the collapsed bar across the top, and the
// dark bands. The sections are cells of the page's list; the Playlists one holds its own list of rows (a
// table: Profile_CommonImpl.ProfileListView) and, like the rows and its header, paints black, pure #000
// included, on the view or on a plain layer of its own, so cells are walked into: every page-wide dark fill
// in them is cleared and kept clear, nested lists are adopted, and plain dark layers as wide are taken over.
static void pagePass(UIView *page) {
    CGSize P = page.bounds.size;
    if (P.width < 1) return;
    BOOL glowOn = MRGProfileGlow();
    UIView *header = findHeader(page);
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithArray:page.subviews];
    NSUInteger seen = 0;
    while (stack.count && seen++ < 4000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:MRGBackgroundView.class] || [v isKindOfClass:MRGGlowView.class] ||
            [v isKindOfClass:UIVisualEffectView.class] || [v isKindOfClass:UIImageView.class]) continue;
        if (header && v == header) continue;   // headerPass's
        CGRect f = [page convertRect:v.bounds fromView:v];
        BOOL wide = f.size.width >= P.width * 0.85;
        BOOL list = [v isKindOfClass:UIScrollView.class];

        if (list && v != page && ([v isKindOfClass:UITableView.class] || [v isKindOfClass:UICollectionView.class]) && wide)
            MRGAdoptList((UIScrollView *)v);
        else if (wide || [v isKindOfClass:UICollectionReusableView.class] || [v isKindOfClass:UITableViewHeaderFooterView.class]) {
            if (isDarkish(v.backgroundColor)) MRGClearDarkPersistently(v);
        }
        // Plain layers (no view of their own) that paint a section's black.
        if (wide) {
            for (CALayer *sub in v.layer.sublayers) {
                if (sub.delegate || sub.bounds.size.width < P.width * 0.85) continue;
                CGColorRef bg = sub.backgroundColor;
                if (bg && isDarkish([UIColor colorWithCGColor:bg])) suppressBG(sub, NO);
            }
        }
        // The collapsed bar across the top of the page (outside the header).
        if (glowOn && wide && !list && CGRectGetMinY(f) < P.height * 0.25 && f.size.height <= 200 &&
            ![v isKindOfClass:UITableViewCell.class] && ![v isKindOfClass:UICollectionReusableView.class]) {
            noteSpotifyColor(page, [v.layer isKindOfClass:CAGradientLayer.class] ? ((CAGradientLayer *)v.layer).colors : nil, v.backgroundColor);
            suppressBG(v.layer, YES);
            if ([v.layer isKindOfClass:CAGradientLayer.class]) suppressColors((CAGradientLayer *)v.layer);
        }
        [stack addObjectsFromArray:v.subviews];
    }
}

static void stylePage(UIView *page, BOOL full, CFTimeInterval interval) {
    if (!profileWanted(page)) { releasePage(page, NO); return; }
    objc_setAssociatedObject(page, &kProfileKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL sameSettings = [objc_getAssociatedObject(page, &kEpochKey) unsignedIntegerValue] == sg_settingsEpoch;
    if (!sameSettings) {
        objc_setAssociatedObject(page, &kEpochKey, @(sg_settingsEpoch), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!MRGProfileGlow()) releasePage(page, YES);
        full = YES;
        interval = 0;
    }
    headerPass(page);
    if (!full) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(page, &kLastPassKey);
    if (last && now - last.doubleValue < interval) return;
    objc_setAssociatedObject(page, &kLastPassKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    pagePass(page);
}

static UIView *profilePageAbove(UIView *view) {
    for (UIView *v = view; v; v = v.superview) if (objc_getAssociatedObject(v, &kProfileKey)) return v;
    return nil;
}

// The page a layer paints in, if the layer is in one of the profile headers being styled.
static UIView *headerPageOf(CALayer *layer) {
    if (!sg_headers.count || !NSThread.isMainThread) return nil;
    UIView *view = ownerView(layer);
    for (int i = 0; view && i < 14; i++, view = view.superview)
        if ([sg_headers containsObject:view]) return weakGet(view, &kHeaderPageKey);
    return nil;
}

%group MRGProfile
%hook _TtC18Profile_CommonImpl21ProfileViewController
- (void)viewWillAppear:(BOOL)animated { %orig; stylePage(((UIViewController *)self).view, YES, 0); }
- (void)viewDidLayoutSubviews { %orig; stylePage(((UIViewController *)self).view, YES, 0.25); }
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    UIView *page = ((UIViewController *)self).view;
    stylePage(page, YES, 0);
    __weak UIView *weakPage = page;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakPage) stylePage(weakPage, YES, 0);
    });
}
%end

// The header's own passes: its first layout comes before its first frame.
%hook SPTEntityHeaderViewController
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (page) stylePage(page, NO, 0);
}
- (void)viewDidLayoutSubviews {
    %orig;
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (page) stylePage(page, YES, 0.25);
}
- (void)parentScrollViewDidChangeContentOffset {
    %orig;
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (!page) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSNumber *last = objc_getAssociatedObject(page, &kLastHeaderKey);
    if (last && now - last.doubleValue < 0.1) return;
    objc_setAssociatedObject(page, &kLastHeaderKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    stylePage(page, YES, 0.25);
}
%end

%hook _TtC18Profile_CommonImpl27ProfileHeaderViewController
- (void)viewDidLoad {
    %orig;
    // The header's view exists from here; the page may already be known.
    UIView *page = profilePageAbove(((UIViewController *)self).view.superview);
    if (page) stylePage(page, NO, 0);
}
%end

// Paint that arrives between passes, inside a styled header: a gradient's colors (the header's color loading
// in) and page-wide fills are taken over as they are set, so they never reach the screen.
%hook CAGradientLayer
- (void)setColors:(NSArray *)colors {
    UIView *page = colors.count && MRGProfileGlow() ? headerPageOf(self) : nil;
    if (page && !isSuppressing(self, &kSupColors)) {
        CGFloat W = page.bounds.size.width;
        if (self.bounds.size.width < 1 || self.bounds.size.width >= W * 0.6) {
            noteSpotifyColor(page, colors, nil);
            if (adopt(self)) {
                objc_setAssociatedObject(self, &kSupColors, colors, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                objc_setAssociatedObject(self, &kGlowRelated, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                colors = nil;
            }
        }
    }
    %orig(colors);
}
%end
%end

// The picture's image arriving: its color is read right then, not on a later pass.
%group MRGProfileImage
%hook UIImageView
- (void)setImage:(UIImage *)image {
    %orig;
    if (!sg_headers.count) return;
    UIView *page = weakGet(self, &kPictureOfKey);
    if (page && image) noteImageColor(page, image);
}
%end
%end

%ctor {
    @autoreleasepool {
        if (!NSClassFromString(@"_TtC18Profile_CommonImpl21ProfileViewController")) return;
        if (!NSClassFromString(@"SPTEntityHeaderViewController")) return;
        if (!NSClassFromString(@"_TtC18Profile_CommonImpl27ProfileHeaderViewController")) return;
        %init(MRGProfile);
        %init(MRGProfileImage);
        // A settings change lays every page out again (MRGBackgrounds.x relayoutAll); the next pass on a
        // profile page is then a full one, so the toggle takes effect at once.
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
            sg_settingsEpoch++;
        }];
    }
}
