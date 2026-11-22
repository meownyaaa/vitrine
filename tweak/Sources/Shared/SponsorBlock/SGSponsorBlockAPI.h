// SponsorBlock API client for Spotify podcast skip segments.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.
#import <Foundation/Foundation.h>
#import "SGSponsorBlock.h"

@interface SGSponsorBlockAPI : NSObject

+ (void)fetchSegmentsForEpisode:(NSString *)episodeID
                     categories:(NSArray<NSString *> *)categories
                     completion:(void (^)(NSArray<SGSponsorBlockSegment *> *segments, NSError *error))completion;

@end
