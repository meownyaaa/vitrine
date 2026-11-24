// Colored progress-bar segment overlay for SponsorBlock segments.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "SGSponsorBlockOverlay.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockSkipper.h"
#import "Core/SGCore.h"

static const CGFloat kMinTrackHeight = 2.0;
static const CGFloat kMaxTrackHeight = 16.0;
static const CGFloat kDefaultTrackHeight = 7.0;
static const CGFloat kExpandedTrackHeight = 12.0;
static const CGFloat kLegacyTrackInset = 3.0;
static const CGFloat kTrackSearchMaxMidYDelta = 16.0;
enum {
    kMaxSearchDepth = 14,
    kMaxDescendantDepth = 6,
    kMaxCandidates = 64,
    kMaxPostLayoutRetries = 3,
};

@interface SGSponsorBlockSegmentBar : UIView
@property (nonatomic) CGFloat startRatio;
@property (nonatomic) CGFloat endRatio;
@end

@implementation SGSponsorBlockSegmentBar
@end

@interface SGSponsorBlockOverlayContainer : UIView
@property (nonatomic, copy) NSString *cachedEpisodeID;
@property (nonatomic) double cachedDuration;
@property (nonatomic) NSArray<SGSponsorBlockSegment *> *cachedRawSegments;
@property (nonatomic) BOOL needsRebuild;
@property (nonatomic) BOOL didScanSubviews;
@property (nonatomic) BOOL usedRenderedTrack;
@property (nonatomic) BOOL lastHighlighted;
@property (nonatomic) BOOL pendingPostLayout;
@property (nonatomic) NSUInteger postLayoutRetries;
@property (nonatomic) BOOL hasLastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredMidY;
@property (nonatomic) CGFloat lastMeasuredBoundsHeight;
@property (nonatomic) CGRect lastPostLayoutBounds;
@property (nonatomic) CGRect cachedTrackFrame;
@property (nonatomic) CGRect lastSliderBounds;
@property (nonatomic) BOOL hasCachedTrackFrame;
@property (nonatomic, weak) UIView *cachedTrackView;
@property (nonatomic, weak) UIView *cachedVisualElement;
- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame;
- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame;
@end

@implementation SGSponsorBlockOverlayContainer

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil;
}

- (void)applyTrackFrame:(CGRect)trackFrame {
    self.frame = trackFrame;
    CGFloat trackHeight = trackFrame.size.height;
    self.layer.cornerRadius = trackHeight / 2.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
}

- (void)layoutSegmentBar:(SGSponsorBlockSegmentBar *)bar
              trackWidth:(CGFloat)trackWidth
             trackHeight:(CGFloat)trackHeight {
    CGFloat x = bar.startRatio * trackWidth;
    CGFloat segWidth = MAX(2.0, (bar.endRatio - bar.startRatio) * trackWidth);
    if (x + segWidth > trackWidth) {
        segWidth = MAX(1.0, trackWidth - x);
    }
    bar.frame = CGRectMake(x, 0, segWidth, trackHeight);
}

- (void)rebuildWithSegments:(NSArray<SGSponsorBlockSegment *> *)segments
                   duration:(double)duration
                  episodeID:(NSString *)episodeID
                 trackFrame:(CGRect)trackFrame {
    _cachedEpisodeID = [episodeID copy];
    _cachedDuration = duration;
    _needsRebuild = NO;

    for (UIView *subview in [self.subviews copy]) {
        [subview removeFromSuperview];
    }

    [self applyTrackFrame:trackFrame];

    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;

    for (SGSponsorBlockSegment *seg in segments) {
        CGFloat startRatio = (CGFloat)(seg.start / duration);
        CGFloat endRatio = (CGFloat)(seg.end / duration);
        if (startRatio < 0.0) startRatio = 0.0;
        if (endRatio > 1.0) endRatio = 1.0;
        if (endRatio <= startRatio) continue;

        SGSponsorBlockSegmentBar *bar = [SGSponsorBlockSegmentBar new];
        bar.startRatio = startRatio;
        bar.endRatio = endRatio;
        UIColor *catColor = SGSponsorBlockCategoryColor(seg.category);
        bar.backgroundColor = [catColor colorWithAlphaComponent:0.65];
        bar.userInteractionEnabled = NO;
        [self layoutSegmentBar:bar trackWidth:trackWidth trackHeight:trackHeight];
        [self addSubview:bar];
    }
}

- (void)layoutSegmentsForTrackFrame:(CGRect)trackFrame {
    [self applyTrackFrame:trackFrame];
    CGFloat trackWidth = trackFrame.size.width;
    CGFloat trackHeight = trackFrame.size.height;
    if (trackWidth <= 0 || trackHeight <= 0) return;

    for (UIView *sv in self.subviews) {
        if (![sv isKindOfClass:[SGSponsorBlockSegmentBar class]]) continue;
        [self layoutSegmentBar:(SGSponsorBlockSegmentBar *)sv trackWidth:trackWidth trackHeight:trackHeight];
    }
}

@end

static NSHashTable<UIView *> *s_trackedSliders = nil;

@implementation SGSponsorBlockOverlay

+ (void)initialize {
    if (self == [SGSponsorBlockOverlay class]) {
        s_trackedSliders = [NSHashTable weakObjectsHashTable];
    }
}

+ (void)attachToSlider:(UIView *)slider {
    if (!slider) return;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attachToSlider:slider];
        });
        return;
    }
    [s_trackedSliders addObject:slider];
    [self updateSlider:slider animateHeightChange:NO];
}

+ (void)refreshAll {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self refreshAll];
        });
        return;
    }
    for (UIView *slider in s_trackedSliders.allObjects) {
        for (UIView *sv in slider.subviews) {
            if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
                ((SGSponsorBlockOverlayContainer *)sv).needsRebuild = YES;
            }
        }
        [self updateSlider:slider animateHeightChange:NO];
    }
}

static BOOL isFiniteRect(CGRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y) &&
           isfinite(r.size.width) && isfinite(r.size.height);
}

static BOOL isVisualElementView(UIView *view) {
    if (!view) return NO;
    NSString *name = NSStringFromClass(view.class);
    return [name isEqualToString:@"_UISlideriOSVisualElement"] ||
           [name isEqualToString:@"_UISliderFluidVisualElement"];
}

static BOOL isFluidSlider(UIView *visualElement) {
    if (visualElement && [NSStringFromClass(visualElement.class) isEqualToString:@"_UISliderFluidVisualElement"]) {
        return YES;
    }
    // iOS 26+ UISlider keeps _UISlideriOSVisualElement for Liquid Glass fluid tracks.
    return !SGBelowiOS26();
}

static BOOL isThumbClass(Class cls) {
    if (!cls) return NO;
    NSString *name = NSStringFromClass(cls);
    return [name isEqualToString:@"_UISliderThumbView"] ||
           [name isEqualToString:@"UISliderThumbView"];
}

static BOOL isThumbLayer(CALayer *layer) {
    if (!layer) return NO;
    if ([layer.delegate isKindOfClass:UIView.class] && isThumbClass(((UIView *)layer.delegate).class)) {
        return YES;
    }
    if (isThumbClass(layer.class)) return YES;
    NSString *name = layer.name;
    return name.length > 0 &&
           ([name isEqualToString:@"Thumb"] ||
            [name isEqualToString:@"_UISliderThumbView"]);
}

static BOOL isColorVisible(CGColorRef color) {
    return color != NULL && CGColorGetAlpha(color) > 0.01;
}

static BOOL isDirectRenderedLayer(CALayer *layer) {
    if (!layer || layer.hidden || layer.opacity <= 0.01) return NO;
    if (isColorVisible(layer.backgroundColor) || layer.contents != nil) return YES;
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (shape.path != NULL && (isColorVisible(shape.fillColor) || isColorVisible(shape.strokeColor))) {
            return YES;
        }
    }
    if ([layer isKindOfClass:CAGradientLayer.class] && ((CAGradientLayer *)layer).colors.count > 0) {
        return YES;
    }
    if (layer.borderWidth > 0.25 && isColorVisible(layer.borderColor)) {
        return YES;
    }
    if (layer.compositingFilter != nil || layer.filters.count > 0 || layer.backgroundFilters.count > 0) {
        return YES;
    }
    Class backdropCls = NSClassFromString(@"CABackdropLayer");
    if (backdropCls && [layer isKindOfClass:backdropCls]) return YES;
    Class portalCls = NSClassFromString(@"CAPortalLayer");
    if (portalCls && [layer isKindOfClass:portalCls]) return YES;
    return NO;
}

static BOOL hasRenderedDescendantLayer(CALayer *layer, NSUInteger depth) {
    if (!layer || depth > kMaxDescendantDepth) return NO;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        if (isDirectRenderedLayer(sub)) return YES;
        if ([sub.delegate isKindOfClass:UIVisualEffectView.class]) return YES;
        if (hasRenderedDescendantLayer(sub, depth + 1)) return YES;
    }
    return NO;
}

static BOOL hasRenderedLayerContent(CALayer *layer, BOOL *isSolidOut) {
    if (isSolidOut) *isSolidOut = NO;
    if (!layer || layer.hidden || layer.opacity <= 0.01) return NO;
    if (isDirectRenderedLayer(layer)) {
        if (isSolidOut) {
            *isSolidOut = (isColorVisible(layer.backgroundColor) ||
                           layer.contents != nil ||
                           [layer isKindOfClass:CAShapeLayer.class] ||
                           [layer isKindOfClass:CAGradientLayer.class]);
        }
        return YES;
    }
    CGFloat h = layer.bounds.size.height;
    if (((layer.masksToBounds && h >= kMinTrackHeight && h <= kMaxTrackHeight &&
          layer.cornerRadius >= MAX(1.5, h * 0.35)) ||
         (layer.mask != nil && !layer.mask.hidden && layer.mask.opacity > 0.01)) &&
        hasRenderedDescendantLayer(layer, 0)) {
        return YES;
    }
    return NO;
}

static BOOL hasRenderedTrackContent(UIView *view, BOOL *isSolidOut) {
    if (isSolidOut) *isSolidOut = NO;
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image != nil) {
        if (isSolidOut) *isSolidOut = YES;
        return YES;
    }
    if ([view isKindOfClass:UIVisualEffectView.class]) {
        return YES;
    }
    if (view.backgroundColor && isColorVisible(view.backgroundColor.CGColor)) {
        if (isSolidOut) *isSolidOut = YES;
        return YES;
    }
    return hasRenderedLayerContent(view.layer, isSolidOut);
}

static CGRect intersectOptionalClip(CGRect rect, CGRect clipRect) {
    if (CGRectIsNull(rect) || !isFiniteRect(rect)) return CGRectNull;
    if (CGRectIsNull(clipRect)) return rect;
    return CGRectIntersection(rect, clipRect);
}

static CGRect layerMaskRectInSlider(CALayer *mask, CALayer *ownerLayer, CALayer *sliderLayer) {
    if (!mask || !ownerLayer || !sliderLayer || mask.hidden || mask.opacity <= 0.01) return CGRectNull;
    CGRect maskBounds = mask.bounds;
    CGRect maskFrame = mask.frame;
    if (!isFiniteRect(maskBounds) || !isFiniteRect(maskFrame) ||
        maskFrame.size.width <= 0 || maskFrame.size.height <= 0) {
        return CGRectNull;
    }
    CGRect inOwner = maskFrame;
    if ([mask isKindOfClass:CAShapeLayer.class] &&
        maskBounds.size.width > 0 && maskBounds.size.height > 0) {
        CAShapeLayer *shape = (CAShapeLayer *)mask;
        if (shape.path != NULL) {
            CGRect pathBox = CGPathGetPathBoundingBox(shape.path);
            if (isFiniteRect(pathBox) && pathBox.size.width > 0 && pathBox.size.height > 0) {
                CGFloat sx = maskFrame.size.width / maskBounds.size.width;
                CGFloat sy = maskFrame.size.height / maskBounds.size.height;
                inOwner = CGRectMake(maskFrame.origin.x + (pathBox.origin.x - maskBounds.origin.x) * sx,
                                     maskFrame.origin.y + (pathBox.origin.y - maskBounds.origin.y) * sy,
                                     pathBox.size.width * sx,
                                     pathBox.size.height * sy);
            }
        }
    }
    CGRect converted = [sliderLayer convertRect:inOwner fromLayer:ownerLayer];
    return isFiniteRect(converted) ? converted : CGRectNull;
}

static CGRect applyMaskAndClip(CGRect r, CALayer *layer, CALayer *sliderLayer, CGRect activeClip) {
    if (CGRectIsNull(r) || !isFiniteRect(r)) return CGRectNull;
    if (layer.mask) {
        CGRect maskInSlider = layerMaskRectInSlider(layer.mask, layer, sliderLayer);
        if (!CGRectIsNull(maskInSlider)) {
            r = intersectOptionalClip(r, maskInSlider);
        }
    }
    return intersectOptionalClip(r, activeClip);
}

static CGRect nextClipRectForLayer(CALayer *layer, CALayer *sliderLayer, CGRect activeClip) {
    CGRect next = activeClip;
    if (!layer || !sliderLayer) return next;
    if (layer.masksToBounds && isFiniteRect(layer.bounds) &&
        layer.bounds.size.width > 0 && layer.bounds.size.height > 0) {
        CGRect boundsInSlider = [sliderLayer convertRect:layer.bounds fromLayer:layer];
        next = intersectOptionalClip(boundsInSlider, next);
    }
    if (layer.mask) {
        CGRect maskInSlider = layerMaskRectInSlider(layer.mask, layer, sliderLayer);
        if (!CGRectIsNull(maskInSlider)) {
            next = intersectOptionalClip(maskInSlider, next);
        }
    }
    return next;
}

static CGRect renderedRectForLayer(CALayer *layer, CALayer *sliderLayer, CGRect activeClip) {
    if (!layer || !sliderLayer) return CGRectNull;
    CGRect localRect = layer.bounds;
    if ([layer isKindOfClass:CAShapeLayer.class]) {
        CAShapeLayer *shape = (CAShapeLayer *)layer;
        if (shape.path != NULL && (isColorVisible(shape.fillColor) || isColorVisible(shape.strokeColor))) {
            CGRect pathBox = CGPathGetPathBoundingBox(shape.path);
            if (!isColorVisible(shape.fillColor) && isColorVisible(shape.strokeColor) && shape.lineWidth > 0) {
                pathBox = CGRectInset(pathBox, -shape.lineWidth / 2.0, -shape.lineWidth / 2.0);
            }
            if (isFiniteRect(pathBox) && pathBox.size.width > 0 && pathBox.size.height > 0) {
                if (layer.masksToBounds && isFiniteRect(localRect) &&
                    localRect.size.width > 0 && localRect.size.height > 0) {
                    localRect = CGRectIntersection(localRect, pathBox);
                } else {
                    localRect = pathBox;
                }
            }
        }
    }
    if (CGRectIsNull(localRect) || !isFiniteRect(localRect)) return CGRectNull;
    return applyMaskAndClip([sliderLayer convertRect:localRect fromLayer:layer], layer, sliderLayer, activeClip);
}

static CGRect renderedTrackRectForSubview(UIView *sub, UIView *slider, CGRect activeClip) {
    if ([sub.layer isKindOfClass:CAShapeLayer.class]) {
        return renderedRectForLayer(sub.layer, slider.layer, activeClip);
    }
    CGRect r = [slider convertRect:sub.bounds fromView:sub];
    if ([sub isKindOfClass:UIImageView.class]) {
        UIImage *img = ((UIImageView *)sub).image;
        CGFloat boundsH = sub.bounds.size.height;
        if (img && img.size.height > 0 && boundsH > 0 && img.size.height < boundsH - 0.5 &&
            (sub.contentMode == UIViewContentModeCenter || sub.contentMode == UIViewContentModeScaleAspectFit)) {
            CGFloat scaledH = img.size.height * (r.size.height / boundsH);
            r.origin.y = CGRectGetMidY(r) - scaledH / 2.0;
            r.size.height = scaledH;
        }
    }
    return applyMaskAndClip(r, sub.layer, slider.layer, activeClip);
}

static CGRect superTrackRectForSlider(UISlider *slider, CGRect bounds) {
    typedef CGRect (*TrackRectIMP)(id, SEL, CGRect);
    static TrackRectIMP s_uiSliderTrackRect = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        IMP imp = class_getMethodImplementation(UISlider.class, @selector(trackRectForBounds:));
        s_uiSliderTrackRect = (TrackRectIMP)(void *)imp;
    });
    if (!s_uiSliderTrackRect || !slider) return CGRectZero;
    return s_uiSliderTrackRect(slider, @selector(trackRectForBounds:), bounds);
}

typedef struct {
    CGRect rect;
    BOOL isSolid;
} SGTrackCandidate;

typedef struct {
    CGFloat sliderW;
    CGFloat trackMinX;
    CGFloat trackMaxX;
    CGFloat trackWidth;
    CGFloat referenceMidY;
    CGFloat visualMidY;
    BOOL isFluid;
    CGRect tr;
    CGRect superRect;
    BOOL hasTr;
    BOOL hasSuper;
    BOOL trIsShifted;
    BOOL isHighlighted;
    CGFloat targetHeight;
} SGTrackSearchContext;

static BOOL isShiftedTrackRectArtifact(CGRect r, const SGTrackSearchContext *ctx) {
    if (!ctx->isFluid || !ctx->hasTr || !ctx->trIsShifted) return NO;
    if (fabs(CGRectGetMidY(r) - CGRectGetMidY(ctx->tr)) <= 1.0 &&
        fabs(r.size.height - ctx->tr.size.height) <= 1.0) {
        return YES;
    }
    // Spotify's trackRectForBounds: pins tr.maxY = superRect.maxY, shifting midY upward by (h - superH)/2;
    // reject stale unhighlighted tr artifacts during highlight transitions as well.
    if (ctx->hasSuper &&
        r.size.height > ctx->superRect.size.height + 1.5 &&
        fabs(CGRectGetMaxY(r) - CGRectGetMaxY(ctx->superRect)) <= 1.0 &&
        fabs(CGRectGetMidY(r) - ctx->referenceMidY) > 1.25) {
        return YES;
    }
    return NO;
}

static BOOL isValidTrackCandidate(CGRect r,
                                  const SGTrackSearchContext *ctx,
                                  CGFloat cornerRadius) {
    if (CGRectIsNull(r) || !isFiniteRect(r)) return NO;
    if (r.size.height < kMinTrackHeight || r.size.height > kMaxTrackHeight || r.size.width < 2.0) {
        return NO;
    }
    BOOL leftAnchored = fabs(r.origin.x - ctx->trackMinX) <= 10.0;
    BOOL allowSmallLeftCap = leftAnchored &&
                             (ctx->isFluid || r.size.width > r.size.height + 4.0 || r.size.height <= kDefaultTrackHeight + 1.5);
    BOOL thumbSized = (!allowSmallLeftCap &&
                       r.size.width <= r.size.height + 4.0 &&
                       r.size.width < ctx->sliderW * 0.25 &&
                       cornerRadius >= r.size.height * 0.4 &&
                       r.size.height >= 9.0);
    if (thumbSized) return NO;

    CGFloat midY = CGRectGetMidY(r);
    if (fabs(midY - ctx->referenceMidY) > kTrackSearchMaxMidYDelta &&
        fabs(midY - ctx->visualMidY) > kTrackSearchMaxMidYDelta) {
        return NO;
    }
    return r.origin.x >= ctx->trackMinX - 16.0 && CGRectGetMaxX(r) <= ctx->trackMaxX + 16.0;
}

static void appendTrackCandidate(SGTrackCandidate *candidates,
                                 NSUInteger *count,
                                 CGRect r,
                                 BOOL isSolid,
                                 const SGTrackSearchContext *ctx) {
    if (*count >= kMaxCandidates) return;
    if (isShiftedTrackRectArtifact(r, ctx)) return;
    candidates[*count] = (SGTrackCandidate){
        .rect = r,
        .isSolid = isSolid,
    };
    (*count)++;
}

static void collectLayerTrackCandidates(CALayer *layer,
                                        UIView *slider,
                                        const SGTrackSearchContext *ctx,
                                        CGRect activeClip,
                                        NSUInteger depth,
                                        SGTrackCandidate *candidates,
                                        NSUInteger *count) {
    if (!layer || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (CALayer *sub in layer.sublayers) {
        if (sub.hidden || sub.opacity <= 0.01 || isThumbLayer(sub)) continue;
        CGRect subInSlider = [slider.layer convertRect:sub.bounds fromLayer:sub];
        if (!isFiniteRect(subInSlider)) continue;
        BOOL isSolid = NO;
        if (hasRenderedLayerContent(sub, &isSolid)) {
            CGRect r = renderedRectForLayer(sub, slider.layer, activeClip);
            if (isValidTrackCandidate(r, ctx, sub.cornerRadius)) {
                appendTrackCandidate(candidates, count, r, isSolid, ctx);
            }
        }
        CGRect nextClip = nextClipRectForLayer(sub, slider.layer, activeClip);
        if (!CGRectIsNull(nextClip) && (nextClip.size.width <= 0 || nextClip.size.height <= 0)) {
            continue;
        }
        collectLayerTrackCandidates(sub, slider, ctx, nextClip, depth + 1, candidates, count);
    }
}

static void collectLeafTrackCandidates(UIView *view,
                                       UIView *slider,
                                       const SGTrackSearchContext *ctx,
                                       CGRect activeClip,
                                       NSUInteger depth,
                                       SGTrackCandidate *candidates,
                                       NSUInteger *count) {
    if (!view || depth > kMaxSearchDepth || *count >= kMaxCandidates) return;
    for (UIView *sub in view.subviews) {
        if (sub.hidden || sub.alpha <= 0.01 || sub.layer.hidden || sub.layer.opacity <= 0.01 || isThumbClass(sub.class)) {
            continue;
        }
        CGRect subInSlider = [slider convertRect:sub.bounds fromView:sub];
        if (!isFiniteRect(subInSlider)) continue;
        BOOL isSolid = NO;
        if (hasRenderedTrackContent(sub, &isSolid)) {
            CGRect r = renderedTrackRectForSubview(sub, slider, activeClip);
            if (isValidTrackCandidate(r, ctx, sub.layer.cornerRadius)) {
                appendTrackCandidate(candidates, count, r, isSolid, ctx);
            }
        }
        CGRect nextClip = nextClipRectForLayer(sub.layer, slider.layer, activeClip);
        if (!CGRectIsNull(nextClip) && (nextClip.size.width <= 0 || nextClip.size.height <= 0)) {
            continue;
        }
        collectLeafTrackCandidates(sub, slider, ctx, nextClip, depth + 1, candidates, count);
    }
}

static CGFloat trackCandidateScore(CGRect r,
                                   BOOL isSolid,
                                   const SGTrackSearchContext *ctx) {
    CGFloat score = fabs(r.size.height - ctx->targetHeight) * 6.0 +
                    fabs(CGRectGetMidY(r) - ctx->referenceMidY) * 2.0;
    if (!isSolid) score += 1.5;
    return score;
}

static BOOL isMatchingTargetHeight(CGFloat h, const SGTrackSearchContext *ctx) {
    if (!ctx->isFluid) return YES;
    if (ctx->isHighlighted) {
        return h > kDefaultTrackHeight + 1.5;
    }
    return h < kExpandedTrackHeight - 1.5;
}

static CGRect selectBestTrackCandidate(const SGTrackCandidate *candidates,
                                       NSUInteger count,
                                       const SGTrackSearchContext *ctx,
                                       BOOL *foundFullOut,
                                       BOOL *foundAnyRenderedOut,
                                       CGFloat *measuredMidYOut,
                                       CGFloat *bestScoreOut) {
    BOOL foundBestFull = NO;
    CGRect bestFullRect = CGRectZero;
    CGFloat bestFullScore = CGFLOAT_MAX;

    CGFloat fullMinWidth = MAX(8.0, ctx->trackWidth - 20.0);

    // 1. Full-width rendered track candidates.
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (c.rect.size.width < fullMinWidth) continue;
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, ctx);
        if (!foundBestFull || score < bestFullScore) {
            foundBestFull = YES;
            bestFullRect = c.rect;
            bestFullScore = score;
        }
    }

    // 2. Split min/max track segments flanking the thumb.
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate a = candidates[i];
        for (NSUInteger j = i + 1; j < count; j++) {
            SGTrackCandidate b = candidates[j];
            if (fabs(CGRectGetMidY(a.rect) - CGRectGetMidY(b.rect)) > 1.0) continue;
            if (fabs(a.rect.size.height - b.rect.size.height) > 1.0) continue;
            if (CGRectGetMaxX(a.rect) > CGRectGetMinX(b.rect) + 8.0 &&
                CGRectGetMaxX(b.rect) > CGRectGetMinX(a.rect) + 8.0) {
                continue;
            }
            CGRect combined = CGRectUnion(a.rect, b.rect);
            if (combined.size.height >= kMinTrackHeight &&
                combined.size.height <= kMaxTrackHeight &&
                combined.size.width >= fullMinWidth &&
                a.rect.size.width + b.rect.size.width >= combined.size.width - 32.0 &&
                isMatchingTargetHeight(combined.size.height, ctx)) {
                CGFloat score = trackCandidateScore(combined, a.isSolid && b.isSolid, ctx);
                if (!foundBestFull || score < bestFullScore) {
                    foundBestFull = YES;
                    bestFullRect = combined;
                    bestFullScore = score;
                }
            }
        }
    }

    // 3. Left-anchored fill bar (e.g. elapsed white fill): exact rendered y + height even when max track uses a private glass layer.
    BOOL foundFill = NO;
    CGRect bestFillRect = CGRectZero;
    CGFloat bestFillScore = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        if (fabs(c.rect.origin.x - ctx->trackMinX) > 10.0) continue;
        if (!isMatchingTargetHeight(c.rect.size.height, ctx)) continue;
        CGFloat score = trackCandidateScore(c.rect, c.isSolid, ctx);
        if (!foundFill || score < bestFillScore) {
            foundFill = YES;
            bestFillRect = c.rect;
            bestFillScore = score;
        }
    }

    BOOL preferFill = foundFill && (!foundBestFull || bestFullScore > bestFillScore + 4.0);
    if (preferFill || foundBestFull) {
        CGRect chosen = preferFill
            ? CGRectMake(ctx->trackMinX, bestFillRect.origin.y, ctx->trackWidth, bestFillRect.size.height)
            : bestFullRect;
        if (foundFullOut) *foundFullOut = YES;
        if (foundAnyRenderedOut) *foundAnyRenderedOut = YES;
        if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(chosen);
        if (bestScoreOut) *bestScoreOut = preferFill ? bestFillScore : bestFullScore;
        return chosen;
    }

    // 4. Stale-height rendered bar during highlight transition: borrow its live measured midY for targetHeight.
    BOOL foundStale = NO;
    CGRect bestStaleRect = CGRectZero;
    CGFloat bestStaleScore = CGFLOAT_MAX;
    for (NSUInteger i = 0; i < count; i++) {
        SGTrackCandidate c = candidates[i];
        BOOL isSpanOrLeftFill = (c.rect.size.width >= fullMinWidth || fabs(c.rect.origin.x - ctx->trackMinX) <= 10.0);
        if (!isSpanOrLeftFill) continue;
        CGFloat score = fabs(CGRectGetMidY(c.rect) - ctx->referenceMidY) * 2.0 +
                        (c.rect.size.width >= fullMinWidth ? 0.0 : 4.0) +
                        (c.isSolid ? 0.0 : 2.0);
        if (!foundStale || score < bestStaleScore) {
            foundStale = YES;
            bestStaleRect = c.rect;
            bestStaleScore = score;
        }
    }

    if (foundFullOut) *foundFullOut = NO;
    if (foundAnyRenderedOut) *foundAnyRenderedOut = foundStale;
    if (measuredMidYOut) *measuredMidYOut = foundStale ? CGRectGetMidY(bestStaleRect) : ctx->referenceMidY;
    if (bestScoreOut) *bestScoreOut = bestStaleScore;
    return bestStaleRect;
}

static BOOL isValidBufferingFrame(CGRect bf, CGFloat sliderW, CGFloat expectedMidY, CGFloat maxMidYDelta) {
    return isFiniteRect(bf) &&
           bf.size.height >= kMinTrackHeight && bf.size.height <= kMaxTrackHeight &&
           bf.size.width >= sliderW - 12.0 &&
           bf.origin.x >= -1.0 && bf.origin.x <= 10.0 &&
           CGRectGetMaxX(bf) <= sliderW + 1.0 &&
           fabs(CGRectGetMidY(bf) - expectedMidY) <= maxMidYDelta;
}

// ProgressBar6Slider carries a UIKit slider visual element (_UISlideriOSVisualElement or
// _UISliderFluidVisualElement) and SliderBufferingAnimationView. Spotify's trackRectForBounds:
// computes y = superRect.minY + (superRect.height - targetHeight) without halving the height delta,
// shifting tr.origin.y (and bufferingView.frame) upward relative to UIKit's centered iOS 26+ fluid track.
// Measure rendered track/fill views and layers directly in slider coordinates (accounting for layer.mask
// and CAShapeLayer paths); when unavailable during transitions, fall back to targetHeight centered on
// visualElement's midY (fluid iOS 26+ tracks) or [UISlider trackRectForBounds:] midY (legacy).
static CGRect resolveTrackFrame(UIView *slider,
                                UIView *bufferingView,
                                UIView *visualElement,
                                SGSponsorBlockOverlayContainer *container,
                                BOOL *usedRenderedTrack,
                                BOOL *measuredMidYValid,
                                CGFloat *measuredMidYOut) {
    if (usedRenderedTrack) *usedRenderedTrack = NO;
    if (measuredMidYValid) *measuredMidYValid = NO;
    if (!slider || slider.bounds.size.width <= 0 || slider.bounds.size.height <= 0) {
        return CGRectZero;
    }

    CGFloat sliderW = slider.bounds.size.width;
    CGFloat sliderH = slider.bounds.size.height;
    CGFloat boundsMidY = CGRectGetMidY(slider.bounds);
    BOOL isHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    BOOL isFluid = isFluidSlider(visualElement);

    CGRect tr = CGRectZero;
    CGRect superRect = CGRectZero;
    BOOL hasTr = NO;
    BOOL hasSuper = NO;
    BOOL hasHorizontalTr = NO;
    BOOL hasHorizontalSuper = NO;
    CGFloat targetHeight = isHighlighted ? kExpandedTrackHeight : kDefaultTrackHeight;

    if ([slider isKindOfClass:UISlider.class]) {
        UISlider *uiSlider = (UISlider *)slider;
        tr = [uiSlider trackRectForBounds:slider.bounds];
        hasTr = isFiniteRect(tr) && tr.size.width > 0 && tr.size.height > 0;
        hasHorizontalTr = hasTr && tr.size.width >= sliderW - 24.0 &&
                          tr.origin.x >= -16.0 && CGRectGetMaxX(tr) <= sliderW + 16.0;

        superRect = superTrackRectForSlider(uiSlider, slider.bounds);
        hasSuper = isFiniteRect(superRect) && superRect.size.width > 0 && superRect.size.height > 0;
        hasHorizontalSuper = hasSuper && superRect.size.width >= sliderW - 24.0 &&
                             superRect.origin.x >= -16.0 && CGRectGetMaxX(superRect) <= sliderW + 16.0;

        if (hasTr && !isFluid && tr.size.height >= kMinTrackHeight && tr.size.height <= kMaxTrackHeight) {
            targetHeight = tr.size.height;
        }
    }

    CGFloat fallbackInset = isFluid ? 0.0 : kLegacyTrackInset;
    CGFloat trackMinX = hasHorizontalTr ? tr.origin.x
                      : (hasHorizontalSuper ? superRect.origin.x : fallbackInset);
    CGFloat trackWidth = hasHorizontalTr ? tr.size.width
                       : (hasHorizontalSuper ? superRect.size.width : MAX(0.0, sliderW - fallbackInset * 2.0));
    CGFloat visualMidY = (visualElement && visualElement.superview == slider && visualElement.frame.size.height > 0)
                       ? CGRectGetMidY(visualElement.frame)
                       : boundsMidY;
    // On iOS 26+ Liquid Glass, the fluid pill track's visual center is offset by -0.5 pt (-1.5 px @ 3x)
    // relative to visualElement.frame.midY / bounds.midY.
    CGFloat referenceMidY = isFluid
                          ? (visualMidY - 0.5)
                          : (hasSuper ? CGRectGetMidY(superRect) : boundsMidY);
    BOOL trIsShifted = hasTr && (fabs(CGRectGetMidY(tr) - referenceMidY) > 0.75);

    if (visualElement && visualElement.superview == slider) {
        SGTrackSearchContext ctx = {
            .sliderW = sliderW,
            .trackMinX = trackMinX,
            .trackMaxX = trackMinX + trackWidth,
            .trackWidth = trackWidth,
            .referenceMidY = referenceMidY,
            .visualMidY = visualMidY,
            .isFluid = isFluid,
            .tr = tr,
            .superRect = superRect,
            .hasTr = hasTr,
            .hasSuper = hasSuper,
            .trIsShifted = trIsShifted,
            .isHighlighted = isHighlighted,
            .targetHeight = targetHeight,
        };

        CGRect rootClip = nextClipRectForLayer(visualElement.layer, slider.layer, CGRectNull);

        SGTrackCandidate viewCandidates[kMaxCandidates];
        NSUInteger viewCount = 0;
        collectLeafTrackCandidates(visualElement, slider, &ctx, rootClip, 0, viewCandidates, &viewCount);
        BOOL foundFullView = NO;
        BOOL foundStaleView = NO;
        CGFloat viewMidY = referenceMidY;
        CGFloat viewScore = CGFLOAT_MAX;
        CGRect bestView = selectBestTrackCandidate(viewCandidates, viewCount, &ctx, &foundFullView, &foundStaleView, &viewMidY, &viewScore);

        SGTrackCandidate layerCandidates[kMaxCandidates];
        NSUInteger layerCount = 0;
        BOOL foundFullLayer = NO;
        BOOL foundStaleLayer = NO;
        CGFloat layerMidY = referenceMidY;
        CGFloat layerScore = CGFLOAT_MAX;
        CGRect bestLayer = CGRectZero;
        if (!foundFullView || isFluid) {
            collectLayerTrackCandidates(visualElement.layer, slider, &ctx, rootClip, 0, layerCandidates, &layerCount);
            bestLayer = selectBestTrackCandidate(layerCandidates, layerCount, &ctx, &foundFullLayer, &foundStaleLayer, &layerMidY, &layerScore);
        }

        if (foundFullView || foundFullLayer) {
            CGRect chosen = (foundFullView && foundFullLayer)
                ? ((layerScore + 0.01 < viewScore) ? bestLayer : bestView)
                : (foundFullView ? bestView : bestLayer);
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            if (measuredMidYValid) *measuredMidYValid = YES;

            // Fluid tracks (iOS 26+ Liquid Glass):
            // The rendered layer/view may include bottom specular/shadow padding (e.g. 8.0 pt instead of 7.0 pt).
            // Strictly enforce targetHeight (7.0 pt rest, 12.0 pt scrubbed).
            // Anchor Y to chosen.origin.y if it aligns with the expected track top (within 1.0 pt), otherwise center on referenceMidY.
            CGFloat h = isFluid ? targetHeight : (chosen.size.height > 0 ? chosen.size.height : targetHeight);
            CGFloat expectedTop = referenceMidY - targetHeight / 2.0;
            CGFloat y = (isFluid && fabs(chosen.origin.y - expectedTop) <= 1.0)
                      ? chosen.origin.y
                      : (isFluid ? expectedTop : chosen.origin.y);
            CGRect trackRect = CGRectMake(trackMinX, y, trackWidth, h);
            if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(trackRect);
            return trackRect;
        }

        if (foundStaleView || foundStaleLayer) {
            if (measuredMidYValid) *measuredMidYValid = YES;
            if (measuredMidYOut) *measuredMidYOut = referenceMidY;
            return CGRectMake(trackMinX, referenceMidY - targetHeight / 2.0, trackWidth, targetHeight);
        }
    }

    if (!isFluid && bufferingView && bufferingView.superview == slider) {
        CGRect bf = bufferingView.frame;
        if (isValidBufferingFrame(bf, sliderW, referenceMidY, 5.5)) {
            if (usedRenderedTrack) *usedRenderedTrack = YES;
            if (measuredMidYValid) *measuredMidYValid = YES;
            if (measuredMidYOut) *measuredMidYOut = CGRectGetMidY(bf);
            return bf;
        }
    }

    CGFloat fallbackMidY = referenceMidY;
    if (container && container.hasLastMeasuredMidY &&
        fabs(container.lastMeasuredBoundsHeight - sliderH) <= 0.5) {
        fallbackMidY = container.lastMeasuredMidY;
    }

    CGFloat h = slider.clipsToBounds ? MIN(targetHeight, sliderH) : targetHeight;
    CGFloat y = fallbackMidY - h / 2.0;
    if (slider.clipsToBounds) {
        y = MAX(0.0, MIN(sliderH - h, y));
    }
    return CGRectMake(trackMinX, y, trackWidth, h);
}

static UIView *overlayAnchor(UIView *slider, UIView *bufferingView, UIView *visualElement) {
    if (bufferingView && visualElement) {
        NSUInteger bIdx = [slider.subviews indexOfObjectIdenticalTo:bufferingView];
        NSUInteger vIdx = [slider.subviews indexOfObjectIdenticalTo:visualElement];
        return (bIdx != NSNotFound && vIdx != NSNotFound && bIdx > vIdx) ? bufferingView : visualElement;
    }
    return bufferingView ?: visualElement;
}

+ (void)updateSlider:(UIView *)slider animateHeightChange:(BOOL)animateHeightChange {
    SGSponsorBlockOverlayContainer *container = nil;
    for (UIView *sv in slider.subviews) {
        if ([sv isKindOfClass:[SGSponsorBlockOverlayContainer class]]) {
            container = (SGSponsorBlockOverlayContainer *)sv;
            break;
        }
    }

    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || !SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockOverlay)) {
        if (container) [container removeFromSuperview];
        return;
    }

    SGSponsorBlockSkipper *skipper = [SGSponsorBlockSkipper sharedSkipper];
    NSString *episodeID = skipper.currentEpisodeID;
    double duration = skipper.episodeDuration;
    NSArray<SGSponsorBlockSegment *> *segments = skipper.currentSegments;

    if (!episodeID.length || !isfinite(duration) || duration <= 0 || !segments.count) {
        if (container) [container removeFromSuperview];
        return;
    }

    // Save the previous cached anchors before any re-scan so anchorChanged and the
    // cached-frame invalidation below can compare old vs. new correctly.
    UIView *prevBufferingView = container.cachedTrackView;
    UIView *prevVisualElement = container.cachedVisualElement;
    BOOL prevDidScan = container.didScanSubviews;
    UIView *bufferingView = prevBufferingView;
    UIView *visualElement = prevVisualElement;
    if (!container || !prevDidScan ||
        (bufferingView && bufferingView.superview != slider) ||
        (visualElement && visualElement.superview != slider)) {
        bufferingView = nil;
        visualElement = nil;
        for (UIView *sv in slider.subviews) {
            if (sv == container) continue;
            if (SGClassNamed(sv.class, @"SliderBufferingAnimationView")) {
                bufferingView = sv;
            } else if (isVisualElementView(sv)) {
                visualElement = sv;
            }
        }
        if (container) {
            container.cachedTrackView = bufferingView;
            container.cachedVisualElement = visualElement;
            container.didScanSubviews = (visualElement != nil && bufferingView != nil);
            // If the anchor views changed, the cached track frame belongs to the old layout.
            if (bufferingView != prevBufferingView || visualElement != prevVisualElement) {
                container.hasCachedTrackFrame = NO;
            }
            UIView *anchor = overlayAnchor(slider, bufferingView, visualElement);
            if (anchor) {
                NSUInteger containerIdx = [slider.subviews indexOfObjectIdenticalTo:container];
                NSUInteger anchorIdx = [slider.subviews indexOfObjectIdenticalTo:anchor];
                if (containerIdx != NSNotFound && anchorIdx != NSNotFound && containerIdx < anchorIdx) {
                    [slider insertSubview:container aboveSubview:anchor];
                }
            }
        }
    }

    BOOL curHighlighted = [slider isKindOfClass:UISlider.class] && ((UISlider *)slider).highlighted;
    BOOL highlightedChanged = container && (container.lastHighlighted != curHighlighted);
    BOOL boundsChanged = container && !CGRectEqualToRect(container.lastSliderBounds, slider.bounds);
    // Compare against the pre-scan values so a re-scan that finds different views is detected.
    BOOL anchorChanged = container && (!container.didScanSubviews ||
                                       bufferingView != prevBufferingView ||
                                       visualElement != prevVisualElement);

    BOOL needsRebuild = (!container ||
                         container.needsRebuild ||
                         container.cachedRawSegments != segments ||
                         ![container.cachedEpisodeID isEqualToString:episodeID] ||
                         fabs(container.cachedDuration - duration) > 0.001);

    CGRect trackFrame = CGRectZero;
    BOOL usedRenderedTrack = NO;
    BOOL measuredMidYValid = NO;
    CGFloat measuredMidY = 0;
    BOOL canUseCachedTrack = (container &&
                              container.hasCachedTrackFrame &&
                              container.usedRenderedTrack &&
                              !highlightedChanged &&
                              !boundsChanged &&
                              !anchorChanged &&
                              !needsRebuild);
    if (canUseCachedTrack) {
        trackFrame = container.cachedTrackFrame;
        usedRenderedTrack = container.usedRenderedTrack;
    } else {
        trackFrame = resolveTrackFrame(slider, bufferingView, visualElement, container,
                                       &usedRenderedTrack, &measuredMidYValid, &measuredMidY);
        if (trackFrame.size.width <= 0 || trackFrame.size.height <= 0) return;

        if (measuredMidYValid && container) {
            container.hasLastMeasuredMidY = YES;
            container.lastMeasuredMidY = measuredMidY;
            container.lastMeasuredBoundsHeight = slider.bounds.size.height;
        }
        if (container) {
            container.cachedTrackFrame = trackFrame;
            container.hasCachedTrackFrame = YES;
            container.lastSliderBounds = slider.bounds;
        }
    }

    BOOL frameChanged = container && !CGRectEqualToRect(container.frame, trackFrame);
    if (!needsRebuild) {
        if (frameChanged) {
            BOOL heightChanged = fabs(container.frame.size.height - trackFrame.size.height) > 0.5;
            if ((animateHeightChange || highlightedChanged) && heightChanged && UIView.inheritedAnimationDuration <= 0.0) {
                NSTimeInterval animDuration = curHighlighted ? 0.18 : 0.08;
                [UIView animateWithDuration:animDuration
                                      delay:0
                                    options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionCurveEaseOut
                                 animations:^{
                    [container layoutSegmentsForTrackFrame:trackFrame];
                } completion:nil];
            } else {
                [container layoutSegmentsForTrackFrame:trackFrame];
            }
        }
    } else {
        NSTimeInterval minDuration = SGSponsorBlockMinDuration();
        NSMutableArray<SGSponsorBlockSegment *> *visible = [NSMutableArray array];
        for (SGSponsorBlockSegment *seg in segments) {
            if (![seg.actionType isEqualToString:@"skip"]) continue;
            if (seg.duration < minDuration) continue;
            if (SGSponsorBlockCategoryBehavior(seg.category) == SGSponsorBlockBehaviorOff) continue;
            [visible addObject:seg];
        }

        if (!visible.count) {
            if (container) [container removeFromSuperview];
            return;
        }

        if (!container) {
            container = [[SGSponsorBlockOverlayContainer alloc] initWithFrame:trackFrame];
            container.userInteractionEnabled = NO;
            container.backgroundColor = [UIColor clearColor];
            container.cachedTrackView = bufferingView;
            container.cachedVisualElement = visualElement;
            container.didScanSubviews = (visualElement != nil && bufferingView != nil);
            UIView *anchor = overlayAnchor(slider, bufferingView, visualElement);
            if (anchor) {
                [slider insertSubview:container aboveSubview:anchor];
            } else {
                [slider addSubview:container];
            }
        }
        container.cachedRawSegments = segments;
        [container rebuildWithSegments:visible duration:duration episodeID:episodeID trackFrame:trackFrame];
        // Seed the track-frame cache on the (possibly new) container so the next layout pass
        // can skip resolveTrackFrame when bounds and anchors are stable.
        container.cachedTrackFrame = trackFrame;
        container.hasCachedTrackFrame = YES;
        container.lastSliderBounds = slider.bounds;
        if (measuredMidYValid) {
            container.hasLastMeasuredMidY = YES;
            container.lastMeasuredMidY = measuredMidY;
            container.lastMeasuredBoundsHeight = slider.bounds.size.height;
        }
        frameChanged = YES;
    }

    BOOL prevUsedRendered = container.usedRenderedTrack;
    container.usedRenderedTrack = usedRenderedTrack;
    container.lastHighlighted = curHighlighted;

    BOOL postLayoutBoundsChanged = !CGRectEqualToRect(container.lastPostLayoutBounds, slider.bounds);
    if (usedRenderedTrack || highlightedChanged || postLayoutBoundsChanged) {
        container.postLayoutRetries = 0;
    }

    // Visual elements lay out their child track views after ProgressBar6Slider -layoutSubviews returns;
    // schedule a post-layout pass whenever on screen and the overlay was just placed/resized,
    // highlight state toggled, or visualElement hasn't finished laying out the target height yet.
    BOOL shouldSchedulePostLayout = (frameChanged ||
                                     highlightedChanged ||
                                     (!usedRenderedTrack && (postLayoutBoundsChanged || prevUsedRendered || container.postLayoutRetries < kMaxPostLayoutRetries)));
    if (slider.window && !container.pendingPostLayout && shouldSchedulePostLayout) {
        if (!usedRenderedTrack && !highlightedChanged && !postLayoutBoundsChanged && !prevUsedRendered) {
            container.postLayoutRetries++;
        }
        container.pendingPostLayout = YES;
        container.lastPostLayoutBounds = slider.bounds;
        __weak UIView *weakSlider = slider;
        __weak SGSponsorBlockOverlayContainer *weakContainer = container;
        dispatch_async(dispatch_get_main_queue(), ^{
            SGSponsorBlockOverlayContainer *c = weakContainer;
            UIView *s = weakSlider;
            if (!c) return;
            c.pendingPostLayout = NO;
            if (s && c.superview == s && s.window) {
                [self updateSlider:s animateHeightChange:YES];
            }
        });
    }
}

@end
