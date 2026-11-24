// The full screen player's open and close, for whatever must stand still while it animates (the
// karaoke card puts its display link down, the redesign holds heavy work back). Both looks' players are
// presented by Spotify's own presentation controller, so one announcement serves both.
#import <UIKit/UIKit.h>

// Posted as the player starts to open or close, before the animation runs, and again once it is
// over; SGPlayerTransitionEnds says when it is expected to be over (as CACurrentMediaTime), 0 when none runs.
extern NSString *const SGPlayerTransitionNotification;
extern NSString *const SGPlayerTransitionEndedNotification;
CFTimeInterval SGPlayerTransitionEnds(void);
// Whether the full screen player is open, or opening: YES from the moment it starts to come up until it starts to go,
// and back as it was when a swipe is let go of before it has gone.
BOOL SGPlayerIsOpen(void);
