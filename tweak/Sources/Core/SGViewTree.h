// Walking and reading Spotify's view trees.
#import <UIKit/UIKit.h>

void SGForEachView(UIView *view, void (^fn)(UIView *));
CGRect SGFrameIn(UIView *view, UIView *target);
// Whether `view` sits under `root`, stopping at a visual effect view on the way up.
BOOL SGIsInside(UIView *view, UIView *root);
// Whether no view from `view` up to (not including) `root` is hidden.
BOOL SGShownUnder(UIView *view, UIView *root);
// A wide stack view with at least two arranged children: a player row, or the row of items in the tab bar.
BOOL SGIsRow(UIView *view);
// The first row (SGIsRow) under `host`.
UIStackView *SGRowIn(UIView *host);
// Whether `cls`'s name contains `marker`, worked out once per class and marker. Main thread only. `marker`
// must be a string literal: answers are kept by its address.
BOOL SGClassNamed(Class cls, NSString *marker);
// Whether any view under `root` has `marker` in its class name.
BOOL SGHasClass(UIView *root, NSString *marker);
// The first view under `root` (itself included) that `match` accepts, remembered weakly on `root` under
// `key` and looked for again once it no longer matches or has left `root`. Nothing found is not remembered.
UIView *SGFindRemembered(UIView *root, const void *key, BOOL (^match)(UIView *view));
// `count` SGFindRemembered lookups on `root` in one walk, for a caller that asks for several views back to back
// with nothing between the lookups that could change the tree. Each key's remembered view is kept by the same
// rule, the keys left are looked for together, each taking the first view `match` accepts for it, and only hits
// are remembered. `out[i]` is key i's view or nil: the same answers the lookups give one after another.
void SGFindRememberedAll(UIView *root, NSUInteger count, const void *const keys[], BOOL (^match)(NSUInteger i, UIView *view), UIView *__strong out[]);
// SGFindRemembered for the first view whose accessibility identifier starts with `prefix`.
UIView *SGFindIdentifier(UIView *root, NSString *prefix, const void *key);
// SGFindRememberedAll for `count` identifier prefixes.
void SGFindIdentifiers(UIView *root, NSUInteger count, NSString *const prefixes[], const void *const keys[], UIView *__strong out[]);

// Artwork, glyphs, text and thin lines (progress bar) keep their color, everything else goes clear.
BOOL SGKeepsColor(UIView *view);
void SGStripBackgrounds(UIView *view);
BOOL SGIsVisibleColor(CGColorRef color);
BOOL SGIsLightColor(CGColorRef color);
// Spotify's base surface: the neutral #121212 it paints its pages with, or the black AMOLED turns
// that into.
BOOL SGIsBaseSurface(CGColorRef color);
// A painted, card-sized view: the now playing bar's card, for one.
BOOL SGLooksLikeCard(UIView *view, CGColorRef color);
