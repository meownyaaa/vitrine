#import "SGRDrawnText.h"
#import "Core/SGCore.h"
#import <objc/runtime.h>
#import <objc/message.h>

// What was decided for a drawing view: @YES it is inverted, @NO its ink is left alone. Absent until it has drawn.
static char kInkKey;

typedef NS_ENUM(NSInteger, SGRInk) { SGRInkUnknown, SGRInkDark, SGRInkOther };

static BOOL isDrawingView(UIView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@"CGDrawingView"];
}

// The color of the ink a drawing view has drawn: the alpha-weighted average of its pixels, which a premultiplied
// bitmap gives as the sum of the color channels over the sum of the alphas.
static SGRInk inkOf(UIView *view) {
    CGSize size = view.bounds.size;
    size_t width = (size_t)ceil(size.width), height = (size_t)ceil(size.height);
    if (width < 1 || height < 1 || width > 800 || height > 400) return SGRInkUnknown;
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, width * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!ctx) return SGRInkUnknown;
    // UIKit's orientation, so the layer draws upright; the average does not care, a drawing that is clipped would.
    CGContextTranslateCTM(ctx, 0, (CGFloat)height);
    CGContextScaleCTM(ctx, 1, -1);
    [view.layer renderInContext:ctx];
    const uint8_t *data = CGBitmapContextGetData(ctx);
    double red = 0, green = 0, blue = 0, alpha = 0;
    if (data) {
        for (size_t i = 0; i < width * height; i++) {
            const uint8_t *pixel = data + i * 4;
            red += pixel[0];
            green += pixel[1];
            blue += pixel[2];
            alpha += pixel[3];
        }
    }
    CGContextRelease(ctx);
    // Less than a pixel's worth of ink: nothing has been drawn yet.
    if (alpha < 255) return SGRInkUnknown;
    CGFloat r = red / alpha, g = green / alpha, b = blue / alpha;
    CGFloat top = MAX(r, MAX(g, b)), bottom = MIN(r, MIN(g, b));
    return top < 0.3 && top - bottom < 0.1 ? SGRInkDark : SGRInkOther;
}

static void invert(UIView *view) {
    id filter = SGFilterOfType(@"colorInvert");
    if (filter) view.layer.filters = @[filter];
}

void SGRLightenDrawnText(UIView *root) {
    SGForEachView(root, ^(UIView *view) {
        if (!isDrawingView(view) || objc_getAssociatedObject(view, &kInkKey)) return;
        SGRInk ink = inkOf(view);
        if (ink == SGRInkUnknown) return;
        objc_setAssociatedObject(view, &kInkKey, @(ink == SGRInkDark), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (ink == SGRInkDark) invert(view);
    });
}

static BOOL isOpaqueWhite(CGColorRef color) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    UIColor *ui = [UIColor colorWithCGColor:color];
    if ([ui getRed:&r green:&g blue:&b alpha:&a]) return a > 0.95 && MIN(r, MIN(g, b)) > 0.95;
    CGFloat white = 0;
    return [ui getWhite:&white alpha:&a] && a > 0.95 && white > 0.95;
}

void SGRClearHostedFill(UIView *root) {
    SGForEachView(root, ^(UIView *view) {
        if (![NSStringFromClass(view.class) containsString:@"SwiftUI"]) return;
        if (isOpaqueWhite(view.layer.backgroundColor)) view.layer.backgroundColor = NULL;
    });
}

static BOOL isDarkNeutral(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) return MAX(r, MAX(g, b)) < 0.3 && MAX(r, MAX(g, b)) - MIN(r, MIN(g, b)) < 0.1;
    CGFloat white = 0;
    return [color getWhite:&white alpha:&a] && white < 0.3;
}

void SGRLightenLabels(UIView *root, UIView *except) {
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UILabel.class] || (except && [view isDescendantOfView:except])) return;
        UILabel *label = (UILabel *)view;
        if (isDarkNeutral(label.textColor)) label.textColor = UIColor.whiteColor;
    });
}
