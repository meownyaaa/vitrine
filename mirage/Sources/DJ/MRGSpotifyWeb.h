// Spotify's Web API (api.spotify.com/v1), called with the bearer token of the app's own spclient requests
// (MRGSpotifyHeaders), for what the DJ needs that the player does not hold: the user's top and liked tracks
// (taste), a search per suggested track (title and artist to a track URI), and the private "Mirage DJ"
// playlist used when the player will not take a list of tracks directly. Nothing here goes to the AI provider.
#import <Foundation/Foundation.h>

// Names only: title, artist. Empty when the token is not there yet or the API refuses it.
void MRGWebTaste(void (^done)(NSArray<NSDictionary *> *topTracks, NSArray<NSString *> *topArtists, NSArray<NSDictionary *> *liked));
// The match, only when title and artist both match a real track: uri (spotify:track:…), title and artist as
// Spotify has them, image (an https cover URL, about 300px, when Spotify has one), or nil.
void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSDictionary *track, NSString *error));
// The cover of a track by its URI (GET /tracks/{id}), cached for the session; nil when there is none.
void MRGWebTrackImage(NSString *uri, void (^done)(NSString *imageURL));
// https://i.scdn.co/image/… for a spotify:image:… id or an https URL; nil otherwise.
NSString *MRGImageURL(NSString *spotifyImage);
// Fills the private "Mirage DJ" playlist with the URIs (made the first time) and hands back its URI.
void MRGWebFillDJPlaylist(NSArray<NSString *> *uris, void (^done)(NSString *playlistURI, NSString *error));
// The account's plan from GET /me ("premium", "free"…), logged; nil when unknown.
void MRGWebAccount(void (^done)(NSString *product, NSString *error));
