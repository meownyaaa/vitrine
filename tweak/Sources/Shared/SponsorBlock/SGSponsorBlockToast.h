// Toast HUD for SponsorBlock skips with an Undo action and prompt skip banners.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.
#import <UIKit/UIKit.h>

@class SGSponsorBlockSegment;

@interface SGSponsorBlockToast : NSObject

+ (void)showWithCategory:(NSString *)category
                duration:(NSTimeInterval)duration
             undoHandler:(void (^)(void))undoHandler;

+ (void)showPromptForSegment:(SGSponsorBlockSegment *)segment
                   remaining:(NSTimeInterval)remaining
                 skipHandler:(void (^)(void))skipHandler;

+ (BOOL)isPresentingPromptForSegment:(SGSponsorBlockSegment *)segment;
+ (BOOL)isPresentingUndoToast;
+ (void)updateActiveToastTimeout;
+ (void)dismissIfPromptForSegment:(SGSponsorBlockSegment *)segment;
+ (void)dismiss;
+ (void)dismissImmediate:(BOOL)immediate;

@end
