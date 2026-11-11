// Mirage's own line to Spotify's player (the same hooks Vitrine's Shared/Player/PlayerState.x uses, kept
// separate so Mirage runs without Vitrine): the SPTEsperantoPlayer, its state as it changes, a short log of
// what was played (names only, kept on the phone), the headers of Spotify's own spclient requests for the
// Web API calls, playing a list of track URIs, and ducking the music while the DJ talks.
#import <Foundation/Foundation.h>

extern NSString *const MRGPlayerTrackChangedNotification;   // main queue; userInfo: uri, title, artist, ad

id MRGPlayerInstance(void);
NSDictionary *MRGNowPlaying(void);                 // uri, title, artist, or nil
NSArray<NSDictionary *> *MRGRecentHistory(void);   // newest first: title, artist (Mirage's own log, max 40)
NSArray<NSDictionary *> *MRGQueueAround(void);     // the player's past and coming tracks: title, artist
BOOL MRGPlayerIsAd(void);

// The authorization (and client-token etc.) Spotify's own requests carry; nil until one has gone out.
NSDictionary<NSString *, NSString *> *MRGSpotifyHeaders(void);

// Plays the URIs as one context, starting at the first. Falls back to queueing them and skipping to them.
void MRGPlayURIs(NSArray<NSString *> *uris, void (^done)(BOOL ok, NSString *how, NSString *error));
void MRGPlayContextURI(NSString *uri, void (^done)(BOOL ok, NSString *error));

// Lowers Spotify's own output (its equalizer unit's global gain) while the DJ speaks; NO when that unit
// is not reachable or the equalizer is bypassed, and the DJ talks over the music instead.
// Lowers Spotify's own output to 30% while the DJ speaks (a render notify on Spotify's output units, eased so
// it never clicks) and brings it back. NO when Spotify's AudioOutputUnitStart could not be rebound: the DJ
// then talks over the music at full level.
BOOL MRGDuckMusic(BOOL duck);
