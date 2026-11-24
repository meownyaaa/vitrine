#import "SGLegacyGlass.h"
#import "SGRuntime.h"
#import "SGLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - availability

BOOL SGLegacyGlassAvailable(void) {
    static BOOL available;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 26.0, *)) return;
        Class mesh = NSClassFromString(@"CAMutableMeshTransform");
        SEL meshSel = NSSelectorFromString(@"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
        available = NSClassFromString(@"CABackdropLayer") && [mesh respondsToSelector:meshSel];
    });
    return available;
}

#pragma mark - backdrop layer and its filters

// Saturation and contrast boost under the blur, as Telegram does, so the backdrop is not just a flat blur.
static id SGSaturationFilter(void) {
    static const float matrix[20] = {
        2.6705f, -1.1087999f, -0.1117f, 0.0f, 0.049999997f,
        -0.3295f, 1.8914f, -0.111899994f, 0.0f, 0.049999997f,
        -0.3297f, -1.1084f, 2.8881f, 0.0f, 0.049999997f,
        0.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };
    id filter = SGFilterOfType(@"colorMatrix");
    [filter setValue:[NSValue valueWithBytes:matrix objCType:"{CAColorMatrix=ffffffffffffffffffff}"] forKey:@"inputColorMatrix"];
    // A key CAFilter may not have on every iOS (checked on 26 only): a missing one is left out, not a crash.
    @try {
        [filter setValue:@YES forKey:@"inputBackdropAware"];
    } @catch (NSException *e) {
        SGLog(@"legacy glass: the colour matrix filter has no inputBackdropAware (%@)", e.reason);
    }
    return filter;
}

static id SGBlurFilter(CGFloat radius) {
    id filter = SGFilterOfType(@"gaussianBlur");
    [filter setValue:@(radius) forKey:@"inputRadius"];
    return filter;
}

// Layer actions off, so the backdrop follows its view's resizes without implicit animation.
@interface SGNoActionsDelegate : NSObject <CALayerDelegate>
@end
@implementation SGNoActionsDelegate
- (id<CAAction>)actionForLayer:(CALayer *)layer forKey:(NSString *)event { return (id<CAAction>)[NSNull null]; }
@end

static NSArray *SGBackdropFiltersOf(CGFloat blur, BOOL saturate) {
    NSMutableArray *filters = [NSMutableArray array];
    for (id filter in @[(saturate ? SGSaturationFilter() : nil) ?: NSNull.null, SGBlurFilter(blur) ?: NSNull.null]) {
        if (filter != NSNull.null) [filters addObject:filter];
    }
    return filters;
}

static NSArray *SGBackdropFilters(CGFloat blur) {
    return SGBackdropFiltersOf(blur, YES);
}

static CALayer *SGMakeBackdropLayer(id<CALayerDelegate> delegate) {
    CALayer *layer = [[NSClassFromString(@"CABackdropLayer") alloc] init];
    if (!layer) return nil;
    SEL setScale = NSSelectorFromString(@"setScale:");
    if ([layer respondsToSelector:setScale]) ((void (*)(id, SEL, double))objc_msgSend)(layer, setScale, 1.0);
    layer.rasterizationScale = 1.0;
    layer.delegate = delegate;
    NSArray *filters = SGBackdropFilters(2.0);
    if (filters.count) layer.filters = filters;
    return layer;
}

#pragma mark - mesh transform (CAMutableMeshTransform)

typedef struct { CGFloat x, y, z; } SGMeshPoint3D;
typedef struct { CGPoint from; SGMeshPoint3D to; } SGMeshVertex;
typedef struct { uint32_t indices[4]; float w[4]; } SGMeshFace;

// The class method takes C arrays, which only NSInvocation can pass without a header for it.
static id SGMakeMeshTransform(SGMeshVertex *vertices, NSUInteger vertexCount, SGMeshFace *faces, NSUInteger faceCount) {
    Class cls = NSClassFromString(@"CAMutableMeshTransform");
    SEL sel = NSSelectorFromString(@"meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:");
    NSMethodSignature *sig = [cls methodSignatureForSelector:sel];
    if (!sig) return nil;
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
    inv.selector = sel;
    NSString *depthNormalization = @"none";
    [inv setArgument:&vertexCount atIndex:2];
    [inv setArgument:&vertices atIndex:3];
    [inv setArgument:&faceCount atIndex:4];
    [inv setArgument:&faces atIndex:5];
    [inv setArgument:&depthNormalization atIndex:6];
    [inv invokeWithTarget:cls];
    __unsafe_unretained id raw = nil;
    [inv getReturnValue:&raw];
    id transform = raw;
    if ([transform respondsToSelector:NSSelectorFromString(@"setSubdivisionSteps:")]) [transform setValue:@0 forKey:@"subdivisionSteps"];
    return transform;
}

#pragma mark - displacement field (after Telegram's GenerateMesh.swift, with the lens of adaptive_liquid_glass)

// How the system's glass bends what is behind it, as adaptive_liquid_glass measured it against SwiftUI's own
// `.glassEffect` (github.com/AymanOmara/adaptive_liquid_glass, MIT; shaders/liquid_glass.frag, "Lens v3", and
// tool/fidelity/standard_constants.json, regularDark): the shift towards the inside falls off exponentially with the
// depth from the rim, over a length of kLensDecay, and is cut to 0 at kLensBand. At the rim it is kLensStrength times
// the band, so the outer points sample deep inside and the band shows a compressed, mirrored copy of the interior. A
// pane whose shorter half is below kLensSizeRef gets the whole lens scaled down by that ratio (SGMakeGlassMesh).
static const CGFloat kLensBand = 18.83, kLensDecay = 5.90, kLensStrength = 2.63, kLensSizeRef = 38.79;

// The share of the rim's shift at `depth` points in from the rim, 1 at the rim and 0 from `band` in.
static CGFloat SGLensProfile(CGFloat depth, CGFloat band) {
    CGFloat decay = kLensDecay * band / kLensBand, cut = exp(-band / decay);
    return MAX(0, exp(-MAX(0, depth) / decay) - cut) / (1 - cut);
}

// The classic lens, for the big panes (kClassicMinSide, SGLegacyGlassView.classic): the glass as it first was, ported from Telegram's
// GenerateMesh.swift, whose bend eases in over a thin band at the edge and is pushed harder still in the strip at the rim.
// On a sheet the measured lens spread over a wide band and its rim light was faint, so a sheet read as a plain blur.
static const CGFloat kBezierX1 = 0.816137566137566, kBezierY1 = 0.20502645502645533;
static const CGFloat kBezierX2 = 0.5806878306878306, kBezierY2 = 0.873015873015873;
static const CGFloat kClassicBand = 12, kClassicOuterStrip = 2, kClassicShift = 20;
// A pane counts as big, and takes the classic lens, from this shorter side on: the queue, the sheets, the menus and the
// dialogs. The controls (the tab bar, the now playing bar, buttons, a switch's thumb, the tab bar's bubble) are smaller.
static const CGFloat kClassicMinSide = 100;

static CGFloat SGBezier(CGFloat t, CGFloat a1, CGFloat a2) {
    return (((1.0 - 3.0 * a2 + 3.0 * a1) * t + (3.0 * a2 - 6.0 * a1)) * t + 3.0 * a1) * t;
}

static CGFloat SGBezierSlope(CGFloat t, CGFloat a1, CGFloat a2) {
    return 3.0 * (1.0 - 3.0 * a2 + 3.0 * a1) * t * t + 2.0 * (3.0 * a2 - 6.0 * a1) * t + 3.0 * a1;
}

// The curve's y at x: Newton's method for the t that gives x, then y at that t.
static CGFloat SGEase(CGFloat x) {
    CGFloat t = x;
    for (int i = 0; i < 4; i++) {
        CGFloat slope = SGBezierSlope(t, kBezierX1, kBezierX2);
        if (slope == 0.0) break;
        t -= (SGBezier(t, kBezierX1, kBezierX2) - x) / slope;
    }
    CGFloat y = SGBezier(t, kBezierY1, kBezierY2);
    return y >= 0.997 ? 1.0 : y;
}

// Signed distance from (x, y) to a width x height rounded rect at the origin (negative inside), and the
// outward unit normal there.
static CGFloat SGRoundedRectSDF(CGFloat x, CGFloat y, CGFloat width, CGFloat height, CGFloat radius, CGFloat *nx, CGFloat *ny) {
    CGFloat px = x - width / 2, py = y - height / 2;
    CGFloat qx = fabs(px) - width / 2 + radius, qy = fabs(py) - height / 2 + radius;
    CGFloat gx = 0, gy = 0;
    if (qx > 0 && qy > 0) {
        CGFloat d = hypot(qx, qy);
        if (d > 0) { gx = qx / d; gy = qy / d; }
    } else if (qx > qy) {
        gx = 1;
    } else {
        gy = 1;
    }
    *nx = px < 0 ? -gx : gx;
    *ny = py < 0 ? -gy : gy;
    return hypot(MAX(qx, 0), MAX(qy, 0)) + MIN(MAX(qx, qy), 0) - radius;
}

// What a vertex samples from, relative to where it sits: inwards along the rim's normal, by the lens profile of its
// depth, as a share of the rim's shift; the classic lens by Telegram's eased curve of its share of the band.
static void SGDisplacement(CGFloat x, CGFloat y, CGFloat width, CGFloat height, CGFloat radius, CGFloat edgeDistance,
                           BOOL classic, CGFloat *outDx, CGFloat *outDy, CGFloat *outSdf) {
    CGFloat nx, ny;
    CGFloat sdf = SGRoundedRectSDF(x, y, width, height, radius, &nx, &ny);
    CGFloat v = classic ? SGEase(MAX(0, MIN(1, 1.0 + sdf / edgeDistance))) : SGLensProfile(-sdf, edgeDistance);
    *outDx = -nx * v; *outDy = -ny * v; *outSdf = sdf;
}

#pragma mark - mesh template

// The mesh is built once per corner radius at a reference size, as vertices of a size-independent
// (base + scale * size) position plus their unitless displacement. Fitting it to a real size is then one
// affine remap per vertex, with no distance-field work per layout pass.
typedef struct { CGFloat radius, refW, refH, edgeDistance, outerEdgeDistance; BOOL classic; } SGMeshSpec;
typedef struct { CGFloat baseX, scaleX, baseY, scaleY, dispX, dispY, depth; } SGTemplateVertex;

static const NSInteger kCornerResolution = 12;
static const CGFloat kOuterEdgeDistance = 3.5;   // the strip at the rim where the mesh's rings are closest
// How deep from the rim the glass bends what is behind it: the measured band, or most of the corner's radius where the
// corner is smaller (the mesh's rings lie within it).
static const CGFloat kEdgeBandShare = 0.8;

static CGFloat SGEdgeBand(CGFloat radius) {
    return MIN(kLensBand, radius * kEdgeBandShare);
}
static const CGFloat kInsetPoints = -1.0;        // the mesh reaches this far past the view, so its rim is never bare

@interface SGMeshTemplate : NSObject
@property (nonatomic, readonly) NSMutableData *vertices;   // SGTemplateVertex[]
@property (nonatomic, readonly) NSMutableData *faces;      // SGMeshFace[]
@end
@implementation SGMeshTemplate
- (instancetype)init {
    if ((self = [super init])) { _vertices = [NSMutableData data]; _faces = [NSMutableData data]; }
    return self;
}
@end

static uint32_t SGAddVertex(SGMeshTemplate *t, SGMeshSpec spec, CGFloat baseX, CGFloat scaleX, CGFloat baseY, CGFloat scaleY, CGFloat depth) {
    CGFloat dx, dy, sdf;
    SGDisplacement(baseX + scaleX * spec.refW, baseY + scaleY * spec.refH, spec.refW, spec.refH, spec.radius, spec.edgeDistance,
                   spec.classic, &dx, &dy, &sdf);
    // The measured lens is steep enough at the rim on its own: no boost within the outer strip, which is kept for the
    // vertices it puts where the lens changes fastest. The classic one has Telegram's smoothstep boost there.
    CGFloat boost = 1.0;
    if (spec.classic && spec.outerEdgeDistance > 0) {
        CGFloat s = MAX(0.0, MIN(1.0, (spec.outerEdgeDistance + sdf) / spec.outerEdgeDistance));
        boost += s * s * (3 - 2 * s) * 0.5;
    }
    SGTemplateVertex v = {baseX, scaleX, baseY, scaleY, dx * boost, dy * boost, depth};
    [t.vertices appendBytes:&v length:sizeof(v)];
    return (uint32_t)(t.vertices.length / sizeof(v)) - 1;
}

static void SGAddQuad(SGMeshTemplate *t, uint32_t i0, uint32_t i1, uint32_t i2, uint32_t i3) {
    SGMeshFace face = {{i0, i1, i2, i3}, {0, 0, 0, 0}};
    [t.faces appendBytes:&face length:sizeof(face)];
}

// A grid over the given (base, scale) axes, quadded up. `axis` entries are CGPoint(base, scale).
static void SGAddGrid(SGMeshTemplate *t, SGMeshSpec spec, NSArray<NSValue *> *xAxis, NSArray<NSValue *> *yAxis) {
    NSUInteger cols = xAxis.count, rows = yAxis.count;
    uint32_t *grid = malloc(sizeof(uint32_t) * rows * cols);
    for (NSUInteger r = 0; r < rows; r++) {
        for (NSUInteger c = 0; c < cols; c++) {
            CGPoint x = xAxis[c].CGPointValue, y = yAxis[r].CGPointValue;
            grid[r * cols + c] = SGAddVertex(t, spec, x.x, x.y, y.x, y.y, 0);
        }
    }
    for (NSUInteger r = 0; r + 1 < rows; r++) {
        for (NSUInteger c = 0; c + 1 < cols; c++) {
            SGAddQuad(t, grid[r * cols + c], grid[r * cols + c + 1], grid[(r + 1) * cols + c + 1], grid[(r + 1) * cols + c]);
        }
    }
    free(grid);
}

// A quarter circle around (centerBase + centerScale * size): rings from the rim inwards, fanned into the
// centre. `rings` are radii as fractions of the corner radius, outermost first, `angles` fractions of the
// arc from startAngle to endAngle.
static void SGAddCorner(SGMeshTemplate *t, SGMeshSpec spec, CGPoint centerX, CGPoint centerY, CGFloat startAngle, CGFloat endAngle,
                        NSArray<NSNumber *> *rings, NSArray<NSNumber *> *angles) {
    NSUInteger ringCount = rings.count, angleCount = angles.count;
    uint32_t *grid = malloc(sizeof(uint32_t) * ringCount * angleCount);
    for (NSUInteger r = 0; r < ringCount; r++) {
        CGFloat radius = spec.radius * rings[r].doubleValue;
        for (NSUInteger a = 0; a < angleCount; a++) {
            CGFloat angle = startAngle + (endAngle - startAngle) * angles[a].doubleValue;
            grid[r * angleCount + a] = SGAddVertex(t, spec, centerX.x + radius * cos(angle), centerX.y, centerY.x + radius * sin(angle), centerY.y, 0);
        }
    }
    for (NSUInteger r = 0; r + 1 < ringCount; r++) {
        for (NSUInteger a = 0; a + 1 < angleCount; a++) {
            SGAddQuad(t, grid[r * angleCount + a], grid[r * angleCount + a + 1], grid[(r + 1) * angleCount + a + 1], grid[(r + 1) * angleCount + a]);
        }
    }

    // The innermost ring is fanned into the centre, two segments to a quad.
    const uint32_t *inner = grid + (ringCount - 1) * angleCount;
    NSInteger segments = (NSInteger)angleCount - 1;
    if (segments >= 2) {
        uint32_t center = SGAddVertex(t, spec, centerX.x, centerX.y, centerY.x, centerY.y, -0.02);
        NSInteger i = 0;
        for (; i + 2 <= segments; i += 2) SGAddQuad(t, center, inner[i], inner[i + 1], inner[i + 2]);
        if (i < segments) SGAddQuad(t, center, inner[segments - 1], inner[segments], inner[segments]);
    }
    free(grid);
}

static NSValue *SGAxisPoint(CGFloat base, CGFloat scale) {
    return [NSValue valueWithCGPoint:CGPointMake(base, scale)];
}

static SGMeshTemplate *SGBuildTemplate(CGFloat radius, BOOL classic) {
    SGMeshSpec spec = {radius, MAX(4 * radius, 100), MAX(4 * radius, 100), classic ? MIN(kClassicBand, radius) : SGEdgeBand(radius),
                       classic ? kClassicOuterStrip : kOuterEdgeDistance, classic};
    SGMeshTemplate *t = [SGMeshTemplate new];
    CGFloat R = radius;

    NSInteger angularSteps = MAX(3, kCornerResolution);
    if (angularSteps % 2) angularSteps++;
    NSInteger radialSteps = MAX(2, kCornerResolution);
    NSInteger edgeSegments = MAX(2, kCornerResolution / 2 + 1);

    // Ring radii: evenly spaced up to (1 - rim strip), then the strip's edge, then the rim itself.
    NSMutableArray<NSNumber *> *depths = [NSMutableArray array];
    CGFloat innerMax = MAX(0, 1 - MAX(0, MIN(1, spec.outerEdgeDistance / R)));
    NSInteger innerSegments = MAX(1, radialSteps - 1);
    for (NSInteger i = 0; i <= innerSegments; i++) [depths addObject:@(innerMax * i / (CGFloat)innerSegments)];
    if (fabs(depths.lastObject.doubleValue - innerMax) >= 1e-4) [depths addObject:@(innerMax)];
    if (fabs(depths.lastObject.doubleValue - 1.0) >= 1e-4) [depths addObject:@1.0];
    NSArray<NSNumber *> *outerToInner = depths.reverseObjectEnumerator.allObjects;
    NSMutableArray<NSNumber *> *rings = [NSMutableArray array];   // the same without the centre, which the fan covers
    for (NSNumber *d in outerToInner) if (d.doubleValue > 0) [rings addObject:d];

    NSMutableArray<NSNumber *> *angles = [NSMutableArray array];
    for (NSInteger i = 0; i <= angularSteps; i++) [angles addObject:@(i / (CGFloat)angularSteps)];

    // Axes of the straight parts: `span` runs from one corner's centre to the other's, `leading` and
    // `trailing` are the corner bands at each end, thickened towards the rim.
    NSMutableArray<NSValue *> *span = [NSMutableArray array], *leading = [NSMutableArray array], *trailing = [NSMutableArray array];
    for (NSInteger i = 0; i <= edgeSegments; i++) {
        CGFloat u = i / (CGFloat)edgeSegments;
        [span addObject:SGAxisPoint(R * (1 - 2 * u), u)];
    }
    for (NSNumber *d in outerToInner) [leading addObject:SGAxisPoint(R * (1 - d.doubleValue), 0)];
    for (NSNumber *d in depths) [trailing addObject:SGAxisPoint(-R * (1 - d.doubleValue), 1)];

    SGAddGrid(t, spec, span, leading);     // top band
    SGAddGrid(t, spec, span, trailing);    // bottom band
    SGAddGrid(t, spec, leading, span);     // left band
    SGAddGrid(t, spec, trailing, span);    // right band
    SGAddGrid(t, spec, span, span);        // middle

    CGPoint near = CGPointMake(R, 0), far = CGPointMake(-R, 1);   // (base, scale) of a corner centre on each axis
    SGAddCorner(t, spec, near, near, M_PI, 1.5 * M_PI, rings, angles);
    SGAddCorner(t, spec, far, near, 1.5 * M_PI, 2 * M_PI, rings, angles);
    SGAddCorner(t, spec, far, far, M_PI_2, 0, rings, angles);
    SGAddCorner(t, spec, near, far, M_PI, M_PI_2, rings, angles);
    return t;
}

// The mesh for `size`, from the cached template of its corner radius.
static id SGMakeGlassMesh(CGSize size, CGFloat radius, CGFloat magnification, CGFloat lensScale, BOOL classic) {
    radius = MIN(radius, MIN(size.width, size.height) / 2);
    if (radius <= 0 || size.width < 1 || size.height < 1) return nil;

    static NSCache<NSNumber *, SGMeshTemplate *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 24; });
    NSNumber *key = @(round(radius * 10) * 2 + (classic ? 1 : 0));
    SGMeshTemplate *tmpl = [cache objectForKey:key];
    if (!tmpl) {
        tmpl = SGBuildTemplate(radius, classic);
        [cache setObject:tmpl forKey:key];
    }

    CGFloat W = size.width, H = size.height;
    CGFloat insetU = kInsetPoints / W, insetV = kInsetPoints / H;
    CGFloat usableU = 1 - 2 * insetU, usableV = 1 - 2 * insetV;
    // The rim's shift in points: the measured strength over the band, the whole lens scaled down on a small pane.
    CGFloat shift = (classic ? kClassicShift : kLensStrength * SGEdgeBand(radius) * MIN(1, MIN(W, H) / 2 / kLensSizeRef)) * lensScale;
    CGFloat dU = shift / W, dV = shift / H;

    NSUInteger vertexCount = tmpl.vertices.length / sizeof(SGTemplateVertex);
    const SGTemplateVertex *templates = tmpl.vertices.bytes;
    SGMeshVertex *vertices = malloc(sizeof(SGMeshVertex) * vertexCount);
    for (NSUInteger i = 0; i < vertexCount; i++) {
        SGTemplateVertex v = templates[i];
        CGFloat u = insetU + (v.baseX + v.scaleX * W) / W * usableU;
        CGFloat w = insetV + (v.baseY + v.scaleY * H) / H * usableV;
        // Magnified about the middle: the point samples nearer the middle, by the magnification, then bends as usual.
        CGFloat su = 0.5 + (u - 0.5) / magnification, sw = 0.5 + (w - 0.5) / magnification;
        CGPoint from = CGPointMake(MAX(0.0, MIN(1.0, su + v.dispX * dU)), MAX(0.0, MIN(1.0, sw + v.dispY * dV)));
        vertices[i] = (SGMeshVertex){from, {u, w, v.depth}};
    }
    id transform = SGMakeMeshTransform(vertices, vertexCount, (SGMeshFace *)tmpl.faces.bytes, tmpl.faces.length / sizeof(SGMeshFace));
    free(vertices);
    return transform;
}

#pragma mark - the rim's light

// The light the system's glass draws along its rim, as adaptive_liquid_glass measured it (shaders/liquid_glass.frag,
// regularDark): a white line kRimWidth wide whose brightness follows which way the rim faces, kRimIntensity times
// max(n . L, 0) where the rim faces the light, top left (lightAngle -3 pi / 4), and kRimBack of that where it faces
// away, so the sides are lit by their slant and the corners across the light are dark. No colour fringe: the measured
// glass has none (dispersion 0), and ours, with a brighter glare, drew the sides as a frosted white outline.
//
// The brightness is a small picture of the rim's normal at every point (the normal changes slowly, so a point per
// pixel is enough), cached by size, under a mask of the line itself, which stays sharp.
static const CGFloat kRimWidth = 1.36, kRimIntensity = 0.33, kRimBack = 0.35;
static NSString *const kSpecularName = @"sg.specular";

static CGPathRef rimPath(CGRect bounds, CGFloat inset, CGFloat radius) {
    CGRect rect = CGRectInset(bounds, inset, inset);
    CGFloat r = MAX(0, MIN(radius - inset, MIN(rect.size.width, rect.size.height) / 2));
    return [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:r].CGPath;
}

static CAShapeLayer *stroke(CGColorRef color, CGFloat width) {
    CAShapeLayer *line = [CAShapeLayer layer];
    line.fillColor = nil;
    line.strokeColor = color;
    line.lineWidth = width;
    return line;
}

// White at the rim's brightness for its normal at each point, a point per pixel.
// An object, so the caller holds it however soon the cache lets it go.
static id SGRimLight(CGSize size, CGFloat radius) {
    static NSCache<NSString *, id> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; cache.countLimit = 32; });
    size_t w = (size_t)MAX(2, ceil(size.width)), h = (size_t)MAX(2, ceil(size.height));
    radius = MIN(radius, MIN(size.width, size.height) / 2);
    NSString *key = [NSString stringWithFormat:@"%zu %zu %.1f", w, h, radius];
    id cached = [cache objectForKey:key];
    if (cached) return cached;

    const CGFloat lx = -M_SQRT1_2, ly = -M_SQRT1_2;   // towards the light, top left, in the layer's y-down space
    uint8_t *pixels = calloc(w * h, 4);
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0; x < w; x++) {
            CGFloat nx, ny;
            SGRoundedRectSDF(x + 0.5, y + 0.5, size.width, size.height, radius, &nx, &ny);
            CGFloat facing = nx * lx + ny * ly;
            CGFloat a = kRimIntensity * (MAX(facing, 0) + kRimBack * MAX(-facing, 0));
            uint8_t v = (uint8_t)lround(MIN(1, a) * 255);
            uint8_t *p = pixels + (y * w + x) * 4;
            p[0] = p[1] = p[2] = p[3] = v;   // premultiplied white
        }
    }
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, w, h, 8, w * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGImageRef image = context ? CGBitmapContextCreateImage(context) : NULL;
    if (context) CGContextRelease(context);
    CGColorSpaceRelease(space);
    free(pixels);
    if (!image) return nil;
    id object = (__bridge_transfer id)image;
    [cache setObject:object forKey:key];
    return object;
}

// The classic pane's rim: the glare it first had, a one point line bright at the top-left and the bottom-right corners
// and gone along the rest.
static NSString *const kClassicSpecularName = @"sg.specular.classic";

void SGLegacyGlassClassicSpecular(CALayer *host, CGRect bounds, CGFloat radius) {
    if (@available(iOS 26.0, *)) return;
    if (!host || bounds.size.width < 2 || bounds.size.height < 2) return;
    CAGradientLayer *rim = nil;
    for (CALayer *sub in host.sublayers) {
        if ([sub.name isEqualToString:kClassicSpecularName]) rim = (CAGradientLayer *)sub;
        if ([sub.name isEqualToString:kSpecularName]) sub.hidden = YES;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!rim) {
        rim = [CAGradientLayer layer];
        rim.name = kClassicSpecularName;
        rim.startPoint = CGPointMake(0, 0);
        rim.endPoint = CGPointMake(1, 1);
        rim.locations = @[@0, @0.28, @0.72, @1];
        rim.colors = @[(id)[UIColor colorWithWhite:1 alpha:0.75].CGColor,
                       (id)[UIColor colorWithWhite:1 alpha:0].CGColor,
                       (id)[UIColor colorWithWhite:1 alpha:0].CGColor,
                       (id)[UIColor colorWithWhite:1 alpha:0.55].CGColor];
        rim.zPosition = 100;
        rim.mask = stroke(UIColor.whiteColor.CGColor, 1);
        [host addSublayer:rim];
    }
    rim.hidden = NO;
    rim.frame = bounds;
    CAShapeLayer *line = (CAShapeLayer *)rim.mask;
    line.frame = rim.bounds;
    line.path = rimPath(rim.bounds, 0.5, radius);
    [CATransaction commit];
}

void SGLegacyGlassSpecular(CALayer *host, CGRect bounds, CGFloat radius) {
    if (@available(iOS 26.0, *)) return;
    if (!host || bounds.size.width < 2 || bounds.size.height < 2) return;
    CALayer *rim = nil;
    for (CALayer *sub in host.sublayers) {
        if ([sub.name isEqualToString:kSpecularName]) rim = sub;
        // A pane that has grown out of the big panes' size draws this rim instead of theirs.
        if ([sub.name isEqualToString:kClassicSpecularName]) sub.hidden = YES;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!rim) {
        rim = [CALayer layer];
        rim.name = kSpecularName;
        rim.contentsGravity = kCAGravityResize;
        // Over everything else in the host: a thin line, and the film or content under it must not hide it.
        rim.zPosition = 100;
        rim.mask = stroke(UIColor.whiteColor.CGColor, kRimWidth);
        [host addSublayer:rim];
    }
    rim.hidden = NO;
    rim.frame = bounds;
    id light = SGRimLight(bounds.size, radius);
    if (light != rim.contents) rim.contents = light;
    CAShapeLayer *line = (CAShapeLayer *)rim.mask;
    line.frame = rim.bounds;
    line.path = rimPath(rim.bounds, kRimWidth / 2, radius);
    [CATransaction commit];
}

#pragma mark - SGLegacyGlassView

// A pane resized again this soon after the last time is being resized frame by frame (a bar's stand-in following the
// player as it closes, BarTransition.x): the mesh is made for the pane's proportions rather than its points, and the rim's
// light stretches with its layer, so in between only frames move and both are made again once the size has stood still
// for kSettle. Made on every frame, the light's bitmap (every pixel worked out on the CPU) and the mesh dropped frames on
// an iPhone 11.
static const CFTimeInterval kResizeBurst = 0.05, kSettle = 0.1;

@implementation SGLegacyGlassView {
    CALayer *_backdropLayer;
    SGNoActionsDelegate *_backdropDelegate;
    CGSize _meshSize;
    CGFloat _meshRadius;
    CFTimeInterval _lastResize;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.layer.cornerCurve = kCACornerCurveCircular;
    self.clipsToBounds = YES;

    _blurRadius = 2.0;
    _magnification = 1;
    _lensScale = 1;
    _backdropDelegate = [SGNoActionsDelegate new];
    _backdropLayer = SGMakeBackdropLayer(_backdropDelegate);
    if (_backdropLayer) [self.layer addSublayer:_backdropLayer];

    _contentView = [[UIView alloc] initWithFrame:self.bounds];
    _contentView.backgroundColor = UIColor.clearColor;
    _contentView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_contentView];
    return self;
}

- (void)setCornerRadius:(CGFloat)cornerRadius {
    if (_cornerRadius == cornerRadius) return;
    _cornerRadius = cornerRadius;
    [self setNeedsLayout];
}

- (void)setBlurRadius:(CGFloat)blurRadius {
    if (_blurRadius == blurRadius) return;
    _blurRadius = blurRadius;
    NSArray *filters = SGBackdropFiltersOf(blurRadius, !_clear);
    if (filters.count) _backdropLayer.filters = filters;
}

- (void)setClear:(BOOL)clear {
    if (_clear == clear) return;
    _clear = clear;
    if (clear) _blurRadius = 1.2;
    NSArray *filters = SGBackdropFiltersOf(_blurRadius, !clear);
    _backdropLayer.filters = filters.count ? filters : nil;
}

- (void)setMagnification:(CGFloat)magnification {
    magnification = MAX(1, magnification);
    if (_magnification == magnification) return;
    _magnification = magnification;
    _meshSize = CGSizeZero;   // the mesh is made again on the next pass
    [self setNeedsLayout];
}

- (void)setLensScale:(CGFloat)lensScale {
    lensScale = MAX(0, lensScale);
    if (_lensScale == lensScale) return;
    _lensScale = lensScale;
    _meshSize = CGSizeZero;
    [self setNeedsLayout];
}

- (void)setSharp:(BOOL)sharp {
    if (_sharp == sharp) return;
    _sharp = sharp;
    // A layer made by hand draws at 1x unless told otherwise; the backdrop at the screen's scale keeps what it shows
    // as sharp as the screen, at nine times the pixels on a 3x screen, so only a pane that asks gets it.
    CGFloat scale = sharp ? UIScreen.mainScreen.scale : 1.0;
    _backdropLayer.contentsScale = scale;
    _backdropLayer.rasterizationScale = scale;
}

- (BOOL)classic {
    return MIN(self.bounds.size.width, self.bounds.size.height) >= kClassicMinSide;
}

- (void)setCapsule:(BOOL)capsule {
    if (_capsule == capsule) return;
    _capsule = capsule;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    CGFloat radius = _capsule ? MIN(size.width, size.height) / 2 : _cornerRadius;
    if (CGSizeEqualToSize(size, _meshSize) && radius == _meshRadius) return;
    BOOL classic = self.classic;
    CFTimeInterval now = CACurrentMediaTime();
    BOOL burst = _meshSize.width >= 1 && now - _lastResize < kResizeBurst
                 && classic == (MIN(_meshSize.width, _meshSize.height) >= kClassicMinSide);
    _lastResize = now;
    if (burst) {
        [self followSize:size radius:radius];
        [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(settle) object:nil];
        [self performSelector:@selector(settle) withObject:nil afterDelay:kSettle inModes:@[NSRunLoopCommonModes]];
        return;
    }
    if (_rimless) {
        for (CALayer *sub in self.layer.sublayers) {
            if ([sub.name isEqualToString:kSpecularName] || [sub.name isEqualToString:kClassicSpecularName]) sub.hidden = YES;
        }
    } else if (classic) {
        SGLegacyGlassClassicSpecular(self.layer, self.bounds, radius);
    } else {
        SGLegacyGlassSpecular(self.layer, self.bounds, radius);
    }
    _meshSize = size;
    _meshRadius = radius;

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius = radius;
    _backdropLayer.frame = self.bounds;
    id mesh = SGMakeGlassMesh(size, radius, _magnification, _lensScale, classic);
    // No mesh (a radius of 0): the last one goes rather than staying for a shape it was not made for.
    [_backdropLayer setValue:mesh forKey:@"meshTransform"];
    [CATransaction commit];
}

// The frames alone, mid-resize: the mesh and the rim's light keep the size they were made for.
- (void)followSize:(CGSize)size radius:(CGFloat)radius {
    CGRect bounds = self.bounds;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.layer.cornerRadius = radius;
    _backdropLayer.frame = bounds;
    for (CALayer *sub in self.layer.sublayers) {
        BOOL light = [sub.name isEqualToString:kSpecularName], classic = [sub.name isEqualToString:kClassicSpecularName];
        if ((!light && !classic) || sub.hidden) continue;
        sub.frame = bounds;
        CAShapeLayer *line = (CAShapeLayer *)sub.mask;
        line.frame = sub.bounds;
        line.path = rimPath(sub.bounds, light ? kRimWidth / 2 : 0.5, radius);
    }
    [CATransaction commit];
}

// The size has stood still: the mesh and the light made for it.
- (void)settle {
    _lastResize = 0;
    _meshSize = CGSizeZero;
    [self setNeedsLayout];
}

@end
