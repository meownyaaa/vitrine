// Glass for the redesign's control layer, and only for it: never behind rows, cards or text. Built on
// Core/SGGlass.m (the effect made through +effectWithStyle:). Under Reduce Transparency a shape is a
// solid SGRSolidGlassFill, on any OS; before iOS 26 without it, a dark thin material blur. Nothing
// touches a glass class on an OS without them. A shape is dark whatever the system appearance: glass
// takes the one it inherits, which outside the navigation stacks Spotify makes dark (the player) is the
// system's, light on a phone in light mode.
//
// Ownership: a shape belongs to the control it is made in (associated with it under the caller's key).
// Threading: main thread only.
#import <UIKit/UIKit.h>

// A glass circle inside someone else's round control, `side` across, behind everything the control
// draws (first in its subviews, re-asserted on every call, since glass takes what is above it in the
// tree into its backdrop however the depths are set) and kept at its middle by the autoresizing mask.
// Being the control's own
// subview it goes wherever the control goes: a frame worked out from outside goes stale when Spotify
// lays a row out after the unit that holds it (the player's header circles sat 24pt off until a tap
// laid the unit out again, trees/continuous/1.txt 2026-09-17). Takes no touches; made once per control
// under `key`, and made again when Reduce Transparency changes the kind of shape.
UIView *SGRGlassInside(UIView *control, const void *key, CGFloat side);

// The same, in a capsule `size` across rather than a circle: for the one control of an action row that
// leads (the playlist header's Play). `prominent` lays a white film inside the shape, so that control
// reads a step brighter than the circles beside it without leaving the same material.
UIView *SGRGlassCapsuleInside(UIView *control, const void *key, CGSize size, BOOL prominent);
// Controls side by side on one glass capsule, as iOS 26 groups a bar's buttons, instead of a circle each: the capsule is
// `height` tall, runs from the first control's leading edge to the last one's trailing edge with `pad` beyond each, and
// sits in `host` (their common superview) behind all of them, under `key`. Controls with no size are left out; with
// none it is hidden. Safe to call on every pass; nil on iOS 26.
UIView *SGRGlassGroupPill(UIView *host, NSArray<UIView *> *controls, const void *key, CGFloat height, CGFloat pad);

// The views from `view` up stop clipping, through the first one `isLast` answers YES for (to the window when it never
// does): a capsule wider than its control, or the legacy glass's press, which grows past it, would be cut off.
void SGRUnclipUpTo(UIView *view, BOOL (^isLast)(UIView *ancestor));

// The glass capsule a name sits on at the top of a page (a bar's title, a header's name), level with the glass circles
// beside it: SGRGlassCircleSize tall, SGRTitlePadding of glass each side of `content` (the name's width,
// SGRTitleWidth), never narrower than it is tall and at most `room` wide. It goes inside `holder` under `key`
// (SGRGlassCapsuleInside); with `isLast` the views from `holder` up stop clipping as SGRUnclipUpTo has it, for a holder
// as small as its name. Returns the capsule, nil for no content.
UIView *SGRGlassTitleCapsule(UIView *holder, const void *key, CGFloat content, CGFloat room, BOOL (^isLast)(UIView *ancestor));
// The width `label`'s text takes on one line, rounded up.
CGFloat SGRTitleWidth(UILabel *label);

// Shows or hides a shape of the Kit's by its effect, never by an alpha on it or on a view above it
// (Redesigned/Player/PlayerMotion.x): UIKit draws the material wrongly or not at all under a fading alpha.
// The solid shape Reduce Transparency puts in its place has no effect and fades by its own alpha. Animates
// in the caller's animation.
void SGRShowGlass(UIView *shape, BOOL shown);
// Glass behind a flat box Spotify draws as a grey rounded rect (a search field, a sort button): the box is
// cleared and made a capsule, and a glass capsule goes inside it. `prominent` lays in the white film SGRGlassCapsuleInside
// gives a prominent shape, for a box that floats over a page it scrolls above (a search field over the list under it),
// where plain glass over black or over text reads as no plate at all. Safe to call on every pass.
UIView *SGRGlassFlatBox(UIView *box, const void *key, BOOL prominent);

// An Encore button of Spotify's on a glass capsule (SGRGlassFlatBox under `key`, no film): its own fill goes, the button's and
// that of the plain view of its size inside it, and with `accent` the accent is laid over the glass under the label,
// for a button Spotify draws with a black one. Returns the glass. Below iOS 26.
UIView *SGRGlassEncoreButton(UIView *button, const void *key, BOOL accent);

// A floating card of Spotify's (a toast, a tooltip) on glass: its paint off, its corners half its height up to
// `maxRadius`, and a pane (under `glassKey`) and a film (under `filmKey`) of its size. Not clipped with the legacy
// glass, whose pane has the corners and whose press grows past it. Returns the pane.
UIView *SGRGlassFloatingCard(UIView *card, const void *glassKey, const void *filmKey, CGFloat maxRadius);

// A glass capsule that is the whole of `box` and follows it: the box is cleared and made a capsule, and the glass is its first subview with
// the box's size kept by autoresizing, so a box that is resized (the AI playlist's Refine field, which Create narrows) takes its glass along
// frame by frame. It answers no press: for a field that is typed into, the grown, stretched glass of a press lags behind the finger and
// reads as a fault. `prominent` lays the white film in as SGRGlassFlatBox does. Safe to call on every pass; nil on iOS 26.
UIView *SGRGlassFillBox(UIView *box, const void *key, BOOL prominent);

// Lays the white film SGRGlassCapsuleInside gives a prominent shape inside any shape of the Kit's (a pane made by SGGlassFor), or takes it
// away, so a card or bubble on glass over black reads as a plate instead of a hole. The film carries the corners `radius`.
void SGRGlassSetFilm(UIView *shape, BOOL on, CGFloat radius);

// The faint white film over a floating bar's glass (the tab bar's platter, the now playing card), without
// which the bar disappears into Spotify's near-black chrome. Made once under `key`, kept just above `glass`
// and on its frame, with corners of `radius`. Nil on iOS 26, where the system glass needs none.
UIView *SGRGlassFilm(UIView *host, const void *key, UIView *glass, CGFloat radius);

// How much floating glass is dimmed (SGRDarkenGlass): what Create's menu dims the page behind the tab bar by, under
// which the bar read best.
extern const CGFloat SGRBarDim;
// A black layer of `alpha` inside `pane` (a legacy glass pane or a blur), made once under `key`: over what the glass
// shows of the page, under its rim, its film and what stands on it, so the controls on floating glass (the tab bar,
// the now playing card, the top buttons, the toast) stand out over a bright page. Corners of `radius`. Nil on iOS 26.
UIView *SGRDarkenGlass(UIView *pane, const void *key, CGFloat radius, CGFloat alpha);

// The chrome of a bottom sheet Spotify draws around an opaque "sheet-view" pane: the ⋯ context menu, the
// queue, and the pop-art track info under the now playing bar. A glass pane goes behind the pane's own
// paint and the plain wrapper views between it and the sheet's first scrolling list lose their fill. Stops
// at that list and leaves its rows alone. Also records the sheet in sgr_sheetChromeRoot (SGRRepaint.h), whose
// hook keeps the fill clear when Spotify paints it back.
UIView *SGRGlassSheetChrome(UIView *content);
// The pane of the sheet `navigation` is presented in (its view's superview): a card at least 300pt wide with a gap
// above it, never as tall as the screen. Nil for a navigation controller that is not in such a sheet.
UIView *SGRSheetPaneOfNavigation(UINavigationController *navigation);
// The pane of Navigation's sheet `view` stands in (id=sheet-view), `view` itself included; nil outside one.
UIView *SGRSheetPaneOf(UIView *view);
// The same for a sheet that carries no "sheet-view" identifier, handed over as the view that is the pane itself
// (the share menu's ShareMenuSheetView, which UIKit presents over the screen on its own, not in Navigation's
// sheet): the pane, the screen's top corners and the cleared grey, as above.
UIView *SGRGlassSheetView(UIView *sheet);
// Takes SGRGlassSheetView's pane off a sheet and gives the pane back its corners and paint (black when it had none). For a sheet
// that was glassed before it was known to be one that stays Spotify's, as Edit profile (Profile/ProfileEdit.x). Safe to call on
// every pass; does nothing on a sheet that was never glassed.
void SGRRemoveSheetGlass(UIView *sheet);
// Whether `layer` is the shadow of a sheet SGRGlassSheetChrome glassed, which UIKit gives its shadow back on every move
// between detents: Kit/SGRSheetPopups.x keeps it at 0 as it is written.
BOOL SGRSheetShadowHeld(CALayer *layer);
// The top corner radius of every sheet the mod glasses: the screen's, as the Genius meanings sheet has it.
CGFloat SGRSheetCornerRadius(void);
// The body SGRGlassSheetChrome puts on a sheet's pane (heavier blur, dark tint, hairline rim), for a sheet
// the mod presents itself and that has no "sheet-view" to find (the Genius meanings sheet).
void SGRThickenSheetGlass(UIView *glass, CGFloat cornerRadius);
// A black layer over the body SGRThickenSheetGlass gives a pane, for menus whose white text the light body
// leaves too little contrast to read. Call it after SGRThickenSheetGlass.
void SGRDimSheetGlass(UIView *glass, CGFloat alpha);
// A pane over the whole of `host` with that body (SGRThickenSheetGlass), dark, its corners `radius`, made once under
// `key` and kept to the host's size: a card of Spotify's on glass (a dialog, a popup, a menu). The caller dims it.
UIView *SGRGlassPaneIn(UIView *host, const void *key, CGFloat radius);

// Whether `view` is chrome of the sheet rooted at `root` (sgr_sheetChromeRoot) rather than a row or card
// inside the sheet's own list.
BOOL SGRIsSheetChromeArea(UIView *view, UIView *root);

// How much of a sheet's width a view must span to count as a band of its list rather than a card or an avatar.
static const CGFloat SGRSheetBandShare = 0.75;

// The opaque dark grey (up to 0.20 bright, grey, alpha >= 0.95) Spotify paints a sheet's rows and wrappers
// with: #1F1F1F, which SGIsBaseSurface (the page black, up to 0.10) does not take for paint.
BOOL SGRIsSheetSurface(CGColorRef color);

// Clears the bands a row of the sheet's list paints (the cell, the stacks in it nearly as wide as the sheet
// `root`). For a cell that comes into the sheet after the chrome was stripped: scrolled in, reused, or
// dragged. Safe to call on every layout pass.
void SGRClearSheetCellPaint(UIView *cell, UIView *root);

// Whether `view` is a card the sheet draws on purpose (a SwiftUI shape, or a narrower rounded fill) rather than
// the grey of a wrapper: SGRGlassSheetChrome and the repaint hook leave these alone.
BOOL SGRIsSheetCard(UIView *view);

// The translucent white a SwiftUI card of a sheet (the device picker's, #292929 opaque) is painted instead,
// and whether `view` is such a card.
CGColorRef SGRSheetCardFill(void);
BOOL SGRIsSwiftUICard(UIView *view);
