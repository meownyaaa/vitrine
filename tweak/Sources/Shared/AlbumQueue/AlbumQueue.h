#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
@class UIView, UIViewController;
BOOL SGAlbumQueueIsAlbumURI(NSString *uri);
BOOL SGIsPlaylistURI(NSString *uri);
BOOL SGIsValidEntityURI(NSString *uri);
NSString *SGSanitizeEntityURI(NSString *raw);

// The confirmation notice shown under the Dynamic Island.
@interface SGAlbumQueueNotice : UIView
+ (void)showIn:(UIWindow *)window title:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol;
+ (void)showIn:(UIWindow *)window title:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol persistent:(BOOL)persistent;
@end

// Spotify's ⋯ buttons. An album header's identifier ends in the album's id.
#define SGAlbumQueueButtonPrefix @"Components.UI.ContextMenuButton-"

// Records the album of a tapped header ⋯, checked against Spotify's Creative Work page.
void SGAlbumQueueMarkSource(UIView *view);
void SGAlbumQueueInstall(UIViewController *menu);
// Resolves the album, then uses Spotify's bulk queue command. Completion is on main.
void SGAlbumQueueAdd(NSString *uri, void (^done)(NSUInteger count, NSString *error));
// Strict context response parser: order and repeated tracks are preserved; partial albums fail.
NSArray<NSString *> *SGAlbumQueueTrackURIs(id context, NSString *uri, NSString **error);
