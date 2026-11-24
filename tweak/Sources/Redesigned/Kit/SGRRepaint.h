// The areas the redesign stripped and SGRRepaint.x keeps transparent when Spotify repaints them, each
// set by the part of the redesign that owns it.
#import <UIKit/UIKit.h>

extern __weak UIView *sgr_nowPlayingRoot;   // Redesigned/NowPlayingBar/NowPlayingBar.x, the bar
// Every view in the bar Spotify painted as a card, learned from the album-color paint, which goes clear. The bar
// makes the set and picks its card from it: in a Jam Spotify also paints the Jam strip, or a view around the
// strip and the track.
extern NSHashTable<UIView *> *sgr_nowPlayingPainted;
// Defined in Redesigned/NowPlayingBar/NowPlayingBar.x: the listener's round avatar on the Jam strip. Its fill
// is kept when the bar's paint goes clear, or only the initial is left.
BOOL SGRIsStripAvatar(UIView *view);
extern __weak UIView *sgr_lyricsPageRoot;   // Redesigned/Lyrics/LyricsPage.x
// Redesigned/Playlist/PlaylistField.x, the playlist page. Only the base surface Spotify paints the page,
// its list and its rows with goes clear here: the artwork field is underneath, and the grays of a
// placeholder or a badge are what still has to read against it.
extern __weak UIView *sgr_playlistRoot;
// Redesigned/Album/AlbumField.x, the album page, kept clear the same way and for the same reason.
extern __weak UIView *sgr_albumRoot;
// Redesigned/Artist/ArtistField.x, the artist page, kept clear the same way and for the same reason.
extern __weak UIView *sgr_artistRoot;
// Kit/SGRGlass.h's SGRGlassSheetChrome: the "sheet-view" pane it glassed (the ⋯ context menu, the queue,
// and the now-playing bar's pop-art track info, one component under all three). Any opaque fill its chrome
// repaints outside the sheet's own list (SGRIsSheetChromeArea) is cleared here on every repaint: Spotify
// draws it back on its own later, and a view built after the first pass is never stripped otherwise.
extern __weak UIView *sgr_sheetChromeRoot;
// That sheet watched from now on: its own layouts and those of the lists in it clear the grey Spotify paints on views
// it puts in later, before their first frame. Called by SGRGlassSheetChrome as it glasses the sheet.
void SGRWatchSheetPaint(UIView *root);

// Search/SearchHeader.x, iOS < 26: the view of the search results header (Spotify's #1F1F1F backing, which the page
// puts back on its own passes) and the grey capsule inside its field. Both are kept clear while they are set.
extern __weak UIView *sgr_searchHeaderRoot;
extern __weak UIView *sgr_searchFieldFill;
// Pages/ShowSearch.x, iOS < 26: the "Find in this show" field of a podcast's search page, whose grey Spotify paints again as it is focused.
extern __weak UIView *sgr_showSearchField;
// The same page's header, the SearchHeader view around the field and Cancel that Spotify paints #000000: kept clear while it is set.
extern __weak UIView *sgr_showSearchHeader;

// Playlist/PlaylistAddSearch.x, iOS < 26: the grey search bar at the bottom of the Add songs sheet's pages, kept clear
// while it is set (Spotify paints it again when the field is focused).
extern __weak UIView *sgr_addSongsSearchBar;

// Keeps `view`'s own fill clear from now on, below iOS 26 (weakly held, so a view that goes needs no undoing). For a control
// dressed with glass whose Spotify paint comes back as it is pressed, let go or reused: the plus of the account lists
// (Pages/AccountPlus.x). Clear it once as well: this keeps it clear, it does not clear it.
void SGRHoldClear(UIView *view);
// The same for every view of `cls`, those made later included, from the moment Spotify paints one: for a view the page
// makes again (Home's header element, rebuilt with the feed) that is painted as it is made, before any pass reaches it.
void SGRHoldClearClass(Class cls);

// Defined in Redesigned/Library/LibraryHeader.x, declared here because the repaint hook is lower than the
// part: a library filter chip's fill was just painted (selected, deselected, pressed), so its glass is brought
// in line with the paint -- shown over a clear fill, hidden under a selected colour -- without a layout pass.
void SGRLibraryChipPainted(UIView *chip);
// Whether `chip` is in one of the rows of chips that are glass (the library's, the search results', Add songs'): only
// those lose their fill. Defined there too.
BOOL SGRIsGlassChip(UIView *chip);
