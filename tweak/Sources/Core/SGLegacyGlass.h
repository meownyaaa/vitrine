// The pre-iOS 26 stand-in for UIGlassEffect: a CABackdropLayer, blurred and saturated, displaced by a
// mesh so its edges refract the way real glass does. Geometry and filter values are ported from
// Telegram-iOS's GlassBackgroundComponent and MeshTransform (GPLv2); no Telegram code is kept verbatim.
//
// CABackdropLayer and CAMutableMeshTransform are private API Apple can remove at any point, so the
// whole thing sits behind SGLegacyGlassAvailable() and the "legacy glass" switch (SGKeyLegacyGlass),
// and every call fails soft to a plain blur. Callers go through SGUseLegacyGlass() (SGGlass.h), which
// combines both.
#import <UIKit/UIKit.h>

// NO on iOS 26+ (UIGlassEffect is used there) and wherever the private classes turn out not to exist.
// Cached after the first call.
BOOL SGLegacyGlassAvailable(void);

// One pane per call site, like UIVisualEffectView. It keeps its own backdrop layer and mesh sized to
// its bounds, so a pane resized by autoresizing or Auto Layout follows with no help from the caller.
@interface SGLegacyGlassView : UIView

// Where a caller puts its own content, like UIVisualEffectView.contentView: the backdrop and the mesh
// live behind it.
@property (nonatomic, strong, readonly) UIView *contentView;

// Corner radius of the glass. Ignored while `capsule` is set, which rounds to half the shorter side.
@property (nonatomic) CGFloat cornerRadius;
@property (nonatomic) BOOL capsule;

// How far the backdrop is blurred, 2 by default: enough to soften an edge, and so little that a small
// control over text shows the text. A big pane (a sheet) sets more, or the page under it takes the eye.
@property (nonatomic) CGFloat blurRadius;

// Whether the pane wears the glass as it first was: YES for a big pane (a shorter side of 100 pt and more: the queue, the
// sheets, the menus, the dialogs), with Telegram's lens, bent hard over a thin band at the edge, and its diagonal glare.
// The measured lens of the small controls spreads over a wide band with a faint rim, which on a sheet read as a blur.
@property (nonatomic, readonly) BOOL classic;

// How much bigger what is behind the glass shows through it, about the middle, 1 by default. The tab bar's held bubble
// sets more, as the system's magnifies the tabs under it.
@property (nonatomic) CGFloat magnification;

// How much of the lens's bend the pane takes, 1 by default; the tab bar's held bubble takes less, its icons smeared at
// the rim under the whole of it.
@property (nonatomic) CGFloat lensScale;

// Clear glass, the system's .clear as a held control's thumb wears it: what is behind keeps its own colours (no
// saturation; the panes' boost turned a switch's green track into a neon blob under its thumb) and is barely blurred
// (adaptive_liquid_glass's clearDark: saturation 0.96, blur sigma 1.23). NO by default.
@property (nonatomic) BOOL clear;

// The backdrop at the screen's scale rather than at 1x, so what shows through is as sharp as the screen (the tab bar's
// held bubble, whose magnified icons came out pixelated). NO by default: it costs nine times the pixels on a 3x screen.
@property (nonatomic) BOOL sharp;

// No light along the rim: for a pane whose owner draws its own (a held switch's lens, lit on two arcs only). NO by default.
@property (nonatomic) BOOL rimless;

@end

// The light the system's glass draws along its rim: a thin white line whose brightness follows which way the rim faces,
// brightest towards the top left, faint across from it (as adaptive_liquid_glass measured it). Kept as one sublayer of
// `host`, made on the first call and set to `bounds` and `radius` on every one; a pane draws its own (SGLegacyGlassView)
// and a film over a pane calls this too, as it covers the pane's. Does nothing on iOS 26 and later, where the system's
// glass has its own.
void SGLegacyGlassSpecular(CALayer *host, CGRect bounds, CGFloat radius);
// The classic pane's rim (SGLegacyGlassView.classic), the same way: its diagonal glare, in place of the other.
void SGLegacyGlassClassicSpecular(CALayer *host, CGRect bounds, CGFloat radius);
