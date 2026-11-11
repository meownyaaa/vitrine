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

@interface MRGBackgroundView : UIView
+ (UIImage *)currentStill;   // cached, blurred
- (void)refresh;             // re-read the settings
@end
