// Mirage's own line to Spotify's player (the same hooks Vitrine's Shared/Player/PlayerState.x uses, kept
// separate so Mirage runs without Vitrine): the SPTEsperantoPlayer, its state as it changes, a short log of
// what was played (names only, kept on the phone), the headers of Spotify's own spclient requests for the
// Web API calls, playing a list of track URIs, and ducking the music while the DJ talks.
#import <Foundation/Foundation.h>

extern NSString *const MRGPlayerTrackChangedNotification;   // main queue; userInfo: uri, title, artist, ad

id MRGPlayerInstance(void);
NSDictionary *MRGNowPlaying(void);                 // uri, title, artist, image (https, when the player has one), or nil
NSArray<NSDictionary *> *MRGRecentHistory(void);   // newest first: title, artist (Mirage's own log, max 40)
NSArray<NSDictionary *> *MRGQueueAround(void);     // the player's past and coming tracks: title, artist
BOOL MRGPlayerIsAd(void);

// The authorization (and client-token etc.) Spotify's own requests carry; nil until one has gone out.
NSDictionary<NSString *, NSString *> *MRGSpotifyHeaders(void);

BOOL MRGPlayerIsPlaying(void);       // a track on, not paused
NSString *MRGPlayerContextURI(void);   // what the player is playing from (spotify:playlist:…), or nil

// Plays a context by URI (a playlist, album or track) as Spotify's own Play buttons do, starting at `startTrack` when
// given (sent again without it when that is refused). `done` says whether the player took the command, not that sound
// came out: MRGWaitForPlayback checks that.
void MRGPlayContextURI(NSString *uri, NSString *startTrack, void (^done)(BOOL ok, NSString *error));
// Adds tracks to Spotify's queue; call it once the context is playing (earlier, the player answers 409 Conflict).
void MRGQueueTracks(NSArray<NSString *> *uris, void (^done)(BOOL ok, NSString *error));
// Hands a spotify: URI to Spotify's own link dispatcher, as a tapped link would (opens its page). NO when not captured.
BOOL MRGOpenSpotifyURI(NSString *uri);
// Waits until the player is on one of the tracks or in the context, not paused; `seen` says what it saw instead.
void MRGWaitForPlayback(NSArray<NSString *> *tracks, NSString *contextURI, NSTimeInterval timeout, void (^done)(BOOL ok, NSString *seen));

// Lowers Spotify's own output to 30% while the DJ speaks (a render notify on Spotify's output units, eased so
// it never clicks) and brings it back. NO when Spotify's AudioOutputUnitStart could not be rebound: the DJ
// then talks over the music at full level.
BOOL MRGDuckMusic(BOOL duck);
