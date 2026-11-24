// The selection bubble of the capsule bar (TabBarLegacy.x), made to move the way iOS 26's does. At rest it is the
// dark pill under the open tab. A finger on the bar lifts it into a transparent glass bubble that follows the finger on two
// springs, one for each edge: the edge in front of the move is the stiffer one, so the bubble stretches along the
// move and the back edge trails, then overshoots a little as it stops. A released bubble settles on the tab it was
// let go over, and turns back into the pill on the way.
//
// All of it is in the coordinates of the view the lens stands in. Nothing here knows about tabs: the bar tells it
// where the open tab's pill rests and where the finger is.
#import <UIKit/UIKit.h>

@interface SGRLegacyLens : UIView

// Where the pill rests, in the superview's coordinates. Not `frame`: the bubble is stretched with a transform.
@property (nonatomic, readonly) CGRect restFrame;
@property (nonatomic, readonly) BOOL touching;
// How far the held bubble reaches past the pill above and below (the bar sets it so the bubble stands a little
// out of the capsule's rim, as the system's does).
@property (nonatomic) CGFloat heldOutset;

// A new place for the pill (a tab was picked, the bar was laid out again). Slides there on the same springs as a
// released bubble when `animated`; a change of size, the first call and Reduce Motion cut.
- (void)setRestFrame:(CGRect)frame animated:(BOOL)animated;

// A finger down on the bar at `x`, free to run between the centers `minCenter` and `maxCenter` (a little past them).
- (void)beginTouchAtX:(CGFloat)x minCenter:(CGFloat)minCenter maxCenter:(CGFloat)maxCenter;
- (void)moveTouchToX:(CGFloat)x;
// The finger is up or the touch was taken away: the bubble goes back to the rest frame.
- (void)endTouch;
// Gets whatever the lens has to show onto the screen now rather than at the end of the run loop turn: the bar calls it
// right after endTouch, before the tab it picked starts loading, which can hold the main thread for a while.
- (void)flush;

@end
