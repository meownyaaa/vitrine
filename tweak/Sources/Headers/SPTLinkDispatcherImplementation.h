// Spotify's link dispatcher, a singleton the app builds at startup; the route the app itself takes
// for a link it opens.
#import <Foundation/Foundation.h>

@interface SPTLinkDispatcherImplementation : NSObject
- (void)navigateToURI:(NSURL *)uri options:(long long)options interactionID:(id)interactionID;
- (void)navigateToURI:(NSURL *)uri options:(long long)options reason:(id)reason completionHandler:(id)completionHandler resultHandler:(id)resultHandler;
- (BOOL)navigateToInternalURI:(NSURL *)uri options:(long long)options reason:(id)reason resultHandler:(id)resultHandler;
- (void)URISchemeDispatcher:(id)dispatcher showInvalidSpotifyLinkMessageForURI:(NSURL *)uri;
- (void)URISchemeDispatcher:(id)dispatcher showInvalidLinkMessageForURI:(NSURL *)uri;
@end
