// Core SponsorBlock skipper conforming to SGPlayerStateObserver.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).

#import <Foundation/Foundation.h>
#import "Shared/Player/PlayerState.h"
#import "SGSponsorBlock.h"

@interface SGSponsorBlockSkipper : NSObject <SGPlayerStateObserver>

+ (instancetype)sharedSkipper;
- (void)start;

@property (nonatomic, copy, readonly) NSString *currentEpisodeID;
@property (nonatomic, copy, readonly) NSArray<SGSponsorBlockSegment *> *currentSegments;
@property (nonatomic, readonly) double episodeDuration;

@end
