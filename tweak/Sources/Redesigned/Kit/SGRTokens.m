#import <CoreText/SFNTLayoutTypes.h>
#import "Core/SGCore.h"
#import "SGRTokens.h"
#import "SGRAccent.h"

const CGFloat SGRSideMargin = 16;
const CGFloat SGRGrid = 8;
const CGFloat SGRRadiusArtwork = 12;
const CGFloat SGRRadiusCard = 16;
const CGFloat SGRRadiusCover = 8;
const CGFloat SGRRadiusThumb = 6;
const CGFloat SGRGlassCircleSize = 44;
const CGFloat SGRActionHeight = 48;
const CGFloat SGRActionSpacing = 12;
const CGFloat SGRGlassSpacing = 16;
const NSTimeInterval SGRCrossfade = 0.35;

// A layout spring settles in about this long without overshooting; a press gives a little back.
static const NSTimeInterval kLayoutDuration = 0.45, kPressDuration = 0.32;
// The tab bar's minimize runs on every scroll, so it is quicker than the 0.3 to 0.4 s Apple gives a
// repositioning spring.
static const NSTimeInterval kBarDuration = 0.26;
static const CGFloat kPressDamping = 0.62;
// A response lands within the press feedback's budget, on a curve that is most of the way there at once.
static const NSTimeInterval kRespondDuration = 0.2;
// An exit is quicker still; Native/Player/PlayerGestures.x keeps its own copy of the value.
static const NSTimeInterval kExitDuration = 0.15;

UIColor *SGRPrimary(void) {
    return UIColor.whiteColor;
}

UIColor *SGRSecondary(void) {
    return [UIColor colorWithWhite:1 alpha:SGRIncreaseContrast() ? 0.80 : 0.65];
}

UIColor *SGRTertiary(void) {
    return [UIColor colorWithWhite:1 alpha:SGRIncreaseContrast() ? 0.60 : 0.40];
}

// Read per call: the accent is stored as it is picked, and the color row reads it the same way.
UIColor *SGRAccent(void) {
    return SGRAccentColor() ?: [UIColor colorWithRed:0x1E / 255.0 green:0xD7 / 255.0 blue:0x60 / 255.0 alpha:1];
}

UIColor *SGRNeutralField(void) {
    return [UIColor colorWithRed:0x12 / 255.0 green:0x12 / 255.0 blue:0x12 / 255.0 alpha:1];
}

UIColor *SGRSolidGlassFill(void) {
    return [UIColor colorWithWhite:1 alpha:0.16];
}

UIColor *SGRHairline(void) {
    return [UIColor colorWithWhite:1 alpha:SGRIncreaseContrast() ? 0.20 : 0.12];
}

UIColor *SGRElevated(UIColor *field) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    if (![field getRed:&r green:&g blue:&b alpha:&a]) return [UIColor colorWithWhite:1 alpha:0.08];
    // 12% toward white keeps a card on a black field clear of the grays SGRAmoled.x turns black.
    CGFloat lift = 0.12;
    return [UIColor colorWithRed:r + (1 - r) * lift green:g + (1 - g) * lift blue:b + (1 - b) * lift alpha:1];
}

UIFont *SGRFont(UIFontTextStyle style, UIFontWeight weight, UIContentSizeCategory largest) {
    UIContentSizeCategory current = UIApplication.sharedApplication.preferredContentSizeCategory;
    if (largest && UIContentSizeCategoryCompareToCategory(current, largest) == NSOrderedDescending) current = largest;
    // Asked for on every layout pass of the Search and Library headers. A font is immutable and the same inputs
    // give the same one, so each is kept per input; the live category above and Bold Text are read on every call,
    // so a Dynamic Type change is a new key at once.
    // A string key: an array's hash is its count, so array keys would all collide.
    static NSMutableDictionary<NSString *, UIFont *> *fonts;
    if (!fonts) fonts = [NSMutableDictionary dictionary];
    NSString *key = [NSString stringWithFormat:@"%@|%g|%@|%@|%d", style, weight, largest ?: @"", current ?: @"", UIAccessibilityIsBoldTextEnabled()];
    UIFont *font = fonts[key];
    if (font) return font;
    UITraitCollection *traits = [UITraitCollection traitCollectionWithPreferredContentSizeCategory:current];
    CGFloat size = [UIFont preferredFontForTextStyle:style compatibleWithTraitCollection:traits].pointSize;
    font = [UIFont systemFontOfSize:size weight:weight];
    fonts[key] = font;
    return font;
}

UIFont *SGRMonospacedDigitsFont(UIFont *font) {
    if (!font) return nil;
    NSArray *features = @[@{UIFontFeatureTypeIdentifierKey: @(kNumberSpacingType), UIFontFeatureSelectorIdentifierKey: @(kMonospacedNumbersSelector)}];
    UIFontDescriptor *descriptor = [font.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute: features}];
    return [UIFont fontWithDescriptor:descriptor size:font.pointSize];
}

BOOL SGRReduceMotion(void) {
    return UIAccessibilityIsReduceMotionEnabled();
}

BOOL SGRReduceTransparency(void) {
    return UIAccessibilityIsReduceTransparencyEnabled();
}

BOOL SGRIncreaseContrast(void) {
    return UIAccessibilityDarkerSystemColorsEnabled();
}

void SGRAnimate(SGRMotion motion, void (^animations)(void), void (^completion)(BOOL finished)) {
    if (!animations) return;
    if ((motion == SGRMotionLayout || motion == SGRMotionPress || motion == SGRMotionBar) && SGRReduceMotion()) {
        [UIView performWithoutAnimation:animations];
        if (completion) completion(YES);
        return;
    }
    UIViewAnimationOptions options = UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState;
    switch (motion) {
        case SGRMotionLayout:
            [UIView animateWithDuration:kLayoutDuration delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:options animations:animations completion:completion];
            break;
        case SGRMotionBar:
            [UIView animateWithDuration:kBarDuration delay:0 usingSpringWithDamping:1 initialSpringVelocity:0 options:options animations:animations completion:completion];
            break;
        case SGRMotionPress:
            [UIView animateWithDuration:kPressDuration delay:0 usingSpringWithDamping:kPressDamping initialSpringVelocity:0 options:options animations:animations completion:completion];
            break;
        case SGRMotionFade:
            [UIView animateWithDuration:SGRCrossfade delay:0 options:options | UIViewAnimationOptionCurveEaseInOut animations:animations completion:completion];
            break;
        case SGRMotionRespond: {
            // UIView's own curves are too soft for this; a property animator takes any curve, and like the
            // others it starts from what is on screen, so it can take over a fade halfway out.
            UICubicTimingParameters *curve = [[UICubicTimingParameters alloc] initWithControlPoint1:CGPointMake(0.23, 1)
                                                                                     controlPoint2:CGPointMake(0.32, 1)];
            UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:kRespondDuration timingParameters:curve];
            [animator addAnimations:animations];
            if (completion) [animator addCompletion:^(UIViewAnimatingPosition position) { completion(position == UIViewAnimatingPositionEnd); }];
            [animator startAnimation];
            break;
        }
        case SGRMotionExit:
            [UIView animateWithDuration:kExitDuration delay:0 options:options | UIViewAnimationOptionCurveEaseOut animations:animations completion:completion];
            break;
    }
}

void SGRAnimateLayout(UIView *host, void (^animations)(void), void (^completion)(BOOL finished)) {
    if (!animations) return;
    if (!SGRReduceMotion() || !host.window) {
        SGRAnimate(SGRMotionLayout, animations, completion);
        return;
    }
    // Snapshot the host, so the layout changes in place while the old picture dissolves.
    [UIView transitionWithView:host duration:0.2
        options:UIViewAnimationOptionTransitionCrossDissolve | UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
        animations:animations completion:completion];
}
