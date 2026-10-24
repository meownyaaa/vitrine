#import <Foundation/Foundation.h>
@class UIView, UIViewController;
BOOL SGAlbumQueueIsAlbumURI(NSString *uri);

// Spotify's ⋯ buttons. An album header's identifier ends in the album's id.
#define SGAlbumQueueButtonPrefix @"Components.UI.ContextMenuButton-"

// Records the album of a tapped header ⋯, checked against Spotify's Creative Work page.
void SGAlbumQueueMarkSource(UIView *view);
void SGAlbumQueueInstall(UIViewController *menu);
// Resolves the album, then uses Spotify's bulk queue command. Completion is on main.
void SGAlbumQueueAdd(NSString *uri, void (^done)(NSUInteger count, NSString *error));
// Strict context response parser: order and repeated tracks are preserved; partial albums fail.
NSArray<NSString *> *SGAlbumQueueTrackURIs(id context, NSString *uri, NSString **error);
