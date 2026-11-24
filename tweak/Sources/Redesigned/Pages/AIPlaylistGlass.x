// Redesign: the header of the AI playlist's chat on glass.
//
//   AI playlist   AIPlaylist_PlaylistCreationPageImpl.PlaylistCreationView: the header row's
//                 "Abort Playlist Creation" cross, and the "Close Chat" cross that takes its place once the chat has
//                 started, become glass circles, as the cross of Create cover art is (CoverArt/CoverArt.x).
//                 "Cancel" (shown in the cross's place while the playlist is being made) is a glass capsule and the
//                 row's "More Options" ⋯ at the other corner a glass circle. The ⋯ is
//                 32 x 32 at (346, 12) in the row, 2pt higher than the cross's centre, and is moved down by that much. It is
//                 dimmed to 0.4 until the chat has started, and glass drawn under a button's fading alpha is drawn wrongly
//                 (Kit/SGRGlass.h, SGRShowGlass), so its glass is shown only while the button is not dimmed.
//                 The chat below the header (message, cards, field, the black behind them) is AIPlaylistChat.x, the popup
//                 the ⋯ opens AIPlaylistMore.x.
//
//   Onboarding    the first screen, "Your playlist playground awaits": a plain container the size of
//                 the screen that is the page's sibling, over it, holds the story and its own cross, "Components.UI.OnboardingView.CloseButton",
//                 a Tertiary button 48 x 48 at the corner. It is not inside the page, so the page's passes never met it and it
//                 showed as Spotify's bare cross, 4pt left of and 6pt above the header row's (that button is 48 x 52 at (4, 4) in its row).
//                 It gets the same glass circle, and is moved by that much so the cross does not jump when the chat begins.
//
// Both are Encore Tertiary buttons of the same frame, one shown at a time by Spotify, so each carries its own glass and
// the hidden one's goes with it. The button keeps its action and its accessibility: the glass is its own subview
// (Kit/SGRGlass.h). Nothing between the button and the page clips: the glass is 44pt inside a 48 x 52pt button, and
// the grown glass of a press (SGGlassInteractive) would be cut off at the button's edge if the button did, so the
// button and the plain views above it, up to the page, are let go of their clip.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static char kCrossGlassKey, kCancelGlassKey;

static NSString *const kOnboardingCross = @"Components.UI.OnboardingView.CloseButton";
static NSString *const kCancelButton = @"Components.UI.PlaylistCreationHeaderRow.CancelButton";
static NSString *const kMoreButton = @"Components.UI.PlaylistCreationHeaderRow.MoreOptionsButton";

// Where the header row's cross is from the onboarding's: its button sits at (4, 4) in the row, this one at the row's own corner, and
// 52pt high against 48 puts the centre of its glyph 2pt lower still.
static const CGFloat kOnboardingShiftX = 4, kOnboardingShiftY = 6;
// The ⋯'s button is centred at y = 28 in the row, the cross's glass at 30.
static const CGFloat kMoreShiftY = 2;
// Cancel's button is 72 x 52 (a 40pt label with 16pt on each side); its capsule is as wide and as high as the cross's circle.
static const CGFloat kCancelGlassHeight = 44;

static BOOL isCross(NSString *identifier) {
    return [identifier isEqualToString:@"Components.UI.PlaylistCreationHeaderRow.DismissButton"]
        || [identifier isEqualToString:@"Components.UI.PlaylistCreationHeaderRow.CloseChatButton"];
}

// The views from the button up to the page that are Spotify's plain containers: a scroll view's clip is its own to keep.
static void unclipPath(UIView *button, UIView *page) {
    for (UIView *view = button; view && view != page; view = view.superview) {
        if (view != button && ![view isMemberOfClass:UIView.class]) continue;
        if (view.clipsToBounds) view.clipsToBounds = NO;
    }
}

static void shiftButton(UIView *button, CGFloat x, CGFloat y) {
    CGAffineTransform shift = CGAffineTransformMakeTranslation(x, y);
    if (!CGAffineTransformEqualToTransform(button.transform, shift)) button.transform = shift;
}

// A button of the header dressed from its own passes, not only from the page's: the page is not laid out again while the first
// screen stands over it (the view that holds the header row's buttons, with no glass in them), and a button laid out at no size on the
// page's first pass is met again only by its own.
static void dressCrossButton(UIView *button) {
    NSString *identifier = button.accessibilityIdentifier;
    if (!identifier.length) return;
    BOOL onboarding = [identifier isEqualToString:kOnboardingCross];
    BOOL cancel = [identifier isEqualToString:kCancelButton];
    BOOL more = [identifier isEqualToString:kMoreButton];
    if (!onboarding && !cancel && !more && !isCross(identifier)) return;
    if (!button.window || button.bounds.size.width < 1 || button.bounds.size.height < 1) return;
    UIView *glass = cancel
        ? SGRGlassCapsuleInside(button, &kCancelGlassKey, CGSizeMake(button.bounds.size.width, kCancelGlassHeight), NO)
        : SGRGlassInside(button, &kCrossGlassKey, SGRGlassCircleSize);
    if (button.clipsToBounds) button.clipsToBounds = NO;
    if (more) {
        if (glass) SGRShowGlass(glass, button.alpha >= 0.99);
        shiftButton(button, 0, kMoreShiftY);
    } else if (onboarding) {
        shiftButton(button, kOnboardingShiftX, kOnboardingShiftY);
    }
}

static void dressCross(UIView *page) {
    if (!page.window) return;
    SGForEachView(page, ^(UIView *view) {
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        if (!isCross(identifier) && ![identifier isEqualToString:kCancelButton] && ![identifier isEqualToString:kMoreButton]) return;
        if (view.bounds.size.width < 1 || view.bounds.size.height < 1) return;
        dressCrossButton(view);
        unclipPath(view, page);
    });
    // The chat under the header: its message, cards, field and the black behind them (AIPlaylistChat.x).
    SGRAIPlaylistDressChat(page);
}

%group SGRAIPlaylistButtons
%hook SGRTertiaryButton
- (void)layoutSubviews {
    %orig;
    dressCrossButton((UIView *)self);
}

- (void)didMoveToWindow {
    %orig;
    dressCrossButton((UIView *)self);
}

// The ⋯ is dimmed and lit again by its alpha alone, which lays nothing out.
- (void)setAlpha:(CGFloat)alpha {
    %orig;
    UIView *button = (UIView *)self;
    if ([button.accessibilityIdentifier isEqualToString:kMoreButton]) dressCrossButton(button);
}
%end
%end

%ctor {
    if (!SGRedesignedUI()) return;
    if (!SGBelowiOS26()) return;
    Class page = SGRSwiftClass(@"AIPlaylist_PlaylistCreationPageImpl", @"PlaylistCreationView");
    if (page) {
        SGRPassView(page, ^(UIView *v) { dressCross(v); });
    } else {
        SGLog(@"class AIPlaylist_PlaylistCreationPageImpl.PlaylistCreationView not found, the AI playlist's cross keeps Spotify's button");
    }
    // Encore's Tertiary button, by the name the trees print: the three crosses, Cancel and the ⋯ are, the first screen's cross outside the page's view.
    Class tertiary = NSClassFromString(@"_TtCCE16Encore_ButtonKitO16EncoreFoundation6Encore6Button8Tertiary");
    if (tertiary) {
        %init(SGRAIPlaylistButtons, SGRTertiaryButton = tertiary);
    } else {
        SGLog(@"class Encore Button Tertiary not found, the AI playlist's first screen keeps Spotify's cross");
    }
}
