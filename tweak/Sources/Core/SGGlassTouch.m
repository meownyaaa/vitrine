#import "SGGlassTouch.h"
#import "SGGlass.h"
#import <objc/runtime.h>
#import <UIKit/UIGestureRecognizerSubclass.h>

static char kRecognizerKey;    // on a host: its SGGlassTouchRecognizer

#pragma mark - the stand-in

static const CGFloat kGrow = 15, kMaxGrowScale = 1.08, kMaxShift = 12, kLightSize = 300, kLightAlpha = 0.1;
static const CFTimeInterval kLightIn = 0.12, kLightOut = 0.22;
static NSString *const kTransformKey = @"sg.glasstouch";

const SGSpring SGGlassLiftOn = {1.36, 568.0, 39.7};
const SGSpring SGGlassLiftOff = {2.0, 460.0, 21.8};

// Ease in and out over 0...1.
static CGFloat SGSmooth(CGFloat t) { return t * t * (3 - 2 * t); }

@interface SGGlassTouchRecognizer : UIGestureRecognizer <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *pane;
// The view that moves, when it is not the one that takes the touches (the player's mod button over the ⋯).
@property (nonatomic, weak) UIView *target;
@end

@implementation SGGlassTouchRecognizer {
    UITouch *_touch;
    // The scroll views the touch is in, whose pan ends the press when it takes the touch.
    NSArray<UIScrollView *> *_scrolls;
    CGPoint _start;
    CGPoint _shift;
    CAGradientLayer *_light;
}

- (instancetype)init {
    if (!(self = [super initWithTarget:nil action:NULL])) return nil;
    self.delegate = self;
    // Watches only: the control under it gets every touch as if this were not there.
    self.cancelsTouchesInView = NO;
    self.delaysTouchesBegan = NO;
    self.delaysTouchesEnded = NO;
    return self;
}

- (BOOL)canPrevent:(UIGestureRecognizer *)other { return NO; }
- (BOOL)canBePrevented:(UIGestureRecognizer *)other { return NO; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

- (UIView *)subject { return self.target ?: self.view; }

#pragma mark light

- (CAGradientLayer *)light {
    if (_light) return _light;
    CAGradientLayer *layer = [CAGradientLayer layer];
    layer.type = kCAGradientLayerRadial;
    layer.startPoint = CGPointMake(0.5, 0.5);
    layer.endPoint = CGPointMake(1, 1);
    // Full at the middle, half at half the radius, none at the edge, eased in between.
    NSMutableArray *colors = [NSMutableArray arrayWithObject:(id)UIColor.whiteColor.CGColor];
    NSMutableArray *locations = [NSMutableArray arrayWithObject:@0];
    for (int i = 0; i < 7; i++) {
        CGFloat step = i / 6.0;
        [colors addObject:(id)[UIColor colorWithWhite:1 alpha:0.5 * (1 - SGSmooth(step))].CGColor];
        [locations addObject:@(0.5 + 0.5 * step)];
    }
    layer.colors = colors;
    layer.locations = locations;
    layer.bounds = CGRectMake(0, 0, kLightSize, kLightSize);
    layer.opacity = 0;
    layer.zPosition = 50;   // under the rim's highlight (100), over the backdrop
    layer.actions = @{@"position": NSNull.null, @"bounds": NSNull.null, @"opacity": NSNull.null};
    _light = layer;
    return layer;
}

- (void)showLight:(BOOL)shown at:(CGPoint)point animated:(BOOL)animated {
    UIView *pane = self.pane;
    if (!pane) return;
    CAGradientLayer *light = [self light];
    if (light.superlayer != pane.layer) [pane.layer addSublayer:light];
    if (shown || light.opacity > 0) light.position = point;
    float target = shown ? kLightAlpha : 0;
    if (animated) {
        CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
        fade.fromValue = @((light.presentationLayer ?: light).opacity);
        fade.toValue = @(target);
        fade.duration = shown ? kLightIn : kLightOut;
        fade.timingFunction = [CAMediaTimingFunction functionWithName:shown ? kCAMediaTimingFunctionEaseOut : kCAMediaTimingFunctionEaseInEaseOut];
        light.opacity = target;
        [light addAnimation:fade forKey:@"opacity"];
    } else {
        light.opacity = target;
    }
}

#pragma mark movement

// The press: grown by kGrow along the longer side and, once the finger moves, stretched along the move and
// squeezed across it, with the middle shifted toward the finger by less and less.
- (CATransform3D)transformTracking:(BOOL)tracking {
    UIView *host = [self subject];
    if (!tracking || !host || UIAccessibilityIsReduceMotionEnabled()) return CATransform3DIdentity;
    CGFloat w = MAX(1, host.bounds.size.width), h = MAX(1, host.bounds.size.height), aspect = w / h;
    CGFloat base = MIN(1 + kGrow / (w < h ? h : w), kMaxGrowScale);
    CGFloat dx = _shift.x / aspect, length = hypot(dx, _shift.y);
    if (length == 0) return CATransform3DMakeScale(base, base, 1);
    CGFloat nx = dx / length, ny = _shift.y / length;
    CGFloat k = 1 - 1 / ((length / h) / (5 * aspect) + 1);
    CGFloat t = ((h + 16 / aspect) / h - 1) * k * aspect;
    CGFloat diff = fabs(fabs(nx) - fabs(ny));
    BOOL horizontal = fabs(nx) > fabs(ny);
    CATransform3D m = CATransform3DIdentity;
    m.m11 = base * (horizontal ? 1 + t * diff : 1 / (1 + t * diff));
    m.m22 = base * (horizontal ? 1 / (1 + t * diff) : 1 + t * diff);
    m.m41 = nx * kMaxShift * k;
    m.m42 = ny * kMaxShift * k;
    return m;
}

- (void)applyTracking:(BOOL)tracking springy:(BOOL)springy {
    UIView *host = [self subject];
    if (!host) return;
    CALayer *layer = host.layer;
    CATransform3D target = [self transformTracking:tracking];
    if (!springy || UIAccessibilityIsReduceMotionEnabled()) {
        [layer removeAnimationForKey:kTransformKey];
        layer.sublayerTransform = target;
        return;
    }
    SGSpring spring = tracking ? SGGlassLiftOn : SGGlassLiftOff;
    CASpringAnimation *animation = [CASpringAnimation animationWithKeyPath:@"sublayerTransform"];
    animation.fromValue = [NSValue valueWithCATransform3D:(layer.presentationLayer ?: layer).sublayerTransform];
    animation.toValue = [NSValue valueWithCATransform3D:target];
    animation.mass = spring.mass;
    animation.stiffness = spring.stiffness;
    animation.damping = spring.damping;
    animation.initialVelocity = 0;
    animation.duration = animation.settlingDuration;
    layer.sublayerTransform = target;
    [layer addAnimation:animation forKey:kTransformKey];
}

#pragma mark touches

- (void)finish {
    if (!_touch) return;
    _touch = nil;
    _scrolls = nil;
    _shift = CGPointZero;
    [self applyTracking:NO springy:YES];
    [self showLight:NO at:CGPointZero animated:YES];
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIView *host = [self subject];
    if (_touch || !host) return;
    _touch = touches.anyObject;
    NSMutableArray<UIScrollView *> *scrolls = [NSMutableArray array];
    for (UIView *v = host.superview; v; v = v.superview) if ([v isKindOfClass:UIScrollView.class]) [scrolls addObject:(UIScrollView *)v];
    _scrolls = scrolls;
    _start = [_touch locationInView:host];
    _shift = CGPointZero;
    [self applyTracking:YES springy:YES];
    if (self.pane) [self showLight:YES at:[_touch locationInView:self.pane] animated:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UIView *host = [self subject];
    if (!_touch || !host || ![touches containsObject:_touch]) return;
    // A scroll that starts on the control takes the touch: the press is over, as a button's is, and the glass does not
    // follow the finger down the page.
    for (UIScrollView *scroll in _scrolls) {
        UIGestureRecognizerState pan = scroll.panGestureRecognizer.state;
        if (pan == UIGestureRecognizerStateBegan || pan == UIGestureRecognizerStateChanged) {
            [self finish];
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
    }
    CGPoint point = [_touch locationInView:host];
    _shift = CGPointMake(point.x - _start.x, point.y - _start.y);
    [self applyTracking:YES springy:NO];
    if (self.pane) [self showLight:YES at:[_touch locationInView:self.pane] animated:NO];
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

// On a host whose press comes through another view (SGGlassInteractiveVia): that view's recognizer, which is the one,
// held weakly (it lives on that view).
@interface SGGlassTouchVia : NSObject
@property (nonatomic, weak) SGGlassTouchRecognizer *recognizer;
@end
@implementation SGGlassTouchVia
@end

static char kViaKey;

void SGGlassInteractive(UIView *host, UIView *pane) {
    SGGlassTouchRecognizer *via = ((SGGlassTouchVia *)objc_getAssociatedObject(host, &kViaKey)).recognizer;
    if (via) {
        via.pane = pane;
        return;
    }
    SGGlassInteractiveVia(host, host, pane);
}

void SGGlassInteractiveVia(UIView *touched, UIView *host, UIView *pane) {
    if (!touched || !host || !pane) return;
    // Not on iOS 26 or later (the system's glass), and not on a plain blur.
    if (!SGUseLegacyGlass()) return;
    SGGlassTouchRecognizer *recognizer = objc_getAssociatedObject(touched, &kRecognizerKey);
    if (!recognizer) {
        recognizer = [SGGlassTouchRecognizer new];
        objc_setAssociatedObject(touched, &kRecognizerKey, recognizer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [touched addGestureRecognizer:recognizer];
    }
    recognizer.pane = pane;
    recognizer.target = host == touched ? nil : host;
    if (host == touched) return;
    // One press for the host: the touches reach its own recognizer too (`touched` is a subview of it, the player's ⋯),
    // which would add a second light and a second spring on the same transform.
    SGGlassTouchRecognizer *own = objc_getAssociatedObject(host, &kRecognizerKey);
    if (own) {
        [own.view removeGestureRecognizer:own];
        objc_setAssociatedObject(host, &kRecognizerKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    SGGlassTouchVia *via = [SGGlassTouchVia new];
    via.recognizer = recognizer;
    objc_setAssociatedObject(host, &kViaKey, via, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
