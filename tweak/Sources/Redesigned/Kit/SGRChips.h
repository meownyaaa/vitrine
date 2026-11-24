// Encore's filter chips (a ChipView over a PillView) on glass, below iOS 26: for the pages whose chips are not the
// library's FilterChipView -- the genres over Liked Songs (Playlist/PlaylistChips.x) and the Podcasts / Music chips
// of Recents (Pages/Recents.x). The chips of the Add to playlist sheet are a different class, Home_PillUIKit's
// PillView, and are dressed by SGRSheetPills.x on its own.
//
// An unselected chip's flat fill (#FFFFFF@0.10) goes and a glass capsule stands behind it, as the library's chips
// have theirs (Library/LibraryHeader.x); a selected chip is glass tinted with the colour it is painted (below). Spotify paints the fill again as a chip is selected or let go, with no layout, so
// SGRRepaint.x keeps the tint off a pill of a chip dressed here and tells the chip.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

// Dresses every chip under `root` and watches each for its own layout, so a row laid out again at new widths (a
// chip picked) sizes the glass again. Cheap to call on every pass.
void SGRGlassChipsIn(UIView *root);

// A selected chip is a solid colour of Spotify's (the library's green). Below iOS 26 it is glass with that colour as
// its tint instead: the colour made translucent over the chip's glass capsule, so the glass shows through it.
// SGRSelectedChipPaint is that colour for a solid `paint` (any other paint comes back as it is), and
// SGRTintSelectedFill puts it on a fill or a pill that Spotify painted solid. For the three kinds of chip (the
// library's, Encore's, the sheet's pills) and SGRRepaint.x, which swaps it in as Spotify paints.
CGColorRef SGRSelectedChipPaint(CGColorRef paint);
void SGRTintSelectedFill(UIView *fill);

// `chip` on glass, for the three kinds of chip: a capsule of its size inside it under `key`, behind its `fill`. A
// `selected` fill keeps its colour as a tint over the glass; any other loses its paint, so the glass is what shows.
void SGRGlassChip(UIView *chip, UIView *fill, BOOL selected, const void *key);

// Whether `view` is the pill of a chip dressed by SGRGlassChipsIn, and the chip's glass is brought in line with a
// paint that has just landed on it. For SGRRepaint.x.
BOOL SGRIsDressedChipPill(UIView *view);
void SGRDressedChipPainted(UIView *chip);

// The chips of a sheet (the Add to playlist sheet's, Home_PillUIKit.PillView), dressed by SGRSheetPills.x. For
// SGRRepaint.x: whether `view` is such a pill, whether a paint is the flat grey of an unselected one, and the pill's
// glass is brought in line with a paint that has just landed on it.
BOOL SGRSheetPillsLive(void);   // a pill has been dressed; false until then, so a hook need not look
BOOL SGRIsSheetPill(UIView *view);
BOOL SGRIsPillGrey(CGColorRef color);
// Whether a pill or a chip is the selected one: Spotify paints it a solid colour of its own, the others a translucent
// white or a dark grey (SGRIsPillGrey).
BOOL SGRPillIsSelected(UIView *pill);
void SGRSheetPillPainted(UIView *pill);
