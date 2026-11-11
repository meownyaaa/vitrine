// Facts about an artist or a song for "who is clairo"-style questions, from real sources only:
//  - Spotify (Web API with the app's token): image, followers, popularity, genres, top tracks; monthly listeners from
//    the public open.spotify.com artist page when it answers.
//  - Wikipedia's REST summary (en.wikipedia.org/api/rest_v1/page/summary/<title>), only a music page.
//  - Gemini's Google Search grounding, when Gemini is the provider.
// Every dictionary carries "sources" ({title, url}) for what was actually used. Nothing is made up here.
#import <Foundation/Foundation.h>

// name, uri, image, followers, popularity, genres, monthlyListeners (string like "12.3M"), topTracks (track dicts),
// wiki ({title, extract, url}), web ({text}), sources; or error when Spotify doesn't know the artist.
void MRGArtistInfo(NSString *name, void (^done)(NSDictionary *info));
// title, artist, uri, image, album, released, popularity, wiki, web, sources; or error.
void MRGTrackInfo(NSString *title, NSString *artist, void (^done)(NSDictionary *info));
// The facts as compact text for a model to answer from (never more than about 2000 characters).
NSString *MRGInfoFacts(NSDictionary *info);
// A chat card ({type: "info", info}) for MRGChatView.
NSDictionary *MRGInfoCard(NSDictionary *info);
