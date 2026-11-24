#import "SGGlass.h"
#import "SGPrefs.h"
#import "SGRuntime.h"
#import "SGUIMode.h"

// +effectWithStyle: is the only initializer UIGlassEffect has; a bare -init leaves the material
// unresolved and the pane renders as a plain blur, while the capsule shape, which is the view's
// own property, still comes out right. Spotify's own Reprise glass builds its effect the same way.
UIVisualEffect *SGGlassEffect(void) {
    Class glass = NSClassFromString(@"UIGlassEffect");
    if ([glass respondsToSelector:@selector(effectWithStyle:)]) return [glass effectWithStyle:0];
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
}

// Read once: the switch, like every switch, takes effect at the next launch. The redesign's only: the native look
// never draws legacy glass.
BOOL SGUseLegacyGlass(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (@available(iOS 26.0, *)) return;
        on = SGRedesignedUI() && SGFlag(SGKeyLegacyGlass, NO) && SGLegacyGlassAvailable();
    });
    return on;
}

static UIView *newPane(void) {
    UIView *glass;
    if (SGUseLegacyGlass()) {
        glass = [[SGLegacyGlassView alloc] initWithFrame:CGRectZero];
    } else {
        glass = [[UIVisualEffectView alloc] initWithEffect:SGGlassEffect()];
    }
    glass.userInteractionEnabled = NO;
    // A pane goes in at index 0, but a host that rebuilds its content puts that in at index 0 too
    // and the pane would end up over it. Depth keeps a pane behind whatever the host draws.
    glass.layer.zPosition = -1;
    return glass;
}

UIView *SGGlassFor(UIView *host, const void *key) {
    UIView *glass = objc_getAssociatedObject(host, key);
    if (!glass) {
        glass = newPane();
        objc_setAssociatedObject(host, key, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    return glass;
}

static char kPanesKey;

UIView *SGGlassAt(UIView *host, NSUInteger index) {
    NSMutableArray<UIView *> *panes = objc_getAssociatedObject(host, &kPanesKey);
    if (!panes) {
        panes = [NSMutableArray array];
        objc_setAssociatedObject(host, &kPanesKey, panes, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    while (panes.count <= index) [panes addObject:newPane()];
    UIView *glass = panes[index];
    glass.hidden = NO;
    if (glass.superview != host) [host insertSubview:glass atIndex:0];
    return glass;
}

void SGHideGlassFrom(UIView *host, NSUInteger count) {
    NSArray<UIView *> *panes = objc_getAssociatedObject(host, &kPanesKey);
    for (NSUInteger i = count; i < panes.count; i++) panes[i].hidden = YES;
}

void SGShapeGlass(UIView *glass, CGFloat radius, BOOL capsule) {
    if ([glass isKindOfClass:SGLegacyGlassView.class]) {
        SGLegacyGlassView *legacy = (SGLegacyGlassView *)glass;
        legacy.cornerRadius = radius;
        legacy.capsule = capsule;
        return;
    }
    // The classes and what they answer to are fixed once loaded; whether this pane takes a configuration is asked each time.
    static Class config, cornerRadius;
    static BOOL capsules, uniform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        config = NSClassFromString(@"UICornerConfiguration");
        cornerRadius = NSClassFromString(@"UICornerRadius");
        capsules = [config respondsToSelector:@selector(capsuleConfiguration)];
        uniform = [config respondsToSelector:@selector(configurationWithUniformRadius:)] && [cornerRadius respondsToSelector:@selector(fixedRadius:)];
    });
    id shape = nil;
    if (config && [glass respondsToSelector:@selector(setCornerConfiguration:)]) {
        if (capsule && capsules) {
            shape = [config capsuleConfiguration];
        } else if (uniform) {
            shape = [config configurationWithUniformRadius:[cornerRadius fixedRadius:radius]];
        }
    }
    if (shape) {
        [glass setCornerConfiguration:shape];
        glass.clipsToBounds = NO;
    } else {
        glass.layer.cornerRadius = capsule ? glass.bounds.size.height / 2 : radius;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
    }
}

void SGPresentDark(UIViewController *controller) {
    controller.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    controller.presentationController.overrideTraitCollection = [UITraitCollection traitCollectionWithUserInterfaceStyle:UIUserInterfaceStyleDark];
}
