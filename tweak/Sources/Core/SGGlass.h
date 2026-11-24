// Glass panes: one pane per host, kept behind the host's own content. The pane is real UIGlassEffect on
// iOS 26 and up. Below that it is an SGLegacyGlassView (an approximation built on private backdrop-layer
// API) when the person's "Legacy Liquid Glass" switch is on and the device has that API, and a plain
// dark chrome blur otherwise.
#import <UIKit/UIKit.h>
#import "SGLegacyGlass.h"
#import "SGGlassTouch.h"
#import "SGGlassThumb.h"

#define SGKeyLegacyGlass @"spotifyglass.redesign.legacyglass"

// Whether panes are SGLegacyGlassViews right now. The one place this is decided: callers ask it instead of
// re-deriving the answer from the switch, @available and SGLegacyGlassAvailable().
BOOL SGUseLegacyGlass(void);

// UIGlassEffect, which is only made by +effectWithStyle:, or a dark chrome blur as the fallback.
UIVisualEffect *SGGlassEffect(void);
// A UIVisualEffectView or an SGLegacyGlassView. Callers set its frame and overrideUserInterfaceStyle and
// pass it to SGShapeGlass, so they need not tell the two apart.
UIView *SGGlassFor(UIView *host, const void *key);
// Several panes on one host, addressed by index; panes past `count` are hidden by SGHideGlassFrom.
UIView *SGGlassAt(UIView *host, NSUInteger index);
void SGHideGlassFrom(UIView *host, NSUInteger count);
// Glass takes its shape from cornerConfiguration on iOS 26, from SGLegacyGlassView's own corner radius
// below that, and from layer.cornerRadius on a plain blur.
void SGShapeGlass(UIView *glass, CGFloat radius, BOOL capsule);

// Dark whatever the system is set to, for a controller the mod presents. A sheet's glass is its presentation's,
// which the controller's own override does not reach. Call it after modalPresentationStyle is set.
void SGPresentDark(UIViewController *controller);

// The areas each look keeps transparent are its own: Native/Appearance/Repaint.h and
// Redesigned/Kit/SGRRepaint.h.
