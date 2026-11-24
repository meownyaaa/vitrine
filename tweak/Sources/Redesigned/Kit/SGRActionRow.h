// The controls a redesigned page puts in the row under its hero, where the Music app has them: the Play
// capsule it draws instead of a disc, and a round button standing in for one of Spotify's own where that
// one cannot be brought into the row.
//
// Neither is a control of its own making. Each takes what it shows from a button of Spotify's -- the glyph
// it draws, the word beside it in the app's own language, whether it reads play or pause -- and a tap on it
// fires that button, so the action, the state and the accessibility stay Spotify's and only the drawing is
// the redesign's. A page that can move Spotify's button into its row moves it and needs neither.
//
// Ownership: whoever adds them; each keeps a weak reference to Spotify's control.
// Threading: main thread only.
#import <UIKit/UIKit.h>

// A capsule the height of SGRActionHeight with a glyph and a word in it, on prominent glass: the one
// control of an action row that leads. `sgr_width` is the width the word it is showing asks for.
@interface SGRPlayCapsule : UIControl
// Spotify's play button, the one the capsule reads and fires. Set by -feedFrom:.
@property (nonatomic, weak, readonly) UIView *source;
// A solid capsule of this color instead of the prominent glass, the Music app's white Play (the playlist).
// nil, the default, is the glass. Set before the capsule is first laid out.
@property (nonatomic, copy) UIColor *fillColor;
// The glyph's and the word's color; nil is the accent.
@property (nonatomic, copy) UIColor *contentColor;
// Takes the glyph, the word and the language from `source`, and follows the glyph as Spotify swaps it
// (play becoming pause) without the header laying out again. Cheap to call again on every pass.
- (void)feedFrom:(UIView *)source;
- (CGFloat)sgr_width;
@end

// A round glass button SGRActionHeight across showing the glyph of one of Spotify's round buttons and
// firing it, for a control the row cannot reach: the album page's shuffle floats over the page rather
// than scrolling with its header, so it is left where it is, concealed, and this stands in for it.
@interface SGRMirrorButton : UIControl
@property (nonatomic, weak, readonly) UIView *source;
// Drawn, in white, when Spotify's button has no image view to copy (a glyph it draws itself).
@property (nonatomic, strong) UIImage *fallbackGlyph;
// YES draws fallbackGlyph centred at its own size and never Spotify's image: for a control whose own image has
// uneven padding in its canvas (the Eat this playlist cross sat off the middle of its circle), where copying it
// copies the offset. The label and the action are still Spotify's. NO, the default, copies Spotify's glyph.
@property (nonatomic, assign) BOOL ownGlyph;
// The color to draw the mirrored glyph in, whatever color Spotify drew it. nil, the default, keeps
// Spotify's -- which is what a glyph that says something by its color needs (shuffle turns the accent
// color while it is on). Set it for a glyph whose color is only the weight Spotify gave the control it
// sat in: Encore bakes the color into the image it draws, so this re-renders the copy as a template.
@property (nonatomic, copy) UIColor *glyphColor;
// The color the glyph takes while Spotify's button is on, and glyphColor while it is off, for a button that
// says it is on with the small dot Encore puts under its glyph (shuffle: trees/continuous/1.txt, a 4pt round
// view, hidden while off). Spotify's own off gray read as a disabled button beside the white download
// (issue #65). A button with no such dot keeps Spotify's colors. nil, the default, reads no dot.
@property (nonatomic, copy) UIColor *onGlyphColor;
// For a button that shows its state only as a word in the app's language (the artist's Follow): YES with
// whether it is on once the state is known, from wherever the page reads it. The button then draws
// stateOffSymbol, or stateOnSymbol in the accent color, and nothing while it answers NO. Set before the
// first -feedFrom:; call -feedFrom: again when the state changes.
@property (nonatomic, copy) BOOL (^readState)(BOOL *on);
@property (nonatomic, copy) NSString *stateOffSymbol;
@property (nonatomic, copy) NSString *stateOnSymbol;
// Takes the glyph, its color and the label from `source`, and follows the glyph as Spotify swaps it
// (shuffle turning on). Cheap to call again on every pass.
//
// Spotify's download button (SGRDownload.h) is drawn by Lottie, with nothing to copy: for it the button
// draws the state Spotify reports instead -- the arrow, a ring filling up, the downloaded glyph -- and reads
// it again while it is on screen, twice a second while a download runs, since nothing Spotify does then
// lays out anything the page hears. So is the add-to button, drawn as a plus or, saved, a checkmark.
- (void)feedFrom:(UIView *)source;
@end

// The ⋯ every redesigned entity page pins to its top trailing corner, level with the back button: one
// button, one size, one place on the playlist, the album and the artist. It is added to `page` -- the
// page's own root view, outside anything that scrolls -- so it stays where it is however far the page is
// scrolled, which is what Spotify's own does not (the navigation bar's slot is emptied on the way down,
// trees/continuous/1.txt 2026-09-20, issue #57) and what a button in a scrolling header cannot.
//
// `source` is Spotify's own ⋯, wherever the page keeps it; nil hides the button until one is found. Kept
// on `page` under `key` and cheap to call again on every pass.
SGRMirrorButton *SGRPinnedMore(UIView *page, const void *key, UIView *source);
// Called with the pinned ⋯ on every pass of SGRPinnedMore, once it is placed and fed: the system menu
// (Redesigned/ContextMenu) sets it to open its menu from the button itself, as it does the player's ⋯.
extern void (*SGRPinnedMoreHook)(SGRMirrorButton *button);

// A sheet opening within this long of a tap on a pinned ⋯ is that page's context menu.
static const NSTimeInterval SGRPinnedMoreWindow = 3;
// The page whose pinned ⋯ was tapped within that window, or nil: for a screen that puts rows of its own on
// Spotify's context menu sheet and has to know which page the sheet belongs to.
UIView *SGRPinnedMoreRecentPage(void);
// The pinned ⋯ itself, tapped within that window, or nil: what the redesign's system menu opens from
// (Redesigned/ContextMenu).
SGRMirrorButton *SGRPinnedMoreRecentButton(void);

// The mirror of SGRPinnedMore at the leading edge: one glass circle, the same size and inset, in place of
// Spotify's own back button, which is hidden. Resizing and glassing Spotify's box in place fought the
// header's collapse animation on every scroll (it lagged, clipped and sat off-centre from the ⋯ opposite),
// so every header pins this independent button instead.
//
// `searchRoot` is where Spotify's back button (Components.Header.UI.BackButton) is looked for; until it is
// found the pinned button stays hidden. Kept on `page`, and cheap to call on every pass.
SGRMirrorButton *SGRPinnedBack(UIView *page, UIView *searchRoot);

// The same for a page whose back button is not Spotify's own Components.Header.UI.BackButton but a control of a
// UINavigationBar (Recents, Your Updates): `source` is what the button reads its glyph from and fires, concealed
// here like the one above. Kept on `page` and cheap to call on every pass. Nil on iOS 26.
SGRMirrorButton *SGRPinnedBackOf(UIView *page, UIView *source);
// The Back pinned to `page` (SGRPinnedBack, SGRPinnedBackOf), or nil: nothing is made.
SGRMirrorButton *SGRPinnedBackIn(UIView *page);
// The Back pinned to `page` put back in its corner and on top, nothing else: for a page that scrolls under it (a table).
void SGRPlacePinnedBack(UIView *page);

// A glass circle of the same size and inset as SGRPinnedMore's, `slot` places further in from the trailing edge
// (0 is the corner itself, 1 the one left of it): for a page whose bar has more than one control there, SongDNA's
// Share and Close. `glyph` is drawn in white when Spotify's control has no image view to copy. Kept on `page` under
// `key`; cheap to call on every pass.
SGRMirrorButton *SGRPinnedTrailing(UIView *page, const void *key, UIView *source, NSUInteger slot, UIImage *glyph);
// Notes `button` as tapped when it is a pinned ⋯, as its touch down does: for a tap run from code, which sends the
// button no touch down so that its other touch down targets (the press highlight) stay still.
void SGRPinnedMoreNoteTap(UIView *button);
