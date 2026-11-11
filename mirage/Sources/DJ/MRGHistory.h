// The listening history the DJ chat can answer from, kept on this phone only (Library/Mirage/history.plist):
//  - live: every track Mirage sees start from now on (timestamp, title, artist, uri, about how long it played); a
//    play counts at 30 s, as in Spotify's own exports. Time played is wall time to the next track, capped at the
//    track's length, so a long pause inside a track can overcount it.
//  - imported: Spotify's "Extended streaming history" export (Streaming_History_Audio_*.json, or the my_spotify_data
//    ZIP holding them; fields ts, master_metadata_track_name, master_metadata_album_artist_name, spotify_track_uri,
//    ms_played), and the shorter "Account data" StreamingHistory_music_*.json (endTime, artistName, trackName,
//    msPlayed). Imported plays from after the moment live recording started are skipped, so nothing counts twice.
// Spotify's app keeps no full history Mirage can read: without an import, answers cover only what Mirage recorded.
#import <Foundation/Foundation.h>

extern NSString *const MRGHistoryChangedNotification;

typedef struct { NSUInteger plays; NSUInteger files; NSUInteger skipped; } MRGHistoryImportResult;

void MRGHistoryStart(void);   // begins live recording (called at launch)

// Imports a JSON file or a ZIP of them (off the main queue); done on the main queue with what was added, or an error.
void MRGHistoryImport(NSURL *file, void (^done)(NSUInteger plays, NSUInteger files, NSString *error));
void MRGHistoryClear(BOOL imported, BOOL live);

// What the history covers: plays, minutes, from, to (NSDate), liveSince (NSDate or nil), importedPlays, livePlays,
// importedFiles (names).
NSDictionary *MRGHistorySummary(void);
// The first play of an artist (fuzzy name match): artist, first (NSDate), firstTrack, firstURI, plays, minutes,
// last (NSDate), source ("import"/"live"), or nil when the history has none.
NSDictionary *MRGHistoryArtist(NSString *name);
// A track's plays: title, artist, uri, first, last, plays, minutes, or nil.
NSDictionary *MRGHistoryTrack(NSString *title, NSString *artist);
// Top artists or tracks by minutes, for a year ("2023") or all time (nil): name (and artist for tracks), plays, minutes.
NSArray<NSDictionary *> *MRGHistoryTopArtists(NSString *year, NSUInteger limit);
NSArray<NSDictionary *> *MRGHistoryTopTracks(NSString *year, NSUInteger limit);
// The last plays recorded (live and imported), newest first: title, artist, uri, at (NSDate), ms.
NSArray<NSDictionary *> *MRGHistoryRecent(NSUInteger limit);
// Minutes and plays per year: year, plays, minutes.
NSArray<NSDictionary *> *MRGHistoryYears(void);
// The listener's taste for the DJ: onRepeat [{title, artist, uri, plays}] (last 28 days), recentArtists [names],
// allTimeArtists [names], throwbacks [{title, artist, uri, plays, year}] (well played, not for 4 months).
NSDictionary *MRGHistoryTaste(void);
