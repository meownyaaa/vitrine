// Addon "Vinyl" (Now Playing): the player's cover becomes a record sleeve. The cover shrinks and moves to one side,
// and a vinyl record peeks out from behind it on the other, spinning while a song plays and standing still when it's
// paused. The record is drawn in code (grooves, a sheen that stays put while the disc turns, a center hole) and its
// label is the album art.
//
// Spotify's tree (from Vitrine's notes): CoverArtCellImpl > UIView > UIView > CoverArtTiltView (≥200pt in the player,
// 40pt in the bar). Spotify gives the tilt view its own transform when the cover is inspected, so it is left alone:
// the scale and shift go on the tilt view's wrapper when that wrapper holds only the cover, else nothing changes.
// Every step checks the class and view it needs; when one is missing Now Playing stays stock.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>
#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"

static const CGFloat kCoverScale = 0.74;
static char kVinylKey, kMovedKey;

static Class tiltClass(void) {
    static Class c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = NSClassFromString(@"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView"); });
    return c;
}

static UIView *findTilt(UIView *v, int depth) {
    if (!v || depth > 8) return nil;
    Class c = tiltClass();
    if (c && [v isKindOfClass:c] && v.bounds.size.width >= 200) return v;
    for (UIView *s in v.subviews) { UIView *t = findTilt(s, depth + 1); if (t) return t; }
    return nil;
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

static void MRGVinylLayout(UIView *cell);

#pragma mark - the record

@interface MRGVinylView : UIView
@property (nonatomic, weak) UIView *cover;   // the tilt view, read for its image
@property (nonatomic, weak) UIView *cell;
@end

@interface MRGVinylTicker : NSObject
@property (nonatomic, weak) MRGVinylView *owner;
@end

@implementation MRGVinylView {
    CALayer *_disc;             // turns
    CAGradientLayer *_base;
    CAShapeLayer *_grooves, *_rings;
    CALayer *_label;
    CAShapeLayer *_hole;
    CAGradientLayer *_sheen;    // stays still: the light on the record
    CAShapeLayer *_sheenMask;
    NSTimer *_timer;
    __weak UIImage *_shownImage;
    NSString *_shownURL;
    double _turn;
    BOOL _spinning, _built;
    CGFloat _builtSide;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.55;
    self.layer.shadowRadius = 14;
    self.layer.shadowOffset = CGSizeMake(0, 6);
    _disc = [CALayer layer];
    _base = [CAGradientLayer layer];
    _base.type = kCAGradientLayerRadial;
    _base.colors = @[(id)[UIColor colorWithWhite:0.16 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.07 alpha:1].CGColor, (id)[UIColor colorWithWhite:0.02 alpha:1].CGColor];
    _base.locations = @[@0, @0.55, @1];
    _base.startPoint = CGPointMake(0.5, 0.5);
    _base.endPoint = CGPointMake(1, 1);
    _grooves = [CAShapeLayer layer];
    _grooves.fillColor = nil;
    _grooves.strokeColor = [UIColor colorWithWhite:1 alpha:0.055].CGColor;
    _grooves.lineWidth = 0.6;
    _rings = [CAShapeLayer layer];
    _rings.fillColor = nil;
    _rings.strokeColor = [UIColor colorWithWhite:0 alpha:0.9].CGColor;
    _rings.lineWidth = 2;
    _label = [CALayer layer];
    _label.masksToBounds = YES;
    _label.contentsGravity = kCAGravityResizeAspectFill;
    _label.backgroundColor = MRGAccent().CGColor;
    _label.borderColor = [UIColor colorWithWhite:0 alpha:0.6].CGColor;
    _label.borderWidth = 1.5;
    _hole = [CAShapeLayer layer];
    _hole.fillColor = [UIColor colorWithWhite:0.02 alpha:1].CGColor;
    _hole.strokeColor = [UIColor colorWithWhite:1 alpha:0.18].CGColor;
    _hole.lineWidth = 0.75;
    for (CALayer *l in @[_base, _grooves, _rings, _label, _hole]) [_disc addSublayer:l];
    [self.layer addSublayer:_disc];
    _sheen = [CAGradientLayer layer];
    _sheen.type = kCAGradientLayerConic;
    _sheen.startPoint = CGPointMake(0.5, 0.5);
    _sheen.endPoint = CGPointMake(0.5, 0);
    UIColor *clear = [UIColor colorWithWhite:1 alpha:0], *lit = [UIColor colorWithWhite:1 alpha:0.13], *soft = [UIColor colorWithWhite:1 alpha:0.06];
    _sheen.colors = @[(id)clear.CGColor, (id)lit.CGColor, (id)clear.CGColor, (id)clear.CGColor, (id)soft.CGColor, (id)clear.CGColor, (id)clear.CGColor];
    _sheen.locations = @[@0, @0.09, @0.2, @0.5, @0.59, @0.7, @1];
    _sheenMask = [CAShapeLayer layer];
    _sheenMask.fillRule = kCAFillRuleEvenOdd;
    _sheen.mask = _sheenMask;
    [self.layer addSublayer:_sheen];
    _turn = MRGVinylSecondsPerTurn();
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(settingsChanged) name:MRGSettingsChangedNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; [_timer invalidate]; }

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
    // The disc turns around its own center: its bounds and position, not a frame, so a spin in flight is never moved.
    _disc.bounds = (CGRect){CGPointZero, sq.size};
    _disc.position = CGPointMake(CGRectGetMidX(sq), CGRectGetMidY(sq));
    CGRect d = _disc.bounds;
    CGPoint mid = CGPointMake(side / 2, side / 2);
    CGFloat R = side / 2;
    _base.frame = d;
    _base.cornerRadius = R;
    _base.masksToBounds = YES;
    UIBezierPath *g = [UIBezierPath bezierPath];
    for (CGFloat r = R * 0.40; r < R * 0.965; r += MAX(1.2, R / 46)) [g appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:r startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _grooves.frame = d;
    _grooves.path = g.CGPath;
    UIBezierPath *rings = [UIBezierPath bezierPath];   // the quiet gaps between tracks
    for (NSNumber *f in @[@0.52, @0.66, @0.81]) [rings appendPath:[UIBezierPath bezierPathWithArcCenter:mid radius:R * f.doubleValue startAngle:0 endAngle:2 * M_PI clockwise:YES]];
    _rings.frame = d;
    _rings.path = rings.CGPath;
    _rings.lineWidth = MAX(1, R / 90);
    CGFloat l = side * 0.36;
    _label.frame = CGRectMake(mid.x - l / 2, mid.y - l / 2, l, l);
    _label.cornerRadius = l / 2;
    CGFloat h = MAX(3, side * 0.022);
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
    [_timer invalidate];
    _timer = nil;
    if (!self.window) return;
    MRGVinylTicker *t = [MRGVinylTicker new];
    t.owner = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:t selector:@selector(tick) userInfo:nil repeats:YES];
    [self startSpin];
    [self tick];
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
    UIView *cell = self.cell;
    if (cell) [cell setNeedsLayout];
}

- (void)tick {
    @try {
        if (!self.window) return;
        if (!_disc.animationKeys.count) [self startSpin];
        [self setSpinning:MRGPlayerIsPlaying()];
        UIImage *img = coverImage(self.cover, 0);
        if (img && img != _shownImage && img.CGImage) {
            _shownImage = img;
            _label.contents = (__bridge id)img.CGImage;
        } else if (!img && !_label.contents) {
            NSString *url = [MRGNowPlaying()[@"image"] isKindOfClass:NSString.class] ? MRGNowPlaying()[@"image"] : nil;
            if (url.length && ![url isEqualToString:_shownURL] && [url hasPrefix:@"https://"]) {
                _shownURL = url;
                __weak MRGVinylView *weak = self;
                [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
                    UIImage *got = data.length ? [UIImage imageWithData:data] : nil;
                    if (got) dispatch_async(dispatch_get_main_queue(), ^{ MRGVinylView *s = weak; if (s && !s->_shownImage) s->_label.contents = (__bridge id)got.CGImage; });
                }] resume];
            }
        }
        UIView *cell = self.cell;
        if (cell) MRGVinylLayout(cell);   // catches sizes the first pass saw before Auto Layout settled
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: tick threw %@", e.reason);
    }
}
@end

@implementation MRGVinylTicker
- (void)tick { MRGVinylView *o = self.owner; if (o) [o tick]; }
@end

#pragma mark - placing it

// The view that gets scaled: the tilt view's wrapper when the cover is all it holds, so Spotify's own tilt transform
// on the cover is never overwritten.
static UIView *movable(UIView *tilt) {
    UIView *w = tilt.superview;
    if (!w || !w.superview) return nil;
    for (UIView *s in w.subviews) if (s != tilt && !s.hidden && s.alpha > 0.01 && s.bounds.size.width > 40 && ![s isKindOfClass:MRGVinylView.class]) return nil;
    return w;
}

static void restore(UIView *cell) {
    MRGVinylView *vinyl = objc_getAssociatedObject(cell, &kVinylKey);
    UIView *moved = objc_getAssociatedObject(cell, &kMovedKey);
    if (moved) moved.transform = CGAffineTransformIdentity;
    [vinyl removeFromSuperview];
    objc_setAssociatedObject(cell, &kVinylKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell, &kMovedKey, nil, OBJC_ASSOCIATION_ASSIGN);
}

static void MRGVinylLayout(UIView *cell) {
    @try {
        BOOL on = MRGAddonInstalled(@"vinyl");
        if (!on) { if (objc_getAssociatedObject(cell, &kVinylKey) || objc_getAssociatedObject(cell, &kMovedKey)) restore(cell); return; }
        UIView *tilt = findTilt(cell, 0);
        UIView *box = tilt ? movable(tilt) : nil;
        UIView *host = box.superview;
        if (!box || !host) {
            static dispatch_once_t once;
            dispatch_once(&once, ^{ MRGDJLog(@"vinyl: player cover not found (tilt %@, wrapper %@), Now Playing stays stock", tilt ? @"yes" : @"no", box ? @"yes" : @"no"); });
            if (objc_getAssociatedObject(cell, &kVinylKey)) restore(cell);
            return;
        }
        UIView *before = objc_getAssociatedObject(cell, &kMovedKey);
        if (before && before != box) restore(cell);

        CGSize S = box.bounds.size;
        CGPoint C = box.center;
        CGFloat side = MIN(S.width, S.height);
        if (side < 150) return;
        CGFloat cover = side * kCoverScale, disc = cover * 0.95, peek = cover * 0.36;
        CGFloat dir = MRGVinylOnLeft() ? -1 : 1;
        // The sleeve plus the bit of record showing make one centered piece.
        CGFloat whole = cover + peek;
        CGFloat coverX = C.x - dir * (whole / 2 - cover / 2);
        CGAffineTransform t = CGAffineTransformMake(kCoverScale, 0, 0, kCoverScale, coverX - C.x, 0);
        if (!CGAffineTransformEqualToTransform(box.transform, t)) box.transform = t;
        objc_setAssociatedObject(cell, &kMovedKey, box, OBJC_ASSOCIATION_ASSIGN);

        MRGVinylView *vinyl = objc_getAssociatedObject(cell, &kVinylKey);
        if (!vinyl) {
            vinyl = [MRGVinylView new];
            objc_setAssociatedObject(cell, &kVinylKey, vinyl, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            static dispatch_once_t once;
            dispatch_once(&once, ^{ MRGDJLog(@"vinyl: on, cover %.0fpt in %@, record on the %@", side, NSStringFromClass(host.class), dir > 0 ? @"right" : @"left"); });
        }
        vinyl.cover = tilt;
        vinyl.cell = cell;
        CGRect bounds = CGRectMake(0, 0, disc, disc);
        if (!CGRectEqualToRect(vinyl.bounds, bounds)) vinyl.bounds = bounds;
        CGPoint center = CGPointMake(coverX + dir * (cover / 2 + peek - disc / 2), C.y);
        if (!CGPointEqualToPoint(vinyl.center, center)) vinyl.center = center;
        NSUInteger vi = [host.subviews indexOfObjectIdenticalTo:vinyl], bi = [host.subviews indexOfObjectIdenticalTo:box];
        if (vinyl.superview != host || vi == NSNotFound || vi > bi) [host insertSubview:vinyl belowSubview:box];
        vinyl.hidden = box.hidden || box.alpha < 0.01;
    } @catch (NSException *e) {
        MRGDJLog(@"vinyl: layout threw %@, Now Playing stays stock", e.reason);
        @try { restore(cell); } @catch (NSException *e2) {}
    }
}

%group MRGVinylHooks
%hook _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl
- (void)layoutSubviews {
    %orig;
    MRGVinylLayout((UIView *)self);
}
%end
%end

%ctor {
    if (NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl") && tiltClass()) %init(MRGVinylHooks);
}
