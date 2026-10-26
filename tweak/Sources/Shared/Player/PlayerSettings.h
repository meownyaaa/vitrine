// Settings of the player that hold for either look.
#import <UIKit/UIKit.h>

UIViewController *SGLockScreenWidgetPage(void);

// Switch to video hidden from the player under either look (VideoSwitch.x), off until switched on.
#define SGKeyHideVideoSwitch @"spotifyglass.hide.videoSwitch"

// A tap on the cover opens Spotify's full screen cover unless this is on, under either look: each look's
// handleTap hook on CoverArtTiltView (PlayerGestures.x) returns before Spotify's. Off until switched on.
#define SGKeyHideFullScreenCover @"spotifyglass.hide.fullScreenCover"
