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
// The frame on screen now (or the last one seen), oriented and blurred like the video, for a background
// view that has just been made to show until its own player layer has a frame: no dark flash.
- (UIImage *)posterFrame;
@end

// The view itself fills (and clips to) its host's bounds; the picture inside it is drawn on a canvas the
// size of the window, placed where the window is, so it stays full-bleed and never re-crops when the host
// is shorter (keyboard), narrower, offset (a nav container, a sliding transition) or growing (the now
// playing plane). Two pages sliding past each other show two halves of one still picture.
@interface MRGBackgroundView : UIView
+ (UIImage *)currentStill;   // cached, blurred
- (void)refresh;             // re-read the settings
- (void)pinCanvas;
// A preview: the picture is laid out for the view's own bounds rather than the window's.
@property (nonatomic) BOOL fitsBounds;
// Added to the dim setting (the side drawer's text sits right on the picture).
@property (nonatomic) CGFloat extraDim;
// 0.5.2: when set (Now Playing's card), the picture moves with this view instead of staying put on the window, so
// pulling the player down drags its background along.
@property (nonatomic, weak) UIView *followView;           // place the canvas over the window again (cheap when nothing moved)
@end

// The window-sized rect, in the coordinates of `view`, ignoring transforms (a sheet mid-animation is
// scaled; the picture should be laid out for where it ends up, and the transform then applies to it).
CGRect MRGWindowRectInView(UIView *view);
