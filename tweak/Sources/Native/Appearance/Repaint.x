// Keeps the areas the native look's tweaks stripped transparent when Spotify repaints them.
#import "Core/SGCore.h"
#import "Repaint.h"

__weak UIView *sg_lyricsCardRoot = nil;
__weak UIView *sg_lyricsPageRoot = nil;
__weak UIView *sg_homeRoot = nil;
__weak UIView *sg_npvBackdropRoot = nil;

%hook CALayer
- (void)setBackgroundColor:(CGColorRef)color {
    if (!color) {
        %orig;
        return;
    }
    UIView *cardRoot = sg_lyricsCardRoot, *pageRoot = sg_lyricsPageRoot, *homeRoot = sg_homeRoot, *npvRoot = sg_npvBackdropRoot;
    if (cardRoot || pageRoot || homeRoot || npvRoot) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !SGKeepsColor(view)) {
            // One walk answers SGIsInside for all four roots: each stops at the same first effect view.
            BOOL lyrics = NO, home = NO;
            for (UIView *v = view; v && !lyrics; v = v.superview) {
                if ([v isKindOfClass:UIVisualEffectView.class]) break;
                // The album color arrives on the backdrop plane per track, outside any layout pass.
                lyrics = v == cardRoot || v == pageRoot || v == npvRoot;
                home = home || v == homeRoot;
            }
            if (lyrics) {
                color = NULL;
            } else if (home && SGIsBaseSurface(color)) {
                // Home keeps its cards and its placeholders; only the base surface the gradient
                // of Native/Home/HomeGradient.x sits behind goes.
                color = NULL;
            }
        }
    }
    %orig(color);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
}
