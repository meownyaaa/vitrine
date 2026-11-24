#import "SGGlassThumb.h"
#import "SGGlass.h"
#import <objc/runtime.h>

static char kThumbKey, kImageKey, kSizeKey, kWatchKey, kPaneKey;

// How much the held glass is bigger than the capsule at rest, the way iOS 26's thumb swells under a finger: 37x24 to
// 58x38.333, as LiquidGlassKit (github.com/DnV1eX/LiquidGlassKit, MIT) measured it for both the slider and the switch.
static const CGFloat kLiftWidth = 58.0 / 37, kLiftHeight = 38.333 / 24;
// The swell is a lively spring and the fall back a calmer, slower one (LiquidGlassKit: 0.4 s at 0.6, 0.6 s at 0.7).
static const NSTimeInterval kLiftDuration = 0.4, kDropDuration = 0.6;
static const CGFloat kLiftDamping = 0.6, kDropDamping = 0.7;
// How much of the measured lens the held glass takes: the bend of the band at the rim, round the switch's lens's middle.
static const CGFloat kHeldLensScale = 0.6;
// iOS 26's held switch thumb (its own Settings in the dark) shrinks what is under it: inside the drop the track shows
// smaller than it is, a green (or grey) pill about the drop's middle on the card's dark, and the drop reaches past the
// track's end. There is no white outline: the rim is the glass's bend and its light, with a soft shadow under it. The
// backdrop glass cannot shrink (it holds only what is under it), so the switch's lens draws its middle itself: the card's
// colour, and the track at kLensShrink about the drop's middle, inset kLensBand from the rim, where the glass bends the
// real track and card.
static const CGFloat kLensShrink = 0.7, kLensBand = 1.25;
// Where the track runs on past an edge of the drop, the shrunk track flares out to the drop's whole height over this
// much of that edge, following its curve, as the system's lens bends the track in at its rim; cut straight, the track
// reads as a plain bar of green, and the card's dark between it and the rim as a band no lens has. The flare comes in
// over this much of the track past the edge.
static const CGFloat kFlareWidth = 12, kFlareRamp = 6, kFlareLift = 0.6;
// The rim's light: a 1 pt line lit only on the top left and the bottom right, as the system's is, not a whole ring.
static const CGFloat kGlareWidth = 1;
// Past an end of the track the thumb follows the finger by this share of the overshoot, up to kMaxPull, and is
// stretched along the pull and thinned across it by its share of kPullStretch.
static const CGFloat kPullShare = 0.3, kMaxPull = 14, kPullStretch = 0.25;

#pragma mark - the capsule

@interface SGGlassThumbView : UIView
// How much bigger the held glass is, across and down (the slider's 1.5 and 1.35 unless set).
@property (nonatomic) CGFloat liftX, liftY;
- (void)setLifted:(BOOL)lifted;
- (void)setPull:(CGFloat)pull;
// No shadow under the capsule at rest: iOS 26's switch thumb is flat.
- (void)setFlat;
// The colour the held lens glows with, round its rim: the switch's track colour, as iOS 26's lens glows green over a switch
// that is on. White unless set.
- (void)setTrack:(CGRect)track color:(UIColor *)color;
// The colour of what the switch sits on (its card), for the lens's middle.
- (void)setSurface:(UIColor *)color;
@end

@implementation SGGlassThumbView {
    UIView *_pill;
    UIView *_pane;
    UIView *_rim;
    CAShapeLayer *_ring;
    CALayer *_shade;
    UIView *_inner;
    UIView *_miniClip;
    UIView *_mini;
    CAShapeLayer *_flareLeft, *_flareRight;
    CAGradientLayer *_glare;
    CAShapeLayer *_glareRing;
    CGRect _track;
    BOOL _hasTrack;
    BOOL _lifted;
    CGFloat _pull;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _liftX = kLiftWidth;
    _liftY = kLiftHeight;
    _pane = SGGlassFor(self, &kPaneKey);
    _pane.alpha = 0;
    // The held lens is a drop of clear glass, as LiquidGlassKit's thumb is: what is under it keeps its colours and its
    // sharpness (no saturation, no blur), the middle shows it as it is and the edge bends it in hard over a band of
    // glass thickness, under a near clear tint with a cool bias (0.9, 0.95, 1.0 at 12%), with no outline of its own.
    // On the pane glass, saturated and blurred, a switch's green showed through as a neon blob, and a white outline
    // drawn round it read as a ring, not a drop.
    if ([_pane isKindOfClass:SGLegacyGlassView.class]) {
        SGLegacyGlassView *glass = (SGLegacyGlassView *)_pane;
        glass.clear = YES;
        glass.blurRadius = 0;
        glass.lensScale = kHeldLensScale;
        // At the screen's scale: a 1x backdrop under a lens this small showed the track soft, and the thumb is small enough
        // for the cost.
        glass.sharp = YES;
        // Its light is the thumb's own (_glare), on two arcs, not the pane's along nearly all of the rim.
        glass.rimless = YES;
    }
    // The shadow under the drop, its own layer behind the glass so the glass does not take it for its backdrop.
    _shade = [CALayer layer];
    _shade.shadowColor = UIColor.blackColor.CGColor;
    _shade.shadowOpacity = 0;
    _shade.shadowRadius = 5;
    _shade.shadowOffset = CGSizeMake(0, 2);
    [self.layer insertSublayer:_shade atIndex:0];
    // The middle of a switch's drop (setTrack:): the card and the track shrunk; nothing on a slider's.
    _inner = [UIView new];
    _inner.userInteractionEnabled = NO;
    _inner.clipsToBounds = YES;
    _inner.layer.cornerCurve = kCACornerCurveContinuous;
    _inner.hidden = YES;
    _inner.alpha = _pane.alpha;
    _miniClip = [UIView new];
    _miniClip.userInteractionEnabled = NO;
    _miniClip.clipsToBounds = YES;
    _miniClip.layer.cornerCurve = kCACornerCurveContinuous;
    [_inner addSubview:_miniClip];
    _mini = [UIView new];
    _mini.userInteractionEnabled = NO;
    _mini.layer.cornerCurve = kCACornerCurveContinuous;
    [_miniClip addSubview:_mini];
    _flareLeft = [CAShapeLayer layer];
    _flareRight = [CAShapeLayer layer];
    [_miniClip.layer addSublayer:_flareLeft];
    [_miniClip.layer addSublayer:_flareRight];
    [self addSubview:_inner];
    _ring = [CAShapeLayer layer];
    _ring.fillColor = [UIColor colorWithRed:0.9 green:0.95 blue:1 alpha:0.06].CGColor;
    _ring.strokeColor = UIColor.clearColor.CGColor;
    _rim = [UIView new];
    _rim.userInteractionEnabled = NO;
    _rim.alpha = _pane.alpha;
    [_rim.layer addSublayer:_ring];
    _glare = [CAGradientLayer layer];
    _glare.startPoint = CGPointMake(0, 0);
    _glare.endPoint = CGPointMake(1, 1);
    _glare.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.75].CGColor, (id)[UIColor colorWithWhite:1 alpha:0].CGColor,
                      (id)[UIColor colorWithWhite:1 alpha:0].CGColor, (id)[UIColor colorWithWhite:1 alpha:0.45].CGColor];
    _glare.locations = @[@0, @0.32, @0.68, @1];
    _glareRing = [CAShapeLayer layer];
    _glareRing.fillColor = nil;
    _glareRing.strokeColor = UIColor.whiteColor.CGColor;
    _glareRing.lineWidth = kGlareWidth;
    _glare.mask = _glareRing;
    [_rim.layer addSublayer:_glare];
    [self addSubview:_rim];
    _pill = [UIView new];
    _pill.backgroundColor = UIColor.whiteColor;
    _pill.userInteractionEnabled = NO;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    _pill.layer.shadowColor = UIColor.blackColor.CGColor;
    _pill.layer.shadowOpacity = 0.18;
    _pill.layer.shadowRadius = 3;
    _pill.layer.shadowOffset = CGSizeMake(0, 1);
    [self addSubview:_pill];
    return self;
}

- (void)setFlat {
    _pill.layer.shadowOpacity = 0;
}

- (void)setSurface:(UIColor *)color {
    if (![_inner.backgroundColor isEqual:color]) _inner.backgroundColor = color;
}

// `track` is the switch's track in the view this thumb sits in; the thumb's centre is read as it is set (the model's,
// inside the caller's animation), so the shrunk track moves across the drop with it.
- (void)setTrack:(CGRect)track color:(UIColor *)color {
    _track = track;
    _hasTrack = YES;
    _inner.hidden = NO;
    _mini.backgroundColor = color;
    CGColorRef fill = color.CGColor;
    for (CAShapeLayer *flare in @[_flareLeft, _flareRight]) {
        if (!CGColorEqualToColor(flare.fillColor, fill)) [self setLayer:flare value:(__bridge id)fill forKey:@"fillColor"];
    }
    [self placeMini];
}

- (void)placeMini {
    if (!_hasTrack) return;
    CGSize held = [self heldSize];
    CGSize size = self.bounds.size;
    // The drop's middle, in the thumb's parent, and the track about it in the drop's own points, then shrunk.
    CGPoint middle = self.center;
    CGPoint origin = CGPointMake(middle.x - held.width / 2, middle.y - held.height / 2);
    CGRect inDrop = CGRectOffset(_track, -origin.x, -origin.y);
    CGPoint c = CGPointMake(held.width / 2, held.height / 2);
    CGRect mini = CGRectMake(c.x + (CGRectGetMinX(inDrop) - c.x) * kLensShrink, c.y + (CGRectGetMinY(inDrop) - c.y) * kLensShrink,
                             inDrop.size.width * kLensShrink, inDrop.size.height * kLensShrink);
    // In the inner view's points, which is the drop inset by the band.
    mini = CGRectOffset(mini, -kLensBand, -kLensBand);
    if (size.width < 1) return;
    _mini.frame = mini;
    _mini.layer.cornerRadius = mini.size.height / 2;
    // How far the track runs past each edge of the drop decides how much each side flares.
    CGFloat pastLeft = -CGRectGetMinX(inDrop), pastRight = CGRectGetMaxX(inDrop) - held.width;
    CGSize clip = _miniClip.bounds.size;
    [self setLayer:_flareLeft value:(__bridge id)[self flareAt:NO width:kFlareWidth * MAX(0, MIN(1, pastLeft / kFlareRamp)) mini:mini clip:clip] forKey:@"path"];
    [self setLayer:_flareRight value:(__bridge id)[self flareAt:YES width:kFlareWidth * MAX(0, MIN(1, pastRight / kFlareRamp)) mini:mini clip:clip] forKey:@"path"];
}

// One edge's flare, in the clip's points: from the shrunk track's top and bottom `width` in from that edge, curving out
// to the edge's whole height; the clip's capsule rounds it to the drop's curve. The same elements at any width, so
// one flare can move into the next.
- (CGPathRef)flareAt:(BOOL)right width:(CGFloat)width mini:(CGRect)mini clip:(CGSize)clip {
    CGFloat top = CGRectGetMinY(mini), bottom = CGRectGetMaxY(mini), h = clip.height;
    CGFloat edge = right ? clip.width : 0, in = right ? clip.width - width : width;
    CGFloat ease = right ? clip.width - width * kFlareLift : width * kFlareLift;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(in, top)];
    [path addCurveToPoint:CGPointMake(edge, -1) controlPoint1:CGPointMake(ease, top * 0.6) controlPoint2:CGPointMake(edge, top * 0.2)];
    [path addLineToPoint:CGPointMake(edge, h + 1)];
    [path addCurveToPoint:CGPointMake(in, bottom) controlPoint1:CGPointMake(edge, bottom + (h - bottom) * 0.8) controlPoint2:CGPointMake(ease, bottom + (h - bottom) * 0.4)];
    [path closePath];
    return path.CGPath;
}

// A layer's value set as the views round it move: in the caller's view animation, along with it, or at once without one.
- (void)setLayer:(CALayer *)layer value:(id)value forKey:(NSString *)key {
    NSTimeInterval duration = UIView.inheritedAnimationDuration;
    if (duration > 0) {
        CABasicAnimation *move = [CABasicAnimation animationWithKeyPath:key];
        move.fromValue = [layer.presentationLayer ?: layer valueForKey:key];
        move.toValue = value;
        move.duration = duration;
        move.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
        [layer addAnimation:move forKey:key];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [layer setValue:value forKey:key];
    [CATransaction commit];
}

// The held glass is laid out at its held size and shrunk by a transform at rest, never grown from the capsule's: grown,
// it magnified the bit of track under the capsule, so the lens was the track's colour through and through and showed
// nothing of what is round the track.
- (CGSize)heldSize {
    return CGSizeMake(self.bounds.size.width * _liftX, self.bounds.size.height * _liftY);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat radius = bounds.size.height / 2;
    CGPoint middle = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
    _pill.bounds = bounds;
    _pill.center = middle;
    _pill.layer.cornerRadius = radius;
    _pill.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:bounds cornerRadius:radius].CGPath;
    CGRect held = (CGRect){CGPointZero, [self heldSize]};
    if (!CGRectEqualToRect(_pane.bounds, held)) _pane.bounds = held;
    _pane.center = middle;
    SGShapeGlass(_pane, held.size.height / 2, YES);
    _rim.bounds = held;
    _rim.center = middle;
    CGRect inner = CGRectInset(held, kLensBand, kLensBand);
    _inner.bounds = (CGRect){CGPointZero, inner.size};
    _inner.center = middle;
    _inner.layer.cornerRadius = inner.size.height / 2;
    CGRect clip = (CGRect){CGPointZero, inner.size};
    _miniClip.frame = clip;
    _miniClip.layer.cornerRadius = clip.size.height / 2;
    [self placeMini];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    CGFloat heldRadius = held.size.height / 2;
    _ring.frame = held;
    _ring.path = [UIBezierPath bezierPathWithRoundedRect:held cornerRadius:heldRadius].CGPath;
    _glare.frame = held;
    _glareRing.frame = _glare.bounds;
    CGRect line = CGRectInset(held, kGlareWidth / 2, kGlareWidth / 2);
    _glareRing.path = [UIBezierPath bezierPathWithRoundedRect:line cornerRadius:line.size.height / 2].CGPath;
    _shade.bounds = held;
    _shade.position = middle;
    _shade.shadowPath = [UIBezierPath bezierPathWithRoundedRect:held cornerRadius:heldRadius].CGPath;
    [CATransaction commit];
    [self applyLift];
}

- (void)applyLift {
    CGAffineTransform rest = CGAffineTransformMakeScale(1 / _liftX, 1 / _liftY);
    _pill.transform = _lifted ? CGAffineTransformMakeScale(_liftX, _liftY) : CGAffineTransformIdentity;
    _pane.transform = _lifted ? CGAffineTransformIdentity : rest;
    _rim.transform = _pane.transform;
    _inner.transform = _pane.transform;
    _shade.affineTransform = _pane.transform;
}

// The pull is the whole thumb's transform; the swell is its parts' (applyLift), so either can change without the other
// jumping.
- (CGAffineTransform)pose {
    CGFloat stretch = fabs(_pull) / kMaxPull * kPullStretch;
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(_pull, 0), 1 + stretch, 1 - stretch * 0.5);
}

- (void)setLifted:(BOOL)lifted {
    if (_lifted == lifted) return;
    _lifted = lifted;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    [UIView animateWithDuration:still ? 0.2 : (lifted ? kLiftDuration : kDropDuration) delay:0
         usingSpringWithDamping:still ? 1 : (lifted ? kLiftDamping : kDropDamping)
          initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        if (!still) [self applyLift];
        self->_pill.alpha = lifted ? 0 : 1;
        self->_pane.alpha = lifted ? 1 : 0;
        self->_rim.alpha = self->_pane.alpha;
        self->_inner.alpha = self->_pane.alpha;
    } completion:nil];
    // A layer's shadow is not a view's animatable property: it fades in its own animation, as long as the swell.
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    fade.fromValue = @(_shade.presentationLayer ? _shade.presentationLayer.shadowOpacity : _shade.shadowOpacity);
    fade.toValue = @(lifted ? 0.35f : 0.0f);
    fade.duration = lifted ? 0.2 : 0.3;
    _shade.shadowOpacity = lifted ? 0.35f : 0.0f;
    [_shade addAnimation:fade forKey:@"fade"];
}

- (void)setPull:(CGFloat)pull {
    if (UIAccessibilityIsReduceMotionEnabled()) pull = 0;
    if (_pull == pull) return;
    BOOL back = pull == 0;
    _pull = pull;
    if (!back) {
        self.transform = [self pose];
        return;
    }
    [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ self.transform = [self pose]; } completion:nil];
}

@end

#pragma mark - the finger

// Watches the slider's touches without taking any: the slider tracks them as it always does.
@interface SGGlassThumbWatch : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property (nonatomic, weak) SGGlassThumbView *thumb;
@end

@implementation SGGlassThumbWatch {
    UITouch *_touch;
    BOOL _atEnd;
    UIImpactFeedbackGenerator *_tap;
}

- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:NULL])) return nil;
    self.delegate = self;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}

- (BOOL)canPrevent:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePrevented:(UIGestureRecognizer *)other { return NO; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

// The thumb's middle at the two ends of its travel, in the slider.
static void travelOf(UISlider *slider, CGFloat *lo, CGFloat *hi) {
    CGRect bounds = slider.bounds, track = [slider trackRectForBounds:bounds];
    *lo = CGRectGetMidX([slider thumbRectForBounds:bounds trackRect:track value:slider.minimumValue]);
    *hi = CGRectGetMidX([slider thumbRectForBounds:bounds trackRect:track value:slider.maximumValue]);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UISlider *slider = (UISlider *)self.view;
    UIView *host = self.thumb.superview;
    if (_touch || !slider.enabled || !host) return;
    // UIKit tracks a touch that lands on the thumb (with some room round it); one elsewhere moves nothing.
    UITouch *touch = touches.anyObject;
    CGRect thumb = [slider convertRect:host.bounds fromView:host];
    if (!CGRectContainsPoint(CGRectInset(thumb, -20, -20), [touch locationInView:slider])) return;
    _touch = touch;
    _atEnd = NO;
    if (!_tap) _tap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_tap prepare];
    [self.thumb setLifted:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UISlider *slider = (UISlider *)self.view;
    if (!_touch || ![touches containsObject:_touch]) return;
    CGFloat x = [_touch locationInView:slider].x, lo, hi;
    travelOf(slider, &lo, &hi);
    CGFloat over = x < lo ? x - lo : x > hi ? x - hi : 0;
    BOOL atEnd = over != 0;
    if (atEnd && !_atEnd) {
        [_tap impactOccurred];
        [_tap prepare];
    }
    _atEnd = atEnd;
    CGFloat pull = over * kPullShare;
    [self.thumb setPull:MAX(-kMaxPull, MIN(kMaxPull, pull))];
}

- (void)finish {
    if (!_touch) return;
    _touch = nil;
    _atEnd = NO;
    [self.thumb setPull:0];
    [self.thumb setLifted:NO];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) [self finish];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) [self finish];
}

- (void)reset { [self finish]; }

@end

#pragma mark - the one entry

static UIImage *clearImage(CGSize size) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format] imageWithActions:^(UIGraphicsImageRendererContext *context) {}];
}

// The view UIKit draws the thumb with: the image view in the slider that shows our clear image.
static UIImageView *thumbViewOf(UISlider *slider, UIImage *image) {
    __block UIImageView *found = nil;
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:slider];
    while (queue.count && !found) {
        UIView *view = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image == image) found = (UIImageView *)view;
        [queue addObjectsFromArray:view.subviews];
    }
    return found;
}

void SGGlassThumbAttach(UISlider *slider, CGSize size) {
    if (!slider || !SGUseLegacyGlass() || size.width < 1 || size.height < 1) return;
    UIImage *image = objc_getAssociatedObject(slider, &kImageKey);
    NSValue *was = objc_getAssociatedObject(slider, &kSizeKey);
    if (!image || !CGSizeEqualToSize(was.CGSizeValue, size)) {
        image = clearImage(size);
        objc_setAssociatedObject(slider, &kImageKey, image, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(slider, &kSizeKey, [NSValue valueWithCGSize:size], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The owner may set its own thumb again (Spotify as the track changes, the volume view as the route does).
    if ([slider thumbImageForState:UIControlStateNormal] != image) {
        [slider setThumbImage:image forState:UIControlStateNormal];
        [slider setThumbImage:image forState:UIControlStateHighlighted];
        [slider layoutIfNeeded];
    }
    UIImageView *host = thumbViewOf(slider, image);
    if (!host) return;
    if (host.clipsToBounds) host.clipsToBounds = NO;
    SGGlassThumbView *thumb = objc_getAssociatedObject(slider, &kThumbKey);
    if (!thumb) {
        thumb = [SGGlassThumbView new];
        objc_setAssociatedObject(slider, &kThumbKey, thumb, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (thumb.superview != host) [host addSubview:thumb];
    // By bounds and center: the swell is a transform.
    if (!CGSizeEqualToSize(thumb.bounds.size, size)) thumb.bounds = (CGRect){CGPointZero, size};
    CGPoint middle = CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds));
    if (!CGPointEqualToPoint(thumb.center, middle)) thumb.center = middle;
    SGGlassThumbWatch *watch = objc_getAssociatedObject(slider, &kWatchKey);
    if (!watch) {
        watch = [SGGlassThumbWatch new];
        objc_setAssociatedObject(slider, &kWatchKey, watch, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [slider addGestureRecognizer:watch];
    }
    watch.thumb = thumb;
}

#pragma mark - a switch

// iOS 26's switch, as adaptive_liquid_glass measured it from SwiftUI on iOS 26.4 (github.com/AymanOmara/
// adaptive_liquid_glass, MIT: lib/src/controls/control_metrics.dart, glass_colors.dart): a 63 x 28 track, a flat white
// 37 x 24 capsule 2 pt in from its ends, which grows into a drop of clear glass 58 x 38.333 while a finger holds it
// (LiquidGlassKit), and moves to a new value on a spring with no overshoot, 0.5 s. A tap swells the thumb, carries the
// drop across and lets it fall back 0.2 s later; a drag follows the finger, on a rubber band past the ends.
// The track is #464649 while off in the dark and the switch's on tint while on, blended as the thumb crosses.
//
// UIKit's switch stays the control: its value, its touches and its accessibility are its own, and only what it draws is
// replaced, by this view inside it, its own drawing kept at alpha 0. The track is wider than UIKit's 51 pt, so it lines
// up with the switch's trailing edge and reaches past its leading one.
static const CGSize kSwitchTrack = {63, 28}, kSwitchThumb = {37, 24};
static const CGFloat kSwitchInset = 2, kSwitchLiftX = 58.0 / 37, kSwitchLiftY = 38.333 / 24;
// A tap's drop falls back this long after it set off across the track.
static const NSTimeInterval kTapDropDelay = 0.2;

@interface SGGlassSwitchView : UIView
@property (nonatomic, weak) UISwitch *toggle;
@property (nonatomic, readonly) SGGlassThumbView *thumb;
@property (nonatomic) CGFloat position;   // 0 off, 1 on
- (void)showPosition:(CGFloat)position animated:(BOOL)animated;
@end

@implementation SGGlassSwitchView {
    UIView *_track;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _track = [UIView new];
    _track.userInteractionEnabled = NO;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_track];
    _thumb = [SGGlassThumbView new];
    _thumb.liftX = kSwitchLiftX;
    _thumb.liftY = kSwitchLiftY;
    [_thumb setFlat];
    [self addSubview:_thumb];
    return self;
}

static UIColor *trackColor(UISwitch *toggle, CGFloat position) {
    UIColor *off = [UIColor colorWithRed:0x46 / 255.0 green:0x46 / 255.0 blue:0x49 / 255.0 alpha:1];
    // Resolved in the dark, as the face is drawn: getRed: reads a dynamic colour in whatever trait is current, which in a
    // light-mode phone gave the light green (#34C759) instead of the dark one iOS 26 draws on black (#30D158).
    UITraitCollection *dark = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
    UIColor *on = [(toggle.onTintColor ?: UIColor.systemGreenColor) resolvedColorWithTraitCollection:dark];
    CGFloat r0, g0, b0, a0, r1, g1, b1, a1;
    if (![off getRed:&r0 green:&g0 blue:&b0 alpha:&a0] || ![on getRed:&r1 green:&g1 blue:&b1 alpha:&a1]) return position > 0.5 ? on : off;
    CGFloat t = MAX(0, MIN(1, position));
    return [UIColor colorWithRed:r0 + (r1 - r0) * t green:g0 + (g1 - g0) * t blue:b0 + (b1 - b0) * t alpha:a0 + (a1 - a0) * t];
}

// What the switch sits on, for the middle of its lens: the first ancestor with a fill (the row's card), or the dark of
// the mod's cards when none has one.
static UIColor *surfaceOf(UISwitch *toggle) {
    for (UIView *v = toggle.superview; v; v = v.superview) {
        CGColorRef fill = v.layer.backgroundColor;
        if (fill && CGColorGetAlpha(fill) > 0.5) return [UIColor colorWithCGColor:fill];
        if ([v isKindOfClass:UIWindow.class]) break;
    }
    return [UIColor colorWithRed:0x1C / 255.0 green:0x1C / 255.0 blue:0x1E / 255.0 alpha:1];
}

// The thumb's centre for `position`, in this view; past 0 or 1 while a drag pulls it on its rubber band.
- (CGPoint)thumbCenterAt:(CGFloat)position {
    CGFloat travel = kSwitchTrack.width - kSwitchThumb.width - 2 * kSwitchInset;
    return CGPointMake(kSwitchInset + kSwitchThumb.width / 2 + travel * position, kSwitchTrack.height / 2);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _track.frame = (CGRect){CGPointZero, kSwitchTrack};
    _track.layer.cornerRadius = kSwitchTrack.height / 2;
    // By bounds and centre: the lift is a transform.
    if (!CGSizeEqualToSize(_thumb.bounds.size, kSwitchThumb)) _thumb.bounds = (CGRect){CGPointZero, kSwitchThumb};
}

- (void)showPosition:(CGFloat)position animated:(BOOL)animated {
    _position = position;
    [self layoutIfNeeded];
    void (^apply)(void) = ^{
        self.thumb.center = [self thumbCenterAt:position];
        self->_track.backgroundColor = trackColor(self.toggle, position);
        [self.thumb setTrack:self->_track.frame color:self->_track.backgroundColor];
    };
    [self.thumb setSurface:surfaceOf(self.toggle)];
    if (!animated || UIAccessibilityIsReduceMotionEnabled()) {
        [UIView performWithoutAnimation:apply];
        return;
    }
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:apply completion:nil];
}

@end

// Watches the switch's touches without taking any, as the slider's watch does: the thumb lifts at the touch, follows a
// drag along the track, and at the touch's end the switch turns (a tap) or goes to the side the thumb was let go on (a
// drag). UIKit's own drawing, which took the switch's touches, is kept unseen and out of hit-testing (hideOwnDrawing),
// so the turn is made here; it is made only if UIKit has not turned the switch itself, so it never turns twice.
@interface SGGlassSwitchWatch : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property (nonatomic, weak) SGGlassSwitchView *face;
@end

@implementation SGGlassSwitchWatch {
    UITouch *_touch;
    CGFloat _startX, _startPosition;
    BOOL _dragging, _startOn;
    NSUInteger _press;
    UIImpactFeedbackGenerator *_tap;
}

- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:NULL])) return nil;
    self.delegate = self;
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}

- (BOOL)canPrevent:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePrevented:(UIGestureRecognizer *)other { return NO; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UISwitch *toggle = (UISwitch *)self.view;
    if (_touch || !toggle.enabled) return;
    _touch = touches.anyObject;
    _startX = [_touch locationInView:toggle].x;
    _startPosition = self.face.position;
    _startOn = toggle.isOn;
    _dragging = NO;
    _press++;
    if (!_tap) _tap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [_tap prepare];
    [self.face.thumb setLifted:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touch || ![touches containsObject:_touch]) return;
    CGFloat dx = [_touch locationInView:self.view].x - _startX;
    if (!_dragging && fabs(dx) < 3) return;
    _dragging = YES;
    // Past an end the thumb follows by the square root of the overshoot, a rubber band (LiquidGlassKit).
    CGFloat travel = kSwitchTrack.width - kSwitchThumb.width - 2 * kSwitchInset;
    CGFloat along = _startPosition * travel + dx;
    if (along < 0) along = -sqrt(-along);
    else if (along > travel) along = travel + sqrt(along - travel);
    [self.face showPosition:along / travel animated:NO];
}

- (void)finishTurning:(BOOL)turn {
    if (!_touch) return;
    _touch = nil;
    NSUInteger press = _press;
    BOOL startOn = _startOn;
    BOOL dragged = _dragging;
    BOOL want = !dragged ? !startOn : self.face.position >= 0.5;
    // Whatever UIKit does with the touch, it does as the touch ends, after this: the switch is read a turn later.
    dispatch_async(dispatch_get_main_queue(), ^{
        UISwitch *toggle = (UISwitch *)self.view;
        if (press != self->_press || !toggle) return;
        if (turn && toggle.enabled && toggle.isOn == startOn && want != startOn) {
            [self->_tap impactOccurred];
            [toggle setOn:want animated:YES];
            [toggle sendActionsForControlEvents:UIControlEventValueChanged];
        }
        [self.face showPosition:toggle.isOn ? 1 : 0 animated:YES];
        if (dragged) {
            [self.face.thumb setLifted:NO];
            return;
        }
        // A tap: the drop crosses, then falls back, unless a new touch has taken it in the meantime.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTapDropDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (press == self->_press && !self->_touch) [self.face.thumb setLifted:NO];
        });
    });
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!_touch || ![touches containsObject:_touch]) return;
    // A tap that slid off the switch is no tap, as UIKit's own buttons have it.
    UIView *view = self.view;
    BOOL inside = _dragging || CGRectContainsPoint(CGRectInset(view.bounds, -16, -16), [_touch locationInView:view]);
    [self finishTurning:inside];
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_touch && [touches containsObject:_touch]) [self finishTurning:NO];
}

- (void)reset { [self finishTurning:NO]; }

@end

static char kSwitchFaceKey;

// UIKit's own drawing of the switch, kept unseen: everything in it but the face. It would take the switch's touches
// (a view at alpha 0 is not hit-tested, and its layer's opacity is that same alpha), so it is taken out of hit-testing
// outright and the touches land on the switch, where SGGlassSwitchWatch turns it.
static void hideOwnDrawing(UISwitch *toggle, UIView *face) {
    for (UIView *sub in toggle.subviews) {
        if (sub == face) continue;
        if (sub.alpha > 0) sub.alpha = 0;
        if (sub.userInteractionEnabled) sub.userInteractionEnabled = NO;
    }
}

static void placeFace(UISwitch *toggle, SGGlassSwitchView *face) {
    CGSize size = toggle.bounds.size;
    CGRect frame = CGRectMake(size.width - kSwitchTrack.width, round((size.height - kSwitchTrack.height) / 2),
                              kSwitchTrack.width, kSwitchTrack.height);
    if (!CGRectEqualToRect(face.frame, frame)) face.frame = frame;
    CGFloat alpha = toggle.enabled ? 1 : 0.5;
    if (face.alpha != alpha) face.alpha = alpha;
}

void SGGlassSwitchAttach(UISwitch *toggle) {
    if (!toggle || !SGUseLegacyGlass() || objc_getAssociatedObject(toggle, &kSwitchFaceKey)) return;
    SGGlassSwitchView *face = [SGGlassSwitchView new];
    face.toggle = toggle;
    objc_setAssociatedObject(toggle, &kSwitchFaceKey, face, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    toggle.clipsToBounds = NO;
    [toggle addSubview:face];
    placeFace(toggle, face);
    hideOwnDrawing(toggle, face);
    [face showPosition:toggle.isOn ? 1 : 0 animated:NO];
    SGGlassSwitchWatch *watch = [SGGlassSwitchWatch new];
    watch.face = face;
    [toggle addGestureRecognizer:watch];
}

BOOL SGGlassSwitchContains(UISwitch *toggle, CGPoint point) {
    SGGlassSwitchView *face = toggle ? objc_getAssociatedObject(toggle, &kSwitchFaceKey) : nil;
    return face && !face.hidden && CGRectContainsPoint(face.frame, point);
}

void SGGlassSwitchSync(UISwitch *toggle, BOOL animated) {
    SGGlassSwitchView *face = toggle ? objc_getAssociatedObject(toggle, &kSwitchFaceKey) : nil;
    if (!face) return;
    [toggle bringSubviewToFront:face];
    placeFace(toggle, face);
    hideOwnDrawing(toggle, face);
    CGFloat position = toggle.isOn ? 1 : 0;
    if (face.position != position) [face showPosition:position animated:animated && face.window];
}
