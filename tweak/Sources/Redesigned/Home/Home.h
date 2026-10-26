// The Home redesign: Spotify's Home page kept, with its controllers, lists and cards, decluttered to a
// music app on black and restyled from the Kit. Its settings are the Home page of Mod Settings (HomeSettings.m).
//
//     HomeSections.x   an allow list of the feed's sections: the shortcuts grid, the DJ and the shelves of
//                      cards stay unless switched off; video and playlist previews and the song suggestions
//                      stay only when switched on; episode cards and any new kind collapse. The DJ loses its
//                      heading, and the flags the redesign forces on Home
//     HomeShelves.m    a shelf's identity from its heading, the shelves seen lately and which are hidden
//     HomeFeed.swift   every section's shelf identity from Spotify's model of the feed, built or not
//     HomeSettings.m   the Home page of Mod Settings: Top picks, what stays on Home, one switch per shelf
//     HomeHeader.x     a large title where the filter pills were, the avatar at the trailing edge, no scrim
//     HomeHeadings.x   the shelves' headings in the Music app's size, drawn over Spotify's
//     HomeCards.x      the Encore button every card is: shortcut tiles (HomeTiles.m), continuous corners on the
//                      shelf covers, the DJ card at the card radius without its talking transcript
//     HomeTiles.m      a shortcut tile's picture run across the tile, blurred behind its title
//     HomeTopPicks.x   Top picks: the shelf nearest the top drawn large and moved above the shortcuts, each card
//                      the cover over a footer in its color
//     MadeForYouCovers.x  Made For You, a Hub page opened from Home: its cards' covers at Home's radius
//     HomePerf.x       FLEX builds: the frames of each scroll of Home and the time the hooks above took
//
// Every hook installs only while Redesigned UI is on (SGRedesignedUI).
// Threading: main thread only.
#import <UIKit/UIKit.h>

// The Home look (the first row of the Home page): Top picks and the color behind it, the tinted glass shortcut
// pills with their bold names, the title's glass pill with the filter menu and the page's color. Off, none of
// those hooks install and Home has the plain shortcuts and title. On until switched off; read at launch
// (SGRHomeLook).
#define SGRKeyHomeLook @"spotifyglass.redesign.home.look"
BOOL SGRHomeLook(void);
// Top picks (HomeTopPicks.x): the shelf nearest the top drawn large above the shortcuts. On until switched off.
#define SGRKeyHomeTopPicks @"spotifyglass.redesign.home.topPicks"
// The shelf Top picks draws, by its identity (SGRHomeShelfIdentity); unset, the first shelf.
#define SGRKeyHomeTopPicksFrom @"spotifyglass.redesign.home.topPicksFrom"
// The footer of a large card in its cover's color. On until switched off; off, the footer is the plain surface.
#define SGRKeyHomeTopPicksColour @"spotifyglass.redesign.home.topPicksColour"
// Top picks keeps Spotify's heading over its cards (drawn at the size of the other shelves' headings, HomeHeadings.x)
// when set; unset, the heading and the band it takes go. Read at launch.
#define SGRKeyHomeTopPicksHeading @"spotifyglass.redesign.home.topPicksHeading"
// The title row stays where it is as the feed scrolls under it, over the feed's hard top edge shaped to the row
// (HomeHeader.x), rather than rising and fading away. Off until switched on; read at launch.
#define SGRKeyHomeKeepTitle @"spotifyglass.redesign.home.keepTitle"
// Parts of Home hidden when set (HomeSections.x): the shortcuts grid and the DJ.
#define SGRKeyHomeHideShortcuts @"spotifyglass.redesign.home.hide.shortcuts"
#define SGRKeyHomeHideDJ @"spotifyglass.redesign.home.hide.dj"
// Parts of Home the redesign drops unless these are set: Spotify's carousel of songs to try and rate
// (Home_ContentEvaluationListElementKit) and its video and playlist previews (Discovery_MediumDensityCardKit,
// Discovery_PreviewElement).
#define SGRKeyHomeSongSuggestions @"spotifyglass.redesign.home.songSuggestions"
#define SGRKeyHomePreviews @"spotifyglass.redesign.home.previews"
// A shelf hidden when set: this prefix and the shelf's identity (SGRHomeShelfHideKey).
#define SGRKeyHomeShelfHidePrefix @"spotifyglass.redesign.home.hide.shelf."
// The shelves seen lately: identity -> the date it was last on Home (HomeShelves.m).
#define SGRKeyHomeShelvesSeen @"spotifyglass.redesign.home.shelvesSeen"

@class SGModRow;
SGModRow *SGRHomeTopPicksRow(void);
UIViewController *SGRHomeSettingsPage(void);   // for Mod Settings (App/ModSettings.x)

// HomeShelves.m. A shelf's identity is what its heading says, read off its labels after the shelf is laid out:
// the small line over the title when there is one ("More like …", for any artist), else the title ("Recents",
// an artist's name). nil while the shelf has no heading to read. Language-bound, as the headings are.
NSString *SGRHomeShelfIdentity(UIView *shelf);
// The identity a heading of these two lines gives: "More like …" for "More like" over "Chief Keef", else the title.
NSString *SGRHomeShelfIdentityFrom(NSString *small, NSString *title);
NSString *SGRHomeShelfTitle(UIView *shelf);        // the heading's title alone ("Chief Keef" under "More like")
void SGRHomeNoteShelf(NSString *identity);         // seen on Home now
NSArray<NSString *> *SGRHomeShelvesSeen(void);     // seen within 30 days, in the order first seen
NSString *SGRHomeShelfHideKey(NSString *identity);
BOOL SGRHomeShelfHidden(NSString *identity);
NSString *SGRHomeTopPicksFrom(void);               // the identity stored under SGRKeyHomeTopPicksFrom, nil for the first shelf

// Whether HomeSections.x has collapsed the section in this cell.
BOOL SGRHomeSectionCollapsed(UIView *cell);
// Has the page's list measure the section around `view` again, on the next turn of the run loop: for a shelf
// whose heading came in after the list sized it (HomeSections.x).
void SGRHomeMeasureAgain(UIView *view);

// Styles a shortcut tile (id=Shortcut.Card.Home) and keeps its picture in step with its cover (HomeTiles.m).
void SGRHomeStyleTile(UIView *tile);
// Takes a tile's styling off a button Spotify has reused for something else (a shelf card), which would wear the
// tile's surface and rim otherwise.
void SGRHomeUnstyleTile(UIView *button);
// A tile's corner radius: 14, measured off the reference's 48pt pills (41px at 3px/pt), continuous.
extern const CGFloat SGRHomeTileRadius;

// The surface color a cover gives a tile or a card (Kit/SGRPalette.h, +tintForImage:), kept by the image while it
// lives: from the cache at once, else worked out off the main thread. nil when the image has no bitmap to read.
// Main thread, calls back on it.
void SGRHomeTintForCover(UIImage *image, void (^completion)(UIColor *color));

// Styles a shelf card (id=Components.UI.HomeCard) drawn large by Top picks (HomeTopPicks.x): a footer in the
// cover's color under the cover. NO, and the card left as Spotify's, for one at Spotify's own size.
BOOL SGRHomeStyleLargeCard(UIView *card);

// Whether `view` is in the shelf Top picks draws large (HomeTopPicks.x), whose heading goes unless Show Top picks
// heading is on (HomeHeadings.x).
BOOL SGRHomeInTopPicks(UIView *view);
// Spotify's "Show all" of the shelf Top picks draws, while the shelf is on screen and offers one, and the shelf's
// title with it: the header's menu offers it (HomeHeader.x), the heading it sits in being gone. nil while Show Top
// picks heading keeps the heading.
UIControl *SGRHomeTopPicksShowAll(NSString **title);
// The page's color from the first large card's cover (HomeHeader.x draws it behind the title, fading to black);
// nil for none.
void SGRHomeSetPageTint(UIColor *color);

// FLEX builds only (HomePerf.x): a hook takes the time as it starts and hands it back as it ends; outside
// a FLEX build Begin returns 0 and End does nothing.
typedef NS_ENUM(NSUInteger, SGRHomeProbe) {
    SGRHomeProbeSections,
    SGRHomeProbeHeader,
    SGRHomeProbeHeadings,
    SGRHomeProbeCards,
    SGRHomeProbeTiles,
    // The hooks of the Home look (HomeCards.x, HomeTopPicks.x, HomeTiles.m).
    SGRHomeProbeLabels,          // UILabel setText:/setAttributedText: hook, every call
    SGRHomeProbeLabelsMatched,   // ... the ones under a Home card or tile, which mark the button
    SGRHomeProbeFrames,          // the playing indicator's setHidden: hook (a tile's pass asked for again)
    SGRHomeProbeListAttrs,       // the page list's layoutAttributesForElementsInRect:/ForItem: hooks
    SGRHomeProbeShelfLayout,     // the shelf's layoutSubviews hook (TouchCancellingCollectionView)
    SGRHomeProbeLargeCard,       // SGRHomeStyleLargeCard
    SGRHomeProbeTint,            // SGRHomeTintForCover asks (cache misses go off the main thread)
    SGRHomeProbeFeed,            // the walk of the feed's model for the shelves' headings (HomeFeed.swift)
    SGRHomeProbeCount,
};
CFTimeInterval SGRHomeProbeBegin(void);
void SGRHomeProbeEnd(SGRHomeProbe probe, CFTimeInterval began);
