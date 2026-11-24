// Colored segment overlay for Spotify's Now Playing progress bar.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).

#import <UIKit/UIKit.h>

@interface SGSponsorBlockOverlay : NSObject

+ (void)attachToSlider:(UIView *)slider;
+ (void)refreshAll;

@end
