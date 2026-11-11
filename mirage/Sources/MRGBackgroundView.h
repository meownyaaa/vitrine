// The background itself: a still (pre-blurred once with Core Image) or a looping, muted video
// (one shared AVQueuePlayer + AVPlayerLooper for every screen, blurred on the GPU through an
// AVVideoComposition), under a black dim layer. It never takes touches.
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>

@interface MRGVideoEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) AVQueuePlayer *player;
- (void)reload;              // after the media or the blur changed
- (void)viewAppeared:(id)view;
- (void)viewDisappeared:(id)view;
@end

// The view itself fills (and clips to) its host's bounds; the picture inside it is drawn on a canvas the
// size of the window, placed where the window is, so it stays full-bleed and never re-crops when the host
// is shorter (keyboard), narrower, offset (a nav container, a sliding transition) or growing (the now
// playing plane). Two pages sliding past each other show two halves of one still picture.
@interface MRGBackgroundView : UIView
+ (UIImage *)currentStill;   // cached, blurred
- (void)refresh;             // re-read the settings
- (void)pinCanvas;           // place the canvas over the window again (cheap when nothing moved)
@end

// The window-sized rect, in the coordinates of `view`, ignoring transforms (a sheet mid-animation is
// scaled; the picture should be laid out for where it ends up, and the transform then applies to it).
CGRect MRGWindowRectInView(UIView *view);
