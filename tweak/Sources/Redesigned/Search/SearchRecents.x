// Redesign: the cross of each recent search on glass.
//
// Tree: a row of the Search tab's "Recent searches" (SwipeView, id=Components.UI.RecentItemRowSearch, 390x64) ends with a
// LegacyUI_ECMCoreKit EncoreButton 48x48, id=Components.UI.ClearButton, a11y "Remove", with the 16x16 UIImageView that draws the cross
// at its middle. A glass circle goes inside the button, behind the cross (first in its subviews, Kit/SGRGlass.h), with the faint white
// film the redesign's floating controls carry: plain glass over the list's black would read as nothing. Rows are made again as the
// list scrolls, so every pass of a button dresses it; the glass is made once per button.
//
// The button's class carries a private discriminator in its name (P33_...), so it is found from the trees' spelling by its ending,
// and only the buttons of a recent search row are touched: the same class is every Encore button of Spotify's legacy components.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static char kCrossGlassKey;

// The circle round the cross: the cross is 16pt in a 48pt button, so 32pt leaves it 8pt on each side.
static const CGFloat kCrossSide = 32;

static NSString *const kClearButtonIdentifier = @"Components.UI.ClearButton";
static NSString *const kRecentRowIdentifier = @"Components.UI.RecentItemRowSearch";

static BOOL inRecentRow(UIView *button) {
    int depth = 0;
    for (UIView *v = button.superview; v && depth < 12; v = v.superview, depth++) {
        if ([v.accessibilityIdentifier isEqualToString:kRecentRowIdentifier]) return YES;
    }
    return NO;
}

static void dressCross(UIView *button) {
    if (!button.window || button.bounds.size.width < 1 || ![button.accessibilityIdentifier isEqualToString:kClearButtonIdentifier]) return;
    if (!inRecentRow(button)) return;
    SGRGlassCapsuleInside(button, &kCrossGlassKey, CGSizeMake(kCrossSide, kCrossSide), YES);
    // The press of the glass grows past the circle.
    if (button.clipsToBounds) button.clipsToBounds = NO;
}

// The EncoreButton of LegacyUI_ECMCoreKit: the one class of that module whose name ends in EncoreButton.
static Class encoreButtonClass(void) {
    return NSClassFromString(@"_TtC19LegacyUI_ECMCoreKitP33_7AC6ABDB5A3E514EA5239D6986C3C90912EncoreButton")
        ?: SGRPrivateSwiftClass(@"LegacyUI_ECMCoreKit", @"12EncoreButton");
}

%ctor {
    // Below iOS 26 only: on iOS 26 the crosses keep the look they have on main.
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class button = encoreButtonClass();
    if (button) {
        SGRPassView(button, ^(UIView *v) { dressCross(v); });
    } else {
        SGLog(@"class LegacyUI_ECMCoreKit.EncoreButton not found, the crosses of the recent searches keep their plain look");
    }
}
