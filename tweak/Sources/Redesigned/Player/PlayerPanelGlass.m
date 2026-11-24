// Player redesign, iOS < 26: the glass of the Speed, Pitch & Reverb panel (SGPlayerShowSpeedPitchPanel), a popover
// from the ⋯. On iOS 26 the system gives the popover Liquid Glass, as it does the ⋯ menu it comes from. Below it the
// popover is a plain blur while the menu wears the mod's glass (ContextMenu/ContextMenuGlass.x), so the panel would
// open from the glass as a different material.
//
// The popover stays the system's, so its animation does too (a background class of the mod's own took it away): its
// blur is hidden and the menu's pane (SGRMenuGlass) goes in on the view that held it. The blur is looked for in the
// views beside the panel's own and beside each ancestor's, nested or not, since UIKit puts it at a different depth
// from one iOS to the next, and the chrome may be built after the panel's first layout, so the pass runs again as it
// settles. If no blur is found, nothing is changed.
//
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Redesigned/Kit/SGRPass.h"
#import "Shared/Player/SpeedPitch.h"

// The black over the pane: the menu's own, so a panel from the ⋯ (Speed, Pitch & Reverb, Lyrics Source) reads as dark
// as the list it opens from. A lighter one, picked for the sliders, left both panels' text with too little contrast.
static const CGFloat kPanelDim = SGRMenuDim;
static char kPanelGlassKey;
static char kPanelSettleKey;

static BOOL isBlur(UIView *view) {
    if ([view isKindOfClass:UIVisualEffectView.class]) return YES;
    // A bare backdrop, one that is not the inside of a blur.
    return ![view.superview isKindOfClass:UIVisualEffectView.class] && [NSStringFromClass(view.class) containsString:@"Backdrop"];
}

// The popover's own blurs: those in the subtrees beside the branch that holds `content`, from its parent up. The mod's
// own pane is not one of them.
static NSArray<UIView *> *chromeBlurs(UIView *content) {
    NSMutableArray<UIView *> *blurs = [NSMutableArray array];
    UIView *branch = content;
    UIView *host = content.superview;
    for (int depth = 0; host && depth < 5; depth++, branch = host, host = host.superview) {
        if ([host isKindOfClass:UIWindow.class] || [NSStringFromClass(host.class) isEqualToString:@"UITransitionView"]) break;
        for (UIView *sub in host.subviews) {
            if (sub == branch) continue;
            SGForEachView(sub, ^(UIView *view) {
                if (!isBlur(view) || objc_getAssociatedObject(view.superview, &kPanelGlassKey) == view) return;
                [blurs addObject:view];
            });
        }
        if (blurs.count) break;
    }
    return blurs;
}

static void logChain(UIView *content) {
    static int logged;
    if (logged++ >= 2) return;
    NSMutableString *chain = [NSMutableString string];
    int depth = 0;
    for (UIView *view = content; view && depth < 6; view = view.superview, depth++) {
        [chain appendFormat:@" > %@(%d)", NSStringFromClass(view.class), (int)view.subviews.count];
    }
    SGLog(@"speed and pitch: no blur beside the panel's branch, its popover keeps the system's:%@", chain);
}

static void stylePanel(UIView *content) {
    if (!content.window) return;
    NSArray<UIView *> *blurs = chromeBlurs(content);
    if (!blurs.count) {
        logChain(content);
        return;
    }
    UIView *host = blurs.firstObject.superview;
    UIView *glass = SGRMenuGlass(host, &kPanelGlassKey, kPanelDim);
    if (!glass) return;
    for (UIView *blur in blurs) {
        if (blur != glass && !blur.hidden) blur.hidden = YES;
    }
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"speed and pitch: glass over %@ of %@", NSStringFromClass(host.class), NSStringFromCGRect(host.bounds)); });
}

void SGPlayerStylePanel(UIView *content) {
    if (!SGRedesignedUI() || !SGBelowiOS26() || !content.window) return;
    stylePanel(content);
    // Again as the popover settles: UIKit may build or re-lay its chrome after the panel's own layout.
    if (objc_getAssociatedObject(content, &kPanelSettleKey)) return;
    objc_setAssociatedObject(content, &kPanelSettleKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    SGRRepeatViewPass(content, @[@0.05, @0.2, @0.5], ^(UIView *v) { stylePanel(v); });
}
