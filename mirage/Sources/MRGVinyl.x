// Add-on "Vinyl" (Now Playing): the player's cover becomes a record sleeve. The cover shrinks and slides to one side,
// and a vinyl record peeks out from behind it on the other, spinning while a song plays and standing still when it's
// paused. The record is drawn in code (grooves, a rim, a light that stays put while the disc turns, a center hole) and
// its label is the album art.
//
// Spotify's tree (from Vitrine's notes): CoverArtCellImpl > UIView > UIView > CoverArtTiltView (≥200pt in the player,
// 40pt in the bar) > the cover (an ElementView the tilt view's size; Vitrine scales it down while paused).
//
// 0.5.2: the record lives inside the tilt view, below the cover, so it moves, fades and animates with the cover in
// every transition (opening and closing the player, the swipe between songs, pulling the player down). The tilt view's
// own scale and shift carry it too. When the cover itself is scaled (Vitrine's paused shrink), the record copies that
// transform about the cover's center and the very same animation, every frame it changes, so it never lags and jumps.
// 0.5.1 kept the tilt view in an unretained reference on the cell; a tilt view Spotify rebuilt left it pointing at
// freed memory, and the next pass crashed. Nothing here holds a Spotify view strongly or unretained: the record is
// stored on the tilt view itself and holds it weakly.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"

static const CGFloat kCoverScale = 0.70;   // the sleeve, of the tilt view's size
static const CGFloat kPeek = 0.42;          // how much record shows past the sleeve, of the sleeve's width
static const CGFloat kDisc = 0.92;          // the record's diameter, of the sleeve's width
static char kVinylKey, kOursKey, kClipKey;
static CFTimeInterval sg_glideUntil;   // right after the add-on or its side changed: the cover glides, else it is set

static Class tiltClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"); });
    return c;
}
static Class cellClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl"); });
    return c;
}

static UIView *findTilt(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    Class c = tiltClass();
    if (c && [v isKindOfClass:c] && v.bounds.size.width >= 200) return v;
    for (UIView *s in v.subviews) { UIView *t = findTilt(s, depth + 1); if (t) return t; }
    return nil;
}

static BOOL inPlayerCell(UIView *v) {
    Class c = cellClass();
    for (UIView *p = v.superview; p && c; p = p.superview) if ([p isKindOfClass:c]) return YES;
    return NO;
}

// The biggest image showing inside the cover.
static UIImage *coverImage(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    if ([v isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)v).image;
        if (img.size.width >= 60) return img;
    }
    for (UIView *s in v.subviews) { UIImage *i = coverImage(s, depth + 1); if (i) return i; }
    return nil;
}

static void logState(NSString *state) {
    static NSString *last;
    if ([state isEqualToString:last]) return;
    last = [state copy];
    MRGDJLog(@"vinyl: %@", state);
}

#pragma mark - the record

@interface MRGVinylView : UIView
@property (nonatomic, weak) UIView *tilt;
@property (nonatomic) CGFloat dir;   // 1: record on the right
@end

@interface MRGVinylProxy : NSObject
@property (nonatomic, weak) MRGVinylView *owner;
@end

@implementation MRGVinylView {
    CALayer *_disc;             // turns
    CAGradientLayer *_base;
    CAShapeLayer *_grooves, *_rings, *_rim;
    CALayer *_label;
    CAShapeLayer *_labelRing, *_hole;
    CAGradientLayer *_sheen;    // stays still: the light on the record
    CAShapeLayer *_sheenMask;
    CADisplayLink *_link;
    NSUInteger _frames;
    __weak UIImage *_shownImage;
    NSString *_shownURL;
    double _turn;
    BOOL _spinning, _built, _followed;
    CGFloat _builtSide;
    CGAffineTransform _lastCover;
    CGPoint _lastCenter;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.5;
    self.layer.shadowRadius = 16;
    self.layer.shadowOffset = CGSizeMake(0, 8);
    _lastCover = CGAffineTransformIdentity;
    _disc = [CALayer layer];
    _base = [CAGradientLayer layer];
    _base.type = kCAGradientLayerRadial;
    _base.colors = @[(id)[UIColor colorWithWhite:0.20 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.09 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.04 alpha:1].CGColor];
    _base.locations = @[@0, @0.6, @1];
    _base.startPoint = CGPointMake(0.5, 0.5);
    _base.endPoint = CGPointMake(1, 1);
    _grooves = [CAShapeLayer layer];
    _grooves.fillColor = nil;
    _grooves.strokeColor = [UIColor colorWithWhite:1 alpha:0.07].CGColor;
    _grooves.lineWidth = 0.6;
    _rings = [CAShapeLayer layer];
    _rings.fillColor = nil;
    _rings.strokeColor = [UIColor colorWithWhite:0 alpha:0.85].CGColor;
    _rim = [CAShapeLayer layer];
    _rim.fillColor = nil;
    _rim.strokeColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
    _rim.lineWidth = 1.5;
    _label = [CALayer layer];
    _label.masksToBounds = YES;
    _label.contentsGravity = kCAGravityResizeAspectFill;
    _label.backgroundColor = MRGAccent().CGColor;
    _labelRing = [CAShapeLayer layer];
    _labelRing.fillColor = nil;
    _labelRing.strokeColor = [UIColor colorWithWhite:0 alpha:0.55].CGColor;
    _labelRing.lineWidth = 2;
    _hole = [CAShapeLayer layer];
    _hole.fillColor = [UIColor colorWithWhite:0.03 alpha:1].CGColor;
    _hole.strokeColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
    _hole.lineWidth = 0.75;
    for (CALayer *l in @[_base, _grooves, _rings, _rim, _label, _labelRing, _hole]) [_disc addSublayer:l];
    [self.layer addSublayer:_disc];
    _sheen = [CAGradientLayer layer];
    _sheen.type = kCAGradientLayerConic;
    _sheen.startPoint = CGPointMake(0.5, 0.5);
    _sheen.endPoint = CGPointMake(0.5, 0);
    UIColor *clear = [UIColor colorWithWhite:1 alpha:0], *lit = [UIColor colorWithWhite:1 alpha:0.20], *soft = [UIColor colorWithWhite:1 alpha:0.09];
    _sheen.colors = @[(id)clear.CGColor, (id)lit.CGColor, (id)clear.CGColor, (id)clear.CGColor, (id)soft.CGColor, (id)clear.CGColor, (id)clear.CGColor];
    _sheen.locations = @[@0, @0.08, @0.18, @0.5, @0.58, @0.68, @1];
    _sheenMask = [CAShapeLayer layer];
    _sheenMask.fillRule = kCAFillRuleEvenOdd;
    _sheen.mask = _sheenMask;
    [self.layer addSublayer:_sheen];
    _turn = MRGVinylSecondsPerTurn();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:MRGSettingsChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged) name:MRGPlayerTrackChangedNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_link invalidate]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    if (side < 10 || (_built && fabs(side - _builtSide) < 0.5)) return;
    _built = YES;
    _builtSide = side;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGRect sq = CGRectMake((b.size.width - side) / 2, (b.size.height - side) / 2, side, side);
    // The disc turns around its own center: bounds and position, not a frame, so a spin in flight is never moved.
    _disc.bounds = (CGRect){CGPointZero, sq.size};
    _disc.position = CGPointMake(CGRectGetMidX(sq), CGRectGetMidY(sq));
    CGRect d = _disc.bounds;
    CGPoint mid = CGPointMake(side / 2, side / 2);
    CGFloat R = side / 2;
    _base.frame = d;
    _base.cornerRadius = R;
    _base.masksToBounds = YES;
    UIBezierPath *g = [UIBezierPath bezierPath];
    for (CGFloat r = R * 0.42; r < R * 0.95; r += MAX(1.2, R / 48)) [g appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _grooves.frame = d;
    _grooves.path = g.CGPath;
    UIBezierPath *rings = [UIBezierPath bezierPath];   // the quiet gaps between tracks
    for (NSNumber *f in @[@0.55, @0.68, @0.82]) [rings appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:R * f.doubleValue startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _rings.frame = d;
    _rings.path = rings.CGPath;
    _rings.lineWidth = MAX(1, R / 80);
    _rim.frame = d;
    _rim.path = [UIBezierPath bezierPathWithArcCenter:mid radius:R - 1 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    CGFloat l = side * 0.38;
    _label.frame = CGRectMake(mid.x - l / 2, mid.y - l / 2, l, l);
    _label.cornerRadius = l / 2;
    _labelRing.frame = d;
    _labelRing.path = [UIBezierPath bezierPathWithArcCenter:mid radius:l / 2 startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    CGFloat h = MAX(3, side * 0.02);
    _hole.frame = d;
    _hole.path = [UIBezierPath bezierPathWithArcCenter:mid radius:h startAngle:0 endAngle:2 * M_PI clockwise:YES].CGPath;
    _sheen.frame = sq;
    UIBezierPath *m = [UIBezierPath bezierPathWithOvalInRect:(CGRect){CGPointZero, sq.size}];
    [m appendPath:[UIBezierPath bezierPathWithOvalInRect:CGRectInset((CGRect){CGPointZero, sq.size}, (side - l) / 2, (side - l) / 2)]];
    _sheenMask.frame = _sheen.bounds;
    _sheenMask.path = m.CGPath;
    self.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:sq].CGPath;
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (!self.window) return;
    MRGVinylProxy *p = [MRGVinylProxy new];
    p.owner = self;
    _link = [CADisplayLink displayLinkWithTarget:p selector:@selector(frame:)];
    if ([_link respondsToSelector:@selector(setPreferredFramesPerSecond:)]) _link.preferredFramesPerSecond = 60;
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self startSpin];
    [self slowTick];
}

- (void)startSpin {
    [_disc removeAnimationForKey:@"spin"];
    _disc.speed = 1;
    _disc.timeOffset = 0;
    _disc.beginTime = 0;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
    a.fromValue = @0;
    a.toValue = @(2 * M_PI);
    a.duration = _turn;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_disc addAnimation:a forKey:@"spin"];
    _spinning = YES;
}

// Apple's pause and resume of a layer's animations: stopping keeps the record where it was.
- (void)setSpinning:(BOOL)on {
    if (on == _spinning) return;
    _spinning = on;
    if (!on) {
        CFTimeInterval t = [_disc convertTime:CACurrentMediaTime() fromLayer:nil];
        _disc.speed = 0;
        _disc.timeOffset = t;
    } else {
        CFTimeInterval paused = _disc.timeOffset;
        _disc.speed = 1;
        _disc.timeOffset = 0;
        _disc.beginTime = 0;
        _disc.beginTime = [_disc convertTime:CACurrentMediaTime() fromLayer:nil] - paused;
    }
}

- (void)settingsChanged {
    double turn = MRGVinylSecondsPerTurn();
    if (fabs(turn - _turn) > 0.01) {
        _turn = turn;
        BOOL was = _spinning;
        [self startSpin];
        if (!was) [self setSpinning:NO];
    }
    [self.tilt setNeedsLayout];
}

- (void)trackChanged {
    _shownImage = nil;   // the next tick reads the new cover
    _shownURL = nil;
    [self.tilt setNeedsLayout];
}

// The cover inside the tilt view: its biggest visible subview other than the record.
static UIView *coverIn(UIView *tilt) {
    UIView *best = nil;
    CGFloat side = MIN(tilt.bounds.size.width, tilt.bounds.size.height), bestArea = 0;
    for (UIView *s in tilt.subviews) {
        if ([s isKindOfClass:MRGVinylView.class] || s.hidden) continue;
        CGSize z = s.bounds.size;
        if (z.width < side * 0.8 || z.height < side * 0.8) continue;
        if (z.width * z.height > bestArea) { bestArea = z.width * z.height; best = s; }
    }
    return best;
}

// The cover's transform, applied about the cover's center: the record shrinks toward the same point and stays tucked
// behind it. Linear part the same; translation so that cc + A(p - cc) = vc + M(p - vc).
static CGAffineTransform followTransform(CGAffineTransform A, CGPoint cc, CGPoint vc) {
    CGFloat dx = vc.x - cc.x, dy = vc.y - cc.y;
    CGFloat ax = A.a * dx + A.c * dy, ay = A.b * dx + A.d * dy;
    return CGAffineTransformMake(A.a, A.b, A.c, A.d, cc.x - vc.x + ax + A.tx, cc.y - vc.y + ay + A.ty);
}

// Every frame: follow the cover's own transform, with its animation when it has one.
- (void)frame:(CADisplayLink *)link {
    @try {
        UIView *tilt = self.tilt;
        if (!tilt || self.superview != tilt) return;
        UIView *cover = coverIn(tilt);
        CGAffineTransform A = cover ? cover.transform : CGAffineTransformIdentity;
        BOOL moved = !CGPointEqualToPoint(self.center, _lastCenter);
        if (!_followed || moved || !CGAffineTransformEqualToTransform(A, _lastCover)) {
            BOOL first = !_followed || (moved && CGAffineTransformEqualToTransform(A, _lastCover));
            _lastCenter = self.center;
            _followed = YES;
            _lastCover = A;
            CGAffineTransform M = cover ? followTransform(A, cover.center, self.center) : CGAffineTransformIdentity;
            CAAnimation *theirs = nil;
            for (NSString *k in cover.layer.animationKeys ?: @[]) {
                CAAnimation *an = [cover.layer animationForKey:k];
                if ([an isKindOfClass:CABasicAnimation.class] && [((CABasicAnimation *)an).keyPath isEqualToString:@"transform"]) { theirs = an; break; }
            }
            CATransform3D from = ((CALayer *)self.layer.presentationLayer ?: self.layer).transform;
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            self.transform = M;
            [CATransaction commit];
            if (theirs && !first) {
                CABasicAnimation *mine = [theirs copy];   // same duration, timing, spring and start time
                mine.keyPath = @"transform";
                mine.additive = NO;
                mine.fromValue = [NSValue valueWithCATransform3D:from];
                mine.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(M)];
                mine.removedOnCompletion = YES;
                mine.fillMode = kCAFillModeBackwards;
                [self.layer addAnimation:mine forKey:@"mrg.follow"];
            } else if (!first && self.window) {
                CABasicAnimation *mine = [CABasicAnimation animationWithKeyPath:@"transform"];
                mine.fromValue = [NSValue valueWithCATransform3D:from];
                mine.toValue = [NSValue valueWithCATransform3D:CATransform3DMakeAffineTransform(M)];
                mine.duration = 0.3;
                mine.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                [self.layer addAnimation:mine forKey:@"mrg.follow"];
            }
        }
        if (++_frames % 30 == 0) [self slowTick];
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: frame threw %@", e.reason);
    }
}

- (void)slowTick {
    @try {
        if (!self.window) return;
        if (!_disc.animationKeys.count) [self startSpin];
        [self setSpinning:MRGPlayerIsPlaying()];
        UIImage *img = coverImage(coverIn(self.tilt) ?: self.tilt, 0);
        if (img && img != _shownImage && img.CGImage) {
            _shownImage = img;
            _label.contents = (__bridge id)img.CGImage;
        } else if (!img && !_label.contents) {
            NSDictionary *now = MRGNowPlaying();
            NSString *url = [now[@"image"] isKindOfClass:NSString.class] ? now[@"image"] : nil;
            if (url.length && ![url isEqualToString:_shownURL] && [url hasPrefix:@"https://"]) {
                _shownURL = url;
                __weak MRGVinylView *weak = self;
                [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                    UIImage *got = data.length ? [UIImage imageWithData:data] : nil;
                    if (got) dispatch_async(dispatch_get_main_queue(), ^{ MRGVinylView *s = weak; if (s && !s->_shownImage) s->_label.contents = (__bridge id)got.CGImage; });
                }] resume];
            }
        }
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: tick threw %@", e.reason);
    }
}
@end

@implementation MRGVinylProxy
- (void)frame:(CADisplayLink *)link { MRGVinylView *o = self.owner; if (o) [o frame:link]; else [link invalidate]; }
@end

#pragma mark - placing it

static void restore(UIView *tilt) {
    MRGVinylView *vinyl = objc_getAssociatedObject(tilt, &kVinylKey);
    NSValue *ours = objc_getAssociatedObject(tilt, &kOursKey);
    if (ours && CGAffineTransformEqualToTransform(tilt.transform, ours.CGAffineTransformValue)) {
        if (tilt.window && CACurrentMediaTime() < sg_glideUntil) [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ tilt.transform = CGAffineTransformIdentity; } completion:nil];
        else tilt.transform = CGAffineTransformIdentity;
    }
    NSNumber *clip = objc_getAssociatedObject(tilt, &kClipKey);
    if (clip) tilt.clipsToBounds = clip.boolValue;
    [vinyl removeFromSuperview];
    objc_setAssociatedObject(tilt, &kVinylKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tilt, &kOursKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(tilt, &kClipKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void MRGVinylApply(UIView *tilt) {
    @try {
        if (!tilt || tilt.bounds.size.width < 200) return;
        if (!MRGAddonInstalled(@"vinyl")) {
            if (objc_getAssociatedObject(tilt, &kVinylKey)) { restore(tilt); logState(@"off, Now Playing is stock again"); }
            return;
        }
        CGSize S = tilt.bounds.size;
        CGFloat side = MIN(S.width, S.height);
        if (side < 150 || !isfinite(side)) return;
        CGFloat dir = MRGVinylOnLeft() ? -1 : 1;
        // In the superview: the sleeve plus the record showing make one centered piece.
        CGFloat cover = side * kCoverScale, peek = cover * kPeek;
        CGAffineTransform t = CGAffineTransformMake(kCoverScale, 0, 0, kCoverScale, -dir * peek / 2, 0);
        NSValue *ours = objc_getAssociatedObject(tilt, &kOursKey);
        CGAffineTransform now = tilt.transform;
        BOOL mine = CGAffineTransformIsIdentity(now) || (ours && CGAffineTransformEqualToTransform(now, ours.CGAffineTransformValue));
        if (mine && CATransform3DIsAffine(tilt.layer.transform) && !CGAffineTransformEqualToTransform(now, t)) {
            // Turned on or the side changed: glide there. A layout pass that only re-asserts it changes nothing.
            BOOL glide = tilt.window && CACurrentMediaTime() < sg_glideUntil;
            if (glide) [UIView animateWithDuration:0.45 delay:0 usingSpringWithDamping:0.86 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{ tilt.transform = t; } completion:nil];
            else tilt.transform = t;
            objc_setAssociatedObject(tilt, &kOursKey, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } else if (mine && CGAffineTransformEqualToTransform(now, t) && !ours) {
            objc_setAssociatedObject(tilt, &kOursKey, [NSValue valueWithCGAffineTransform:t], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }   // else Spotify is tilting the cover right now: left alone, taken back on a later pass

        // The record overhangs the tilt view's edge, so the tilt view must not clip (Spotify's doesn't; checked anyway).
        if (tilt.clipsToBounds) {
            if (!objc_getAssociatedObject(tilt, &kClipKey)) objc_setAssociatedObject(tilt, &kClipKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            tilt.clipsToBounds = NO;
            logState(@"the cover clipped its edges; unclipped for the record");
        }

        MRGVinylView *vinyl = objc_getAssociatedObject(tilt, &kVinylKey);
        BOOL fresh = vinyl == nil;
        if (fresh) {
            vinyl = [MRGVinylView new];
            objc_setAssociatedObject(tilt, &kVinylKey, vinyl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        vinyl.tilt = tilt;
        vinyl.dir = dir;
        // In the tilt view's own (unscaled) space the sleeve is the whole tilt view.
        CGFloat disc = side * kDisc;
        CGRect bounds = CGRectMake(0, 0, disc, disc);
        CGPoint center = CGPointMake(S.width / 2 + dir * (side / 2 + side * kPeek - disc / 2), S.height / 2);
        [UIView performWithoutAnimation:^{
            if (!CGRectEqualToRect(vinyl.bounds, bounds)) vinyl.bounds = bounds;
            if (!CGPointEqualToPoint(vinyl.center, center)) vinyl.center = center;
        }];
        if (vinyl.superview != tilt) [tilt insertSubview:vinyl atIndex:0];
        else if (tilt.subviews.firstObject != vinyl) [tilt sendSubviewToBack:vinyl];
        if (fresh && tilt.window && CACurrentMediaTime() < sg_glideUntil) {
            vinyl.alpha = 0;
            [UIView animateWithDuration:0.35 animations:^{ vinyl.alpha = 1; }];
        }
        logState([NSString stringWithFormat:@"on, cover %.0fpt, record inside it on the %@", side, dir > 0 ? @"right" : @"left"]);
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: layout threw %@, Now Playing stays stock", e.reason);
        @try { restore(tilt); } @catch (NSException *e2) {}
    }
}

%group MRGVinylHooks
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < 200) return;
    if (!MRGAddonInstalled(@"vinyl") && !objc_getAssociatedObject(tilt, &kVinylKey)) return;
    if (inPlayerCell(tilt)) MRGVinylApply(tilt);
}
- (void)didMoveToWindow {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.window && tilt.bounds.size.width >= 200 && MRGAddonInstalled(@"vinyl") && inPlayerCell(tilt)) [tilt setNeedsLayout];
}
%end

%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews {
    %orig;
    UIView *cell = (UIView *)self;
    UIView *tilt = findTilt(cell, 0);
    if (tilt && (MRGAddonInstalled(@"vinyl") || objc_getAssociatedObject(tilt, &kVinylKey))) MRGVinylApply(tilt);
}
%end
%end

// Turning the add-on on or off, or changing its settings, re-lays the covers on screen.
static void relayAll(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            NSMutableArray *stack = [NSMutableArray arrayWithObject:w];
            NSUInteger seen = 0;
            while (stack.count && seen < 4000) {
                UIView *v = stack.lastObject; [stack removeLastObject]; seen++;
                if (tiltClass() && [v isKindOfClass:tiltClass()] && v.bounds.size.width >= 200) { if (inPlayerCell(v)) MRGVinylApply(v); continue; }
                [stack addObjectsFromArray:v.subviews];
            }
        }
    }
}

%ctor {
    if (cellClass() && tiltClass()) {
        %init(MRGVinylHooks);
        [NSNotificationCenter.defaultCenter addObserverForName:MRGSettingsChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            static NSString *last;
            NSString *now = [NSString stringWithFormat:@"%d%d", MRGAddonInstalled(@"vinyl"), MRGVinylOnLeft()];
            if ([now isEqualToString:last]) return;   // another setting: nothing to move
            last = now;
            sg_glideUntil = CACurrentMediaTime() + 0.6;
            @try { relayAll(); } @catch (NSException *e) {}
        }];
    }
}
