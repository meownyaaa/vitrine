// What the harness does not compile: the accent hook (SGRAccent.x) and the repaint hook (SGRRepaint.x).
#import <UIKit/UIKit.h>
UIColor *SGRAccentColor(void) { return nil; }
__weak UIView *sgr_nowPlayingRoot = nil;
NSHashTable<UIView *> *sgr_nowPlayingPainted = nil;
__weak UIView *sgr_lyricsCardRoot = nil;
__weak UIView *sgr_lyricsPageRoot = nil;
__weak UIView *sgr_playlistRoot = nil;
__weak UIView *sgr_albumRoot = nil;
__weak UIView *sgr_artistRoot = nil;

// Redesigned/Kit/SGRBridges.x: SGRField.m asks whether the player is opening or closing for its moving field.
BOOL SGRPlayerIsTransitioning(void) { return NO; }
void SGRObservePlayerTransition(id owner, void (^began)(id owner), void (^ended)(id owner)) {}

// Shared/AlbumQueue/AlbumQueueMenu.x: a tapped album header ⋯ records its album for the menu; no menu here.
void SGAlbumQueueMarkSource(UIView *view) {}

// SGRRepaint.x, the layer hooks that keep a glassed sheet clear of Spotify's grey: the harness has no Spotify sheet.
__weak UIView *sgr_sheetChromeRoot = nil;
void SGRWatchSheetPaint(UIView *root) {}
// SGRSheetPills.x, for Encore's chips with a pill: the harness's chips are the Library's own, which have none.
BOOL SGRPillIsSelected(UIView *pill) { return NO; }
