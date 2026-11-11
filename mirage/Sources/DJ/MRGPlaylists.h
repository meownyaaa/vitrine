// Playlist changes through Spotify's own playlist engine, the way the app itself makes them: Esperanto calls
// (SPTEsperantoTransportBridgeImpl -callSingle:method:payload:onResponse:, the ObjC bridge every ESP*Client uses) to
//   spotify.playlist_esperanto.proto.RootlistModificationService  (create a playlist, remove one from your library)
//   spotify.playlist_esperanto.proto.PlaylistService               (add and remove tracks, find a track's rows)
// with protobuf payloads hand-encoded from the schemas embedded in the app (rootlist_modification_request.proto,
// playlist_modification_request.proto, modification_request.proto, playlist_find_request.proto). Method names follow
// the app's ESP naming (PascalCase rpc names, "Modify"/"Find"); the names Spotify itself calls on these services are
// recorded at runtime and preferred. Every attempt and answer goes to the DJ log. Nothing here uses the Web API.
#import <Foundation/Foundation.h>

typedef void (^MRGPlaylistDone)(BOOL ok, NSString *uri, NSString *error);

BOOL MRGPlaylistsAvailable(void);   // a transport has been seen (Spotify made at least one Esperanto call)
void MRGPlaylistCreate(NSString *name, NSArray<NSString *> *trackURIs, MRGPlaylistDone done);   // uri: the new playlist
void MRGPlaylistAdd(NSString *playlistURI, NSArray<NSString *> *trackURIs, MRGPlaylistDone done);
void MRGPlaylistRemove(NSString *playlistURI, NSArray<NSString *> *trackURIs, MRGPlaylistDone done);
// Removes the playlist from your library: for a playlist you own Spotify treats that as deleting it (it can be
// recovered at spotify.com/account/recover-playlists); for someone else's it unfollows.
void MRGPlaylistDelete(NSString *playlistURI, MRGPlaylistDone done);

// Playlists Mirage made (name, uri, created), newest first; kept on this phone.
NSArray<NSDictionary *> *MRGPlaylistsMade(void);
// A spotify:playlist: URI from a link or URI string, or nil.
NSString *MRGPlaylistURIFrom(NSString *text);
// What Mirage has seen Spotify call on its playlist services (service/method pairs), for the log and diagnostics.
NSArray<NSString *> *MRGPlaylistSeenMethods(void);
