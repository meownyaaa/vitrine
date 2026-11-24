// Redesign, iOS < 26: the chips of the Add to playlist sheet on glass, as the library's chips are.
//
// Tree: the sheet's AssistedCurationTabsElement holds a Home_PillUIKit.PillScrollView, a
// UIScrollView of PillDrawerViews, each with a Home_PillUIKit.PillView 32pt tall (From your Liked Songs,
// Recently played, Songs). The pill paints its own layer, #333333 unselected and a solid colour of its own (the
// accent) selected, so, unlike Encore's chips (SGRChips.m), the unselected fill is an opaque grey and not a
// translucent white.
//
// The glass goes in the pill itself, first among its subviews, as in the library (Library/LibraryHeader.x): an
// unselected pill's grey goes and a glass capsule stands behind its label; a selected pill keeps its colour, and
// its colour is made translucent over the glass, which then shows through it as a tint. Spotify paints the pill again as it is selected and let
// go, which lays nothing out, so SGRRepaint.x keeps the grey off a dressed pill and tells it (SGRIsSheetPill,
// SGRSheetPillPainted).
//
// Only the pills inside a sheet (id=sheet-view): Home's own PillScrollView is not dressed here.
#import "Core/SGCore.h"
#import "SGRChips.h"
#import "SGRGlass.h"
#import "SGRPass.h"

static char kPillGlassKey, kPillDressedKey;
// Set once a pill has been dressed: until then SGRRepaint.x's hook, which hears every layer's paint, does no lookup.
static BOOL sLive;

// The flat grey Spotify paints an unselected pill with: opaque, neutral, dark. A selected pill is a colour or a
// bright one, never this.
BOOL SGRIsPillGrey(CGColorRef color) {
    if (!color || CFGetTypeID(color) != CGColorGetTypeID() || CGColorGetAlpha(color) < 0.05) return NO;
    const CGFloat *c = CGColorGetComponents(color);
    size_t n = CGColorGetNumberOfComponents(color);
    if (n == 2) return c[0] <= 0.35;
    if (n < 3) return NO;
    return c[0] <= 0.35 && fabs(c[0] - c[1]) < 0.03 && fabs(c[1] - c[2]) < 0.03;
}

BOOL SGRPillIsSelected(UIView *pill) {
    CGColorRef paint = pill.layer.backgroundColor;
    return paint && CGColorGetAlpha(paint) > 0.3 && !SGRIsPillGrey(paint);
}

// A pill grows under a finger with the legacy glass (SGGlassInteractive) and the scroll view it stands in clips to
// its bounds, which cut the grown capsule off at its edges. The row is as wide as the sheet, so unclipping up to it
// shows nothing that was not on screen already. The pill is its own fill.
static void glassPill(UIView *pill) {
    if (SGUseLegacyGlass()) SGRUnclipUpTo(pill.superview, ^BOOL(UIView *v) { return [NSStringFromClass(v.class) hasSuffix:@"PillScrollView"]; });
    SGRGlassChip(pill, pill, SGRPillIsSelected(pill), &kPillGlassKey);
}

static void dressPill(UIView *pill) {
    if (!pill.window || !SGRSheetPaneOf(pill)) return;
    if (!objc_getAssociatedObject(pill, &kPillDressedKey)) {
        objc_setAssociatedObject(pill, &kPillDressedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        sLive = YES;
        SGLog(@"sheet pills: glass over a pill of %@", NSStringFromCGRect(pill.bounds));
    }
    glassPill(pill);
}

BOOL SGRSheetPillsLive(void) {
    return sLive;
}

BOOL SGRIsSheetPill(UIView *view) {
    return objc_getAssociatedObject(view, &kPillDressedKey) != nil;
}

void SGRSheetPillPainted(UIView *pill) {
    if (pill.window && SGRIsSheetPill(pill)) glassPill(pill);
}

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    // The class as the app has it: mangled, or dotted as the trees print it.
    Class pill = NSClassFromString(@"_TtC14Home_PillUIKit8PillView") ?: NSClassFromString(@"Home_PillUIKit.PillView");
    if (pill) {
        SGRPassView(pill, ^(UIView *v) { dressPill(v); });
    } else {
        SGLog(@"class Home_PillUIKit.PillView not found, the chips of the Add to playlist sheet keep Spotify's grey");
    }
}
