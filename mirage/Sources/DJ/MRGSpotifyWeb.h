// Spotify's Web API (api.spotify.com/v1), called with the bearer token of the app's own spclient requests
// (MRGSpotifyHeaders), for one thing only: a search per suggested track (title and artist to a track URI). The user
// endpoints (/me, /me/top, /me/tracks, /me/playlists) answer 404 to that token, so Mirage no longer calls them; taste
// and playback come from Spotify's own player. Nothing here goes to the AI provider.
#import <Foundation/Foundation.h>

// The match, only when title and artist both match a real track: uri (spotify:track:…), title and artist as
// Spotify has them, image (an https cover URL, about 300px, when Spotify has one), or nil.
void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSDictionary *track, NSString *error));
// https://i.scdn.co/image/… for a spotify:image:… id or an https URL; nil otherwise.
NSString *MRGImageURL(NSString *spotifyImage);
