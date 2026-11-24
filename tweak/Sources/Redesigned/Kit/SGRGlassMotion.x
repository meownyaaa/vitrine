#import "SGRGlassMotion.h"
#import "Core/SGCore.h"
#import "SGRTokens.h"
#import "SGRedesign.h"

// How long a noted control waits for what replaces it: the two are shown and hidden in one pass of Spotify's, a turn of
// the run loop apart at most, and a morph from a control that went long ago would fly from nowhere.
static const CFTimeInterval kLeavingLife = 0.4;
// The shape's spring and its fade (as on iOS 26: the new controls are whole about 0.2 s after the tap, settled by 0.35).
static const NSTimeInterval kMorphDuration = 0.38, kMorphFadeDelay = 0.2, kMorphFadeDuration = 0.16;
static const CGFloat kMorphDamping = 0.8;
// The arriving control's own drawing comes in under the shape, from a little smaller.
static const NSTimeInterval kArriveDelay = 0.08, kArriveDuration = 0.22;
static const CGFloat kArriveScale = 0.9;
// A bar's controls, one after another.
static const NSTimeInterval kBarStagger = 0.04;
static const CGFloat kBarScale = 0.86;

// The bubble: the drop leaves the control at most this big across and grows to this share of the menu's shorter side as
// it flies, then opens out this far past the menu's edge before it settles. The flight takes the first share of the time
// and the opening out reaches past the edge at the second: about 0.4 s in all, as on iOS 26. The circle stays a circle
// a little longer and opens out further past the edge than iOS 26's timings alone give, since with a small overshoot
// and a quick flight the menu reads as fading in.
static const CGFloat kBubbleMinDrop = 30, kBubbleMaxDrop = 56, kBubbleGrowShare = 0.55, kBubbleOvershoot = 9;
static const NSTimeInterval kBubbleDuration = 0.5, kBubbleRowsDelay = 0.16;
static const double kBubbleFlightShare = 0.46, kBubblePastShare = 0.78;
static const CGFloat kBubbleRowsScale = 0.94;
// A touch counts as where a menu came from for this long; a control bigger than this is a row or a page, and the
// drop leaves from the finger instead.
static const CFTimeInterval kTouchLife = 1.0;
static const CGSize kControlMax = {140, 80};

static CGRect sLeavingRect;
static CGFloat sLeavingRadius;
static CFTimeInterval sLeavingAt;

static BOOL motionOn(void) {
    if (@available(iOS 26.0, *)) return NO;
    return SGUseLegacyGlass() && !SGRReduceMotion();
}

static BOOL onScreen(UIView *view) {
    return view.window && !view.hidden && view.alpha > 0.01 && view.bounds.size.width >= 1 && view.bounds.size.height >= 1;
}

// The corners a control is drawn with: its layer's, or a capsule's when it has none.
static CGFloat radiusOf(UIView *view) {
    CGFloat half = view.bounds.size.height / 2;
    CGFloat radius = view.layer.cornerRadius;
    return radius > 0 ? MIN(radius, half) : half;
}

// Fades `layer` in from nothing and grows it from `scale`, by animations of its own: the model stays as it is.
static void arrive(CALayer *layer, CFTimeInterval delay, CGFloat scale) {
    CFTimeInterval start = [layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0;
    fade.toValue = @(layer.opacity);
    fade.duration = kArriveDuration;
    fade.beginTime = start;
    fade.fillMode = kCAFillModeBackwards;
    fade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    [layer addAnimation:fade forKey:@"sgr.arrive.fade"];
    CASpringAnimation *grow = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
    grow.fromValue = @(scale);
    grow.toValue = @1;
    grow.stiffness = 320;
    grow.damping = 26;
    grow.duration = grow.settlingDuration;
    grow.beginTime = start;
    grow.fillMode = kCAFillModeBackwards;
    [layer addAnimation:grow forKey:@"sgr.arrive.grow"];
}

void SGRGlassNoteLeaving(UIView *view) {
    if (!motionOn() || !onScreen(view)) return;
    sLeavingRect = [view convertRect:view.bounds toView:nil];
    sLeavingRadius = radiusOf(view);
    sLeavingAt = CACurrentMediaTime();
}

void SGRGlassMorphFromLeaving(UIView *to, SGRGlassMaker glass) {
    if (!motionOn() || !to || !glass || !sLeavingAt || CACurrentMediaTime() - sLeavingAt > kLeavingLife) return;
    CGRect start = sLeavingRect;
    CGFloat startRadius = sLeavingRadius;
    sLeavingAt = 0;
    // Spotify lays the header out after it has shown and hidden its controls: the shape ends where that puts `to`.
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = to.window;
        if (!onScreen(to)) return;
        [window layoutIfNeeded];
        CGRect end = [to convertRect:to.bounds toView:nil];
        if (CGRectEqualToRect(CGRectIntegral(start), CGRectIntegral(end))) return;
        CGFloat endRadius = radiusOf(to);

        UIView *shape = [[UIView alloc] initWithFrame:start];
        shape.userInteractionEnabled = NO;
        shape.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        shape.clipsToBounds = YES;
        shape.layer.cornerRadius = startRadius;
        shape.layer.cornerCurve = kCACornerCurveContinuous;
        UIView *pane = glass(shape);
        if (!pane) return;
        // The pane is as big as the larger of the two shapes and kept in the middle of the moving one, which clips it:
        // resized with it, it would take its new size at once and leave the shape bare while it grows.
        pane.autoresizingMask = UIViewAutoresizingNone;
        pane.bounds = CGRectMake(0, 0, MAX(start.size.width, end.size.width), MAX(start.size.height, end.size.height));
        pane.center = CGPointMake(start.size.width / 2, start.size.height / 2);
        SGShapeGlass(pane, MIN(startRadius, endRadius), NO);
        [window addSubview:shape];

        arrive(to.layer, kArriveDelay, kArriveScale);
        [UIView animateWithDuration:kMorphDuration delay:0 usingSpringWithDamping:kMorphDamping initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            shape.frame = end;
            shape.layer.cornerRadius = endRadius;
            pane.center = CGPointMake(end.size.width / 2, end.size.height / 2);
        } completion:nil];
        [UIView animateWithDuration:kMorphFadeDuration delay:kMorphFadeDelay options:UIViewAnimationOptionCurveEaseOut
                         animations:^{ shape.alpha = 0; }
                         completion:^(BOOL finished) { [shape removeFromSuperview]; }];
    });
}

// The controls of a bar: the UIControls in it, outermost first, in the order they read.
static void collectControls(UIView *view, NSMutableArray<UIView *> *into, int depth) {
    if (depth > 6 || !onScreen(view)) return;
    if ([view isKindOfClass:UIControl.class] && depth > 0) {
        [into addObject:view];
        return;
    }
    for (UIView *sub in view.subviews) collectControls(sub, into, depth + 1);
}

void SGRGlassBarAppear(UIView *bar) {
    if (!motionOn() || !bar) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!onScreen(bar)) return;
        [bar layoutIfNeeded];
        NSMutableArray<UIView *> *controls = [NSMutableArray array];
        collectControls(bar, controls, 0);
        if (!controls.count) {
            arrive(bar.layer, 0, kBarScale);
            return;
        }
        [controls sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat ax = [a convertPoint:CGPointZero toView:nil].x, bx = [b convertPoint:CGPointZero toView:nil].x;
            return ax < bx ? NSOrderedAscending : ax > bx ? NSOrderedDescending : NSOrderedSame;
        }];
        [controls enumerateObjectsUsingBlock:^(UIView *control, NSUInteger i, BOOL *stop) {
            arrive(control.layer, i * kBarStagger, kBarScale);
        }];
    });
}

#pragma mark - the bubble

static CGRect sTouchRect;
static CFTimeInterval sTouchAt;

// A rounded rect as Core Graphics draws one, whatever its corners: every path of the bubble has the same elements, so
// Core Animation can move one into the next. The corners are kept under half the shorter side, which it refuses.
static CGPathRef roundedPath(CGRect rect, CGFloat radius) {
    CGFloat most = MAX(0, MIN(rect.size.width, rect.size.height) / 2 - 0.01);
    CGFloat r = MAX(0, MIN(radius, most));
    return CGPathCreateWithRoundedRect(rect, r, r, NULL);
}

static CGRect around(CGPoint middle, CGFloat side) {
    return CGRectMake(middle.x - side / 2, middle.y - side / 2, side, side);
}

// The first view of `kind` inside `view`, a few levels down.
static UIView *firstOf(UIView *view, Class kind, int depth) {
    if (depth > 6) return nil;
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:kind]) return sub;
        UIView *found = firstOf(sub, kind, depth + 1);
        if (found) return found;
    }
    return nil;
}

// A view's shadow drawn by a view of its own beside the body (the menu's _UICutoutShadowView, a popover's shadow): it
// reaches past the body's bounds, where a mask on the whole would cut it off until the mask came off at the end, and the
// shadow then appeared at once, after the menu was whole.
static BOOL isShadow(UIView *view) {
    return [NSStringFromClass(view.class) containsString:@"Shadow"];
}

// `paths` (in `target`'s space) played over `target` at `keyTimes`: a mask on it, or, when it holds a shadow of its own,
// one on each of its other views, the shadow faded in as the shape nears its end instead. The masks come off at the end.
static void playShape(UIView *target, NSArray *paths, NSArray<NSNumber *> *keyTimes, NSArray<CAMediaTimingFunction *> *timing,
                      NSTimeInterval duration) {
    NSMutableArray<UIView *> *bodies = [NSMutableArray array], *shadows = [NSMutableArray array];
    for (UIView *sub in target.subviews) [isShadow(sub) ? shadows : bodies addObject:sub];
    if (!shadows.count) bodies = [NSMutableArray arrayWithObject:target];
    NSMutableArray<CAShapeLayer *> *masks = [NSMutableArray array];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        [bodies enumerateObjectsUsingBlock:^(UIView *body, NSUInteger i, BOOL *stop) {
            if (i < masks.count && body.layer.mask == masks[i]) body.layer.mask = nil;
        }];
    }];
    for (UIView *body in bodies) {
        CGPoint origin = body == target ? CGPointZero : body.frame.origin;
        CGAffineTransform shift = CGAffineTransformMakeTranslation(-origin.x, -origin.y);
        NSMutableArray *values = [NSMutableArray array];
        for (id path in paths) {
            CGPathRef moved = CGPathCreateCopyByTransformingPath((__bridge CGPathRef)path, &shift);
            [values addObject:(__bridge_transfer id)moved];
        }
        CAShapeLayer *mask = [CAShapeLayer layer];
        mask.frame = body.bounds;
        mask.path = (__bridge CGPathRef)values.lastObject;
        CAKeyframeAnimation *shape = [CAKeyframeAnimation animationWithKeyPath:@"path"];
        shape.values = values;
        shape.keyTimes = keyTimes;
        shape.timingFunctions = timing;
        shape.duration = duration;
        body.layer.mask = mask;
        [mask addAnimation:shape forKey:@"sgr.bubble"];
        [masks addObject:mask];
    }
    for (UIView *shadow in shadows) {
        CAKeyframeAnimation *fade = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
        fade.values = @[@0, @0, @(shadow.layer.opacity)];
        fade.keyTimes = @[@0, @(kBubbleFlightShare), @1];
        fade.duration = duration;
        [shadow.layer addAnimation:fade forKey:@"sgr.bubble.shadow"];
    }
    [CATransaction commit];
}

void SGRGlassBubbleOpen(UIView *target, CGFloat targetRadius) {
    if (!motionOn() || !target || !sTouchAt || CACurrentMediaTime() - sTouchAt > kTouchLife) return;
    CGRect source = sTouchRect;
    sTouchAt = 0;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!onScreen(target) || target.layer.mask) return;
        [target.window layoutIfNeeded];
        CGRect bounds = target.bounds;
        if (bounds.size.width < 1 || bounds.size.height < 1) return;
        CGFloat drop = MAX(kBubbleMinDrop, MIN(kBubbleMaxDrop, MIN(source.size.width, source.size.height)));
        CGFloat grown = MAX(drop, MIN(bounds.size.width, bounds.size.height) * kBubbleGrowShare);
        CGPoint from = [target convertPoint:CGPointMake(CGRectGetMidX(source), CGRectGetMidY(source)) fromView:nil];
        CGPoint middle = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));

        // The menu itself is the bubble, as iOS 26's is: a mask cut from it starts as a drop over the button, flies to
        // its middle growing as a circle, and opens out into its shape a little past it before it settles. Its glass and
        // its rows show through the whole way. A drop of glass laid over the menu instead hid it until the end and read
        // as a flat disc of the page's colour.
        NSArray *paths = @[
            (__bridge_transfer id)roundedPath(around(from, drop), drop / 2),
            (__bridge_transfer id)roundedPath(around(middle, grown), grown / 2),
            (__bridge_transfer id)roundedPath(CGRectInset(bounds, -kBubbleOvershoot, -kBubbleOvershoot), targetRadius + kBubbleOvershoot),
            (__bridge_transfer id)roundedPath(bounds, targetRadius),
        ];
        playShape(target, paths, @[@0, @(kBubbleFlightShare), @(kBubblePastShare), @1], @[
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut],
            [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
        ], kBubbleDuration);
        // The rows come in as the drop opens, a little smaller first.
        UIView *rows = firstOf(target, UICollectionView.class, 0);
        if (rows) arrive(rows.layer, kBubbleRowsDelay, kBubbleRowsScale);
    });
}

// Where the last touch went down, for the bubble: the control under it, or a drop at the finger.
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        UITouch *touch = event.allTouches.anyObject;
        if (touch.phase == UITouchPhaseBegan) {
            UIView *view = touch.view;
            CGRect rect = view ? [view convertRect:view.bounds toView:nil] : CGRectZero;
            if (!view || rect.size.width > kControlMax.width || rect.size.height > kControlMax.height) {
                CGPoint at = [touch locationInView:nil];
                rect = CGRectMake(at.x - 22, at.y - 22, 44, 44);
            }
            sTouchRect = rect;
            sTouchAt = CACurrentMediaTime();
        }
    }
    %orig;
}
%end

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init;
}
