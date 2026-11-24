#import "Core/SGCore.h"
#import "SGRChips.h"
#import "SGRGlass.h"
#import "SGRRestyle.h"

// Encore_ChipsKit's own classes, as the trees print them.
static NSString *const kChipClass = @"_TtCE15Encore_ChipsKitO16EncoreFoundation6Encore8ChipView";
static NSString *const kPillClass = @"_TtCE15Encore_ChipsKitO16EncoreFoundation6Encore8PillView";
static NSString *const kRowClass = @"_TtCE15Encore_ChipsKitO16EncoreFoundation6Encore15NestedChipsView";

static char kChipGlassKey, kChipWatchedKey;

// How much of its colour a selected chip keeps: enough for the label (#121212 on it) to read, little enough for the
// glass under it to show as a tint.
static const CGFloat kSelectedTintAlpha = 0.62;

CGColorRef SGRSelectedChipPaint(CGColorRef paint) {
    if (!paint || CFGetTypeID(paint) != CGColorGetTypeID() || CGColorGetAlpha(paint) < 0.95) return paint;
    return (CGColorRef)CFAutorelease(CGColorCreateCopyWithAlpha(paint, kSelectedTintAlpha));
}

void SGRTintSelectedFill(UIView *fill) {
    CGColorRef paint = fill.layer.backgroundColor;
    if (!paint || CGColorGetAlpha(paint) < 0.95) return;
    fill.layer.backgroundColor = SGRSelectedChipPaint(paint);
}

void SGRGlassChip(UIView *chip, UIView *fill, BOOL selected, const void *key) {
    CGSize size = chip.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    if (selected) SGRTintSelectedFill(fill);
    else if (fill.layer.backgroundColor) fill.layer.backgroundColor = NULL;
    SGRGlassCapsuleInside(chip, key, size, NO);
}

static BOOL isChip(UIView *view) {
    return [NSStringFromClass(view.class) isEqualToString:kChipClass];
}

static UIView *pillOf(UIView *chip) {
    for (UIView *sub in chip.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:kPillClass]) return sub;
    }
    return nil;
}

static void glassChip(UIView *chip) {
    // A chip grows under a finger with the legacy glass (SGGlassInteractive), and every view up to the row clips to
    // its bounds, which cut the grown capsule off at its edges.
    if (SGUseLegacyGlass()) SGRUnclipUpTo(chip.superview, ^BOOL(UIView *v) { return [NSStringFromClass(v.class) isEqualToString:kRowClass]; });
    UIView *pill = pillOf(chip);
    SGRGlassChip(chip, pill, pill && SGRPillIsSelected(pill), &kChipGlassKey);
}

static void watchChip(UIView *chip) {
    if (objc_getAssociatedObject(chip, &kChipWatchedKey)) return;
    if (SGRObserveLayout(chip, ^(UIView *view) { glassChip(view); })) {
        objc_setAssociatedObject(chip, &kChipWatchedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

void SGRGlassChipsIn(UIView *root) {
    SGForEachView(root, ^(UIView *v) {
        if (!isChip(v)) return;
        glassChip(v);
        watchChip(v);
    });
}

BOOL SGRIsDressedChipPill(UIView *view) {
    // Asked on every opaque paint in the app: the cheap test first, and the class by pointer, never by its name.
    UIView *chip = view.superview;
    if (!chip || !objc_getAssociatedObject(chip, &kChipWatchedKey)) return NO;
    static Class pill;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ pill = NSClassFromString(kPillClass); });
    return pill && [view isMemberOfClass:pill] && isChip(chip);
}

void SGRDressedChipPainted(UIView *chip) {
    if (chip.window && isChip(chip)) glassChip(chip);
}
