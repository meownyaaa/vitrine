// Spotify's Web API (api.spotify.com/v1), called with the bearer token of the app's own spclient requests
// (MRGSpotifyHeaders), for what the DJ needs that the player does not hold: the user's top and liked tracks
// (taste), a search per suggested track (title and artist to a track URI), and the private "Mirage DJ"
// playlist used when the player will not take a list of tracks directly. Nothing here goes to the AI provider.
#import <Foundation/Foundation.h>

// Names only: title, artist. Empty when the token is not there yet or the API refuses it.
void MRGWebTaste(void (^done)(NSArray<NSDictionary *> *topTracks, NSArray<NSString *> *topArtists, NSArray<NSDictionary *> *liked));
// spotify:track:… for the best match, or nil.
void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSString *uri, NSString *error));
// Fills the private "Mirage DJ" playlist with the URIs (made the first time) and hands back its URI.
void MRGWebFillDJPlaylist(NSArray<NSString *> *uris, void (^done)(NSString *playlistURI, NSString *error));
