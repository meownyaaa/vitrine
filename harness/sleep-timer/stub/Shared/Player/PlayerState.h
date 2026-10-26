// The calls SleepTimer.m and SpotifySleepTimer.m make of PlayerState.h, without UIKit; main.m answers them.
#import <Foundation/Foundation.h>
#import "Headers/SPTPlayer.h"
NSString *SGURIString(id uri);
@protocol SGPlayerStateObserver <NSObject>
- (void)playerStateDidChange:(SPTPlayerState *)state;
@optional
- (void)playerStateDidReport:(SPTPlayerState *)state;
@end
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer);
