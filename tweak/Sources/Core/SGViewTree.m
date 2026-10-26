#import "SGViewTree.h"
#import <objc/runtime.h>

void SGForEachView(UIView *view, void (^fn)(UIView *)) {
    fn(view);
    for (UIView *sub in view.subviews) SGForEachView(sub, fn);
}

CGRect SGFrameIn(UIView *view, UIView *target) {
    return [view.superview convertRect:view.frame toView:target];
}

BOOL SGIsInside(UIView *view, UIView *root) {
    if (!root) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:UIVisualEffectView.class]) return NO;
        if (v == root) return YES;
    }
    return NO;
}

BOOL SGShownUnder(UIView *view, UIView *root) {
    for (UIView *v = view; v && v != root; v = v.superview) {
        if (v.hidden) return NO;
    }
    return YES;
}

BOOL SGIsRow(UIView *view) {
    return [view isKindOfClass:UIStackView.class] && view.bounds.size.width > 200 && ((UIStackView *)view).arrangedSubviews.count >= 2;
}

// Depth first, as SGForEachView walks, stopping at the first view `match` accepts.
static UIView *firstMatch(UIView *view, BOOL (^match)(UIView *view)) {
    if (match(view)) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = firstMatch(sub, match);
        if (found) return found;
    }
    return nil;
}

UIStackView *SGRowIn(UIView *host) {
    return (UIStackView *)firstMatch(host, ^BOOL(UIView *v) { return SGIsRow(v); });
}

BOOL SGClassNamed(Class cls, NSString *marker) {
    if (!cls || !marker) return NO;
    // Markers are literals, so the outer level goes by the pointer and never hashes the string.
    static NSMapTable<NSString *, NSMutableDictionary *> *cache;
    if (!cache) cache = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsOpaqueMemory | NSPointerFunctionsOpaquePersonality
                                              valueOptions:NSPointerFunctionsStrongMemory];
    NSMutableDictionary *answers = [cache objectForKey:marker];
    if (!answers) [cache setObject:(answers = [NSMutableDictionary dictionary]) forKey:marker];
    NSNumber *answer = answers[(id<NSCopying>)cls];
    if (!answer) answers[(id<NSCopying>)cls] = answer = @([NSStringFromClass(cls) containsString:marker]);
    return answer.boolValue;
}

BOOL SGHasClass(UIView *root, NSString *marker) {
    __block BOOL found = NO;
    SGForEachView(root, ^(UIView *v) {
        if (!found && SGClassNamed(v.class, marker)) found = YES;
    });
    return found;
}

@interface SGWeakBox : NSObject
@property (nonatomic, weak) UIView *value;
@end

@implementation SGWeakBox
@end

// The view remembered on `root` under `key`, while it still matches and is still under `root`.
static UIView *remembered(UIView *root, const void *key, BOOL (^match)(UIView *view)) {
    SGWeakBox *box = objc_getAssociatedObject(root, key);
    UIView *cached = box.value;
    return cached && match(cached) && [cached isDescendantOfView:root] ? cached : nil;
}

static void remember(UIView *root, const void *key, UIView *found) {
    SGWeakBox *box = objc_getAssociatedObject(root, key);
    if (!box) {
        box = [SGWeakBox new];
        objc_setAssociatedObject(root, key, box, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    box.value = found;
}

UIView *SGFindRemembered(UIView *root, const void *key, BOOL (^match)(UIView *view)) {
    if (!root) return nil;
    UIView *found = remembered(root, key, match);
    if (found) return found;
    found = firstMatch(root, match);
    if (found) remember(root, key, found);
    return found;
}

// Depth first like firstMatch, testing every key still wanted at each view, so each takes the first view it
// accepts; done once every key has one.
static void matchAll(UIView *view, NSUInteger count, BOOL (^match)(NSUInteger i, UIView *view), UIView *__strong out[], NSUInteger *left) {
    for (NSUInteger i = 0; i < count; i++) {
        if (out[i] || !match(i, view)) continue;
        out[i] = view;
        if (!--*left) return;
    }
    for (UIView *sub in view.subviews) {
        matchAll(sub, count, match, out, left);
        if (!*left) return;
    }
}

void SGFindRememberedAll(UIView *root, NSUInteger count, const void *const keys[], BOOL (^match)(NSUInteger i, UIView *view), UIView *__strong out[]) {
    NSUInteger left = 0;
    for (NSUInteger i = 0; i < count; i++) {
        out[i] = root ? remembered(root, keys[i], ^BOOL(UIView *v) { return match(i, v); }) : nil;
        if (!out[i]) left++;
    }
    if (!root || !left) return;
    matchAll(root, count, match, out, &left);
    for (NSUInteger i = 0; i < count; i++) {
        if (out[i]) remember(root, keys[i], out[i]);
    }
}

UIView *SGFindIdentifier(UIView *root, NSString *prefix, const void *key) {
    return SGFindRemembered(root, key, ^BOOL(UIView *v) { return [v.accessibilityIdentifier hasPrefix:prefix]; });
}

void SGFindIdentifiers(UIView *root, NSUInteger count, NSString *const prefixes[], const void *const keys[], UIView *__strong out[]) {
    SGFindRememberedAll(root, count, keys, ^BOOL(NSUInteger i, UIView *v) { return [v.accessibilityIdentifier hasPrefix:prefixes[i]]; }, out);
}

BOOL SGKeepsColor(UIView *view) {
    return [view isKindOfClass:UIImageView.class] || [view isKindOfClass:UILabel.class] || view.bounds.size.height <= 4;
}

void SGStripBackgrounds(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) return;
    Class cls = view.class;
    // The karaoke views paint nothing to strip and hold a label for every word in sight.
    if (SGClassNamed(cls, @"SGRKaraoke")) return;
    if (!SGKeepsColor(view)) view.layer.backgroundColor = NULL;
    if ([view.layer isKindOfClass:CAGradientLayer.class] || SGClassNamed(cls, @"GradientView")) view.hidden = YES;
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:CAGradientLayer.class]) layer.hidden = YES;
    }
    for (UIView *sub in view.subviews) SGStripBackgrounds(sub);
}

BOOL SGIsVisibleColor(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.05) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    CGFloat brightest = 0;
    for (size_t i = 0; i + 1 < n; i++) brightest = MAX(brightest, c[i]);
    return brightest > 0.08;
}

BOOL SGIsLightColor(CGColorRef color) {
    if (!color || CGColorGetAlpha(color) < 0.5) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    for (size_t i = 0; i + 1 < n; i++) if (c[i] < 0.85) return NO;
    return YES;
}

// Lighter grays (#1F1F1F placeholders, #292929 cards) and translucent paint stay.
BOOL SGIsBaseSurface(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.95) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] <= 0.10;
    if (n < 3) return NO;
    return c[0] <= 0.10 && fabs(c[0] - c[1]) < 0.02 && fabs(c[1] - c[2]) < 0.02;
}

BOOL SGLooksLikeCard(UIView *view, CGColorRef color) {
    CGSize size = view.bounds.size;
    return size.height >= 40 && size.height <= 140 && size.width >= 200 && SGIsVisibleColor(color);
}
