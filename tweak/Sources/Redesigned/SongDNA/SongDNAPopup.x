// SongDNA redesign: the contributor's pop-up on glass. Tapping a contributor on the map opens a card over it
// (SongDNA_MapKit.DNAPopupView): a #1F1F1F rounded card, r=16, holding the contributor's name with a chevron at its
// trailing edge, a two-line story, and the "View 81 songs together" button (an Encore Secondary,
// id=dna-blend-button-cta).
//
// The card's grey goes and a glass pane of the sheets' body (SGRThickenSheetGlass, as the redesign's dialogs have)
// stands behind its content; the chevron gets a glass circle of its own behind it, and the button is made a glass
// capsule. Nothing of Spotify's is replaced, so the name still opens the contributor and the button still plays the
// blend.
//
// The card is laid out and painted after it is attached, so the pass runs from its layout and again a moment later.
// The little arrow (SongDNA_MapKit.ArrowView) that points from the card at the contributor is left as Spotify draws it.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static const CGFloat kPopupRadius = 16, kChevronSide = 28;

static char kPaneKey, kChevronKey, kButtonKey;

// The card's own paint: its one subview that is the opaque grey, as wide as the card. Once dressed its grey is
// clear, so it is then the subview that holds our pane. Looking for the grey alone found no card from the second
// pass on, and the first one runs before the heading and the button are laid out (the chevron 0pt wide), so the
// chevron and the button never got their glass.
static UIView *cardOf(UIView *popup) {
    for (UIView *sub in popup.subviews) {
        if (objc_getAssociatedObject(sub, &kPaneKey) || SGRIsSheetSurface(sub.layer.backgroundColor)) return sub;
    }
    return nil;
}

static void dressPopup(UIView *popup) {
    if (popup.bounds.size.width < 1 || popup.bounds.size.height < 1) return;
    UIView *card = cardOf(popup);
    if (!card) return;
    SGRGlassPaneIn(card, &kPaneKey, kPopupRadius);
    card.backgroundColor = UIColor.clearColor;

    SGForEachView(popup, ^(UIView *view) {
        NSString *name = NSStringFromClass(view.class);
        if ([name hasSuffix:@"ChevronView"] && view.bounds.size.width > 1) {
            SGRGlassInside(view, &kChevronKey, kChevronSide);
        } else if ([view.accessibilityIdentifier isEqualToString:@"dna-blend-button-cta"]) {
            view.layer.borderWidth = 0;
            SGRGlassFlatBox(view, &kButtonKey, NO);
        }
    });
}

%group SGRSongDNAPopup
%hook SGRDNAPopupView
- (void)layoutSubviews {
    %orig;
    dressPopup((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    UIView *popup = (UIView *)self;
    if (!popup.window) return;
    SGRRepeatViewPass(popup, @[@0.0, @0.1, @0.3, @0.7], ^(UIView *v) { dressPopup(v); });
}
%end
%end

%ctor {
    // Below iOS 26 only: on iOS 26 the page keeps the look it has on main.
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class popup = SGRSwiftClass(@"SongDNA_MapKit", @"DNAPopupView");
    if (!popup) {
        SGLog(@"class SongDNA_MapKit.DNAPopupView not found, the contributor pop-up keeps Spotify's grey");
        return;
    }
    %init(SGRSongDNAPopup, SGRDNAPopupView = popup);
}
