// Redesign: Spotify's outlined capsule buttons (LegacyUI_ECMCoreKit.CallToActionButton: Follow on an artist row in Search
// and on the artist's About card, See more under the artist's popular tracks) are a 1 pt white ring on nothing, the one
// control of Spotify's own look left on those pages. Here the ring goes and the button stands on a glass capsule, as the
// chips do (SGRChips.h). A button Spotify fills (a solid call to action) keeps its paint.
//
// Tree: CallToActionButton 72.5x34, r=17, clips, layer.borderWidth 1, background clear, a UIButtonLabel inside it.
// Spotify sets the ring again as the button changes state, with a layout, so every pass of the button's takes it off
// again.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "SGRChips.h"
#import "SGRPass.h"
#import "SGRRestyle.h"

static char kRingGlassKey, kOutlinedKey;

static void dressOutlined(UIView *button) {
    if (!button.window || button.bounds.size.height < 1) return;
    // A button Spotify fills (a reused cell's, given a solid call to action) is no outlined one any more: its paint stays
    // and the glass goes. The fill this file takes off is never a visible one, so this is Spotify's.
    if (SGIsVisibleColor(button.layer.backgroundColor)) {
        if (objc_getAssociatedObject(button, &kOutlinedKey)) {
            objc_setAssociatedObject(button, &kOutlinedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            UIView *glass = objc_getAssociatedObject(button, &kRingGlassKey);
            if (glass && !glass.hidden) glass.hidden = YES;
        }
        return;
    }
    BOOL ringed = button.layer.borderWidth > 0 && !SGIsVisibleColor(button.layer.backgroundColor);
    if (!ringed && !objc_getAssociatedObject(button, &kOutlinedKey)) return;
    objc_setAssociatedObject(button, &kOutlinedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (button.layer.borderWidth > 0) button.layer.borderWidth = 0;
    SGRGlassChip(button, button, NO, &kRingGlassKey);
}

%ctor {
    // Below iOS 26 only: on iOS 26 the page keeps the look it has on main.
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class button = SGRSwiftClass(@"LegacyUI_ECMCoreKit", @"CallToActionButton");
    if (button) SGRPassView(button, ^(UIView *v) { dressOutlined(v); });
    else SGLog(@"class LegacyUI_ECMCoreKit.CallToActionButton not found, outlined buttons keep Spotify's ring");
}
