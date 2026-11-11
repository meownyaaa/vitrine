// Spotify's Web API (api.spotify.com/v1), called with the bearer token of the app's own spclient requests
// (MRGSpotifyHeaders), for one thing only: a search per suggested track (title and artist to a track URI). The user
// endpoints (/me, /me/top, /me/tracks, /me/playlists) answer 404 to that token, so Mirage no longer calls them; taste
// and playback come from Spotify's own player. Nothing here goes to the AI provider.
#import <Foundation/Foundation.h>

// The match, only when title and artist both match a real track: uri (spotify:track:…), title and artist as
// Spotify has them, image (an https cover URL, about 300px, when Spotify has one), popularity (0-100, when the
// search gives it), album, released, or nil.
void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSDictionary *track, NSString *error));
// https://i.scdn.co/image/… for a spotify:image:… id or an https URL; nil otherwise.
NSString *MRGImageURL(NSString *spotifyImage);
// Web API search (type track, artist, album or playlist): tracks as MRGWebResolve's dictionaries; the others as uri,
// name, image, popularity, genres (artists), owner (playlists), artist (albums).
void MRGWebSearch(NSString *query, NSString *type, NSInteger limit, void (^done)(NSArray<NSDictionary *> *results, NSString *error));

// Artist lookups for requests that name an artist (all through the Web API search, with fallbacks; never throw):
// the artist meant by a typed name or abbreviation: uri, name, image, popularity, genres (how: which search found it).
void MRGWebFindArtist(NSString *query, void (^done)(NSDictionary *artist, NSString *how));
// Their most played tracks (MRGWebResolve dictionaries), up to limit.
void MRGWebArtistTracks(NSDictionary *artist, NSInteger limit, void (^done)(NSArray<NSDictionary *> *tracks));
void MRGWebRelatedArtists(NSDictionary *artist, void (^done)(NSArray<NSDictionary *> *artists));
void MRGWebArtist(NSString *uri, void (^done)(NSDictionary *artist));
// Fuzzy name matching shared with the DJ.
void MRGWebArtistCatalog(NSDictionary *artist, NSInteger max, void (^done)(NSArray<NSDictionary *> *tracks));
void MRGWebLabelArtists(NSString *label, void (^done)(NSArray<NSDictionary *> *artists));
BOOL MRGNamesMatch(NSString *a, NSString *b);
NSInteger MRGEditDistance(NSString *a, NSString *b);
