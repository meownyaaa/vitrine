// The native player's hookup of the gestures (Shared/Gestures): the double tap goes on the player's artwork list.
// And the hold to play faster on the cover, the native look's copy of the redesign's (Redesigned/Player/
// PlayerArtwork.x).
//
// Tree (trees/now-playing.txt): the artwork sits in AccessibleCollectionView, a full screen list of
// the queue scrolled sideways, so the recognizer goes on that and the grid is the screen. Spotify's
// controls are sibling units rather than children of it, so a tap on a button never reaches it.
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Gestures/Gestures.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Player/SpeedPitch.h"
#import "Shared/Player/PlayerSettings.h"

#pragma mark - hold to play faster

// Holding either side of the cover plays at kHoldSpeed until the finger lifts, and the speed set before
// comes back. The middle third is left alone, and a hold that starts to move is a swipe to the next track.
// It is a speed like the menu's, so with Pitch follows speed on (until switched off) it also plays an
// octave higher, the way a record does.
static const double kHoldSpeed = 2;
// The now playing bar's cover has a tilt view of its own, 40pt; the player's is about 354.
static const CGFloat kCoverMinWidth = 200;
static char kHoldKey;
// The badge comes in quickly and goes quicker: the finger is already off the cover. The way out is the
// redesign's SGRMotionExit (Redesigned/Kit/SGRTokens.h), copied since the native look cannot import the Kit.
static const NSTimeInterval kBadgeEnter = 0.2, kBadgeExit = 0.15;

@interface SGCoverHold : UILongPressGestureRecognizer
@end

@implementation SGCoverHold {
    double _before;
    UIVisualEffectView *_badge;
    UILabel *_badgeLabel;
    BOOL _badgeShown;
}

- (void)sg_held {
    UIView *cover = self.view;
    if (self.state == UIGestureRecognizerStateBegan) {
        CGFloat x = [self locationInView:cover].x, third = cover.bounds.size.width / 3;
        if ((x > third && x < 2 * third) || !SGPlayerSpeedAllowed()) {
            self.enabled = NO;
            self.enabled = YES;   // cancels this hold
            return;
        }
        _before = SGPlayerSpeed();
        SGSetPlayerSpeed(kHoldSpeed);
        SGPlayFeedback(SGFeedbackGrab);
        [self showBadge:YES on:cover];
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, @"Playing at 2 times speed");
    } else if (self.state == UIGestureRecognizerStateEnded || self.state == UIGestureRecognizerStateCancelled
               || self.state == UIGestureRecognizerStateFailed) {
        if (_before > 0) SGSetPlayerSpeed(_before);
        _before = 0;
        [self showBadge:NO on:cover];
    }
}

// "2×" and a forward glyph on a capsule of the look's glass (SGGlassEffect: Liquid Glass from iOS 26, the dark
// chrome blur before) at the top of the cover while it is held. What fades is the effect, never an alpha
// over it, which UIKit draws a blur under wrongly or not at all.
- (void)showBadge:(BOOL)shown on:(UIView *)cover {
    if (shown && !_badge) {
        _badgeLabel = [UILabel new];
        UIFont *font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        NSTextAttachment *arrows = [NSTextAttachment textAttachmentWithImage:[[UIImage systemImageNamed:@"forward.fill"
            withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font]] imageWithTintColor:UIColor.whiteColor
            renderingMode:UIImageRenderingModeAlwaysOriginal]];
        NSMutableAttributedString *text = [[NSMutableAttributedString alloc] initWithString:@"2×  "
            attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.whiteColor}];
        [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:arrows]];
        _badgeLabel.attributedText = text;
        _badgeLabel.textAlignment = NSTextAlignmentCenter;
        _badge = [[UIVisualEffectView alloc] initWithEffect:nil];
        _badge.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _badge.userInteractionEnabled = NO;
        _badge.frame = CGRectMake(0, 0, 92, 34);
        SGShapeGlass(_badge, 17, YES);
        _badgeLabel.frame = _badge.bounds;
        [_badge.contentView addSubview:_badgeLabel];
    }
    if (!_badge) return;
    _badgeShown = shown;
    UIVisualEffectView *badge = _badge;
    UILabel *label = _badgeLabel;
    if (shown) {
        if (badge.superview != cover) {
            badge.center = CGPointMake(CGRectGetMidX(cover.bounds), 30);
            badge.effect = nil;
            label.alpha = 0;
            badge.transform = UIAccessibilityIsReduceMotionEnabled() ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.9, 0.9);
            [cover addSubview:badge];
        }
        [UIView animateWithDuration:kBadgeEnter delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            badge.effect = SGGlassEffect();
            label.alpha = 1;
            badge.transform = CGAffineTransformIdentity;
        } completion:nil];
    } else {
        [UIView animateWithDuration:kBadgeExit delay:0 options:UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            badge.effect = nil;
            label.alpha = 0;
        } completion:^(BOOL finished) {
            if (finished && !self->_badgeShown) [badge removeFromSuperview];
        }];
    }
}

@end

// The player's cover cells, whichever Spotify builds (the strings are in 9.1.78's binary); a tilt view
// elsewhere, an album's header, is left alone.
static BOOL inPlayerCover(UIView *tilt) {
    static NSArray<Class> *cells;
    if (!cells) {
        NSMutableArray<Class> *found = [NSMutableArray array];
        for (NSString *name in @[@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl", @"_TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl",
                                 @"_TtC39ListeningParties_NowPlayingViewModeImpl34NowPlayingLiveRoomCoverArtCellImpl"]) {
            Class cell = NSClassFromString(name);
            if (cell) [found addObject:cell];
        }
        cells = found;
    }
    for (UIView *v = tilt.superview; v; v = v.superview) {
        for (Class cell in cells) if ([v isKindOfClass:cell]) return YES;
    }
    return NO;
}

static void watchHold(UIView *tilt) {
    if (objc_getAssociatedObject(tilt, &kHoldKey) || tilt.bounds.size.width < kCoverMinWidth || !inPlayerCover(tilt)) return;
    SGCoverHold *hold = [[SGCoverHold alloc] initWithTarget:nil action:nil];
    [hold addTarget:hold action:@selector(sg_held)];
    hold.minimumPressDuration = 0.35;
    [tilt addGestureRecognizer:hold];
    objc_setAssociatedObject(tilt, &kHoldKey, hold, OBJC_ASSOCIATION_ASSIGN);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"native player: hold to play faster on the cover (%@)", NSStringFromClass(tilt.superview.class)); });
}

#pragma mark - hooks

// A single tap on the cover is Spotify's way into the tilt mode, the artwork alone in 3D. That is
// the half of a double tap that misses, so while the zones are on it would open on the way to every
// gesture; the tap goes back to Spotify with the switch. Full screen cover hidden keeps it from Spotify too.
%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)handleTap {
    if (SGFlag(SGKeyGestures, NO) || SGHidden(SGKeyHideFullScreenCover)) return;
    %orig;
}
- (void)layoutSubviews {
    %orig;
    watchHold((UIView *)self);
}
%end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    SGGestureAttach((UIView *)self);
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    SGRequireClasses(@[
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
    ]);
}
