// The line being sung in place of the artist in the system's now playing: lock screen, Dynamic Island,
// Control Center, CarPlay. There is a Live Activity for it too (Shared/LiveActivity). The
// lines and the clock come from Karaoke.
#import <Foundation/Foundation.h>

#define SGKeyLockScreenLyrics @"spotifyglass.lockScreenLyrics"
// The line's translation in its place, for lines that already have one (as the Live Activity's Translations).
#define SGKeyLockScreenTranslation @"spotifyglass.lockScreenLyrics.translation"

// Moving artwork with lyrics: the moving artwork clip found for the track `uri`, a local file, which
// LyricsArtwork.x draws the lines over while that track plays. Main queue.
void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file);
