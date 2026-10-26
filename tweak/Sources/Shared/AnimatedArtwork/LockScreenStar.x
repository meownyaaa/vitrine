// The lock screen widget's star: a tap switches the full-screen artwork between moving artwork and the
// lyrics, at once, by writing the choice LockScreenMotion.x and LyricsArtwork.x both watch. The star is
// MediaPlayer's like command, the slot Apple Music's Favorite star takes; it is filled while the lyrics
// show, under Lyrics or Moving artwork with lyrics. Spotify's own like and dislike buttons (its like_dislike flag) take the same slot, so the flag
// is forced off while the switch is on and the Lock screen page's row shows it locked. iOS 26 only, as
// the artwork is.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "Shared/Player/PlayerState.h"

static NSString *const kLikeDislikeFlag = @"ios-feature-lockscreen.like_dislike_enabled";
static MPFeedbackCommand *sg_like;   // the command while the star is on it, else nil
static id sg_target;

static BOOL starOn(void) {
    return SGHidden(SGKeyLockScreenStar) && SGLockScreenArtwork() != SGLockArtworkOff;
}

static MPRemoteCommandHandlerStatus tapped(void) {
    SGLockArtwork choice = SGLockScreenArtwork();
    if (choice == SGLockArtworkOff) return MPRemoteCommandHandlerStatusCommandFailed;
    dispatch_async(dispatch_get_main_queue(), ^{
        // Back to the choice the star left when that one is on the other side, with lyrics or without; else to
        // Lyrics or Moving artwork. So Lyrics and Moving artwork with lyrics each swap with the moving artwork.
        BOOL lyrics = SGLockArtworkShowsLyrics(choice);
        SGLockArtwork back = (SGLockArtwork)SGInt(SGKeyLockScreenStarBack, SGLockArtworkOff);
        BOOL valid = back > SGLockArtworkOff && back <= SGLockArtworkMotionLyrics && SGLockArtworkShowsLyrics(back) != lyrics;
        SGSetInt(SGKeyLockScreenStarBack, choice);
        SGSetInt(SGKeyLockScreenArtwork, valid ? back : lyrics ? SGLockArtworkMotion : SGLockArtworkLyrics);
        SGLog(@"lock star: tapped, the lock screen takes %ld", (long)SGLockScreenArtwork());
    });
    return MPRemoteCommandHandlerStatusSuccess;
}

// Main thread, on every defaults write and player state: the command is touched only when the star's state
// changed, or when Spotify's lock screen policy turned it off under the star, which the log says.
static void arm(void) {
    static BOOL lastOn, lastActive;
    BOOL on = starOn(), active = on && SGLockArtworkShowsLyrics(SGLockScreenArtwork());
    if (sg_like && !sg_like.enabled) {
        static int told;
        if (told++ < 3) SGLog(@"lock star: the like command was off under the star, set again");
        sg_like.enabled = YES;
    }
    if (on == lastOn && active == lastActive && on == (sg_like != nil)) return;
    lastOn = on;
    lastActive = active;
    if (!on && !sg_like) return;   // the command is Spotify's
    MPFeedbackCommand *like = MPRemoteCommandCenter.sharedCommandCenter.likeCommand;
    if (!on) {
        [like removeTarget:sg_target];
        sg_target = nil;
        sg_like = nil;
        like.enabled = NO;
        like.active = NO;
        SGLog(@"lock star: off");
        return;
    }
    if (!sg_like) {
        // Spotify's handler, if the flag had it on one, would like the song on the same tap.
        [like removeTarget:nil];
        sg_target = [like addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) { return tapped(); }];
        like.localizedTitle = @"Lock screen lyrics";
        sg_like = like;
        SGLog(@"lock star: on the like command");
    }
    like.enabled = YES;
    like.active = active;
}

// Spotify's two ways of taking the like command back under the star: turning it off is kept on; taking the
// handlers off is let through and logged, with the star armed again on the next player state.
%hook MPRemoteCommand
- (void)setEnabled:(BOOL)enabled {
    if (!enabled && sg_like && self == sg_like) {
        static int told;
        if (told++ < 3) SGLog(@"lock star: Spotify turned the like command off, kept on");
        enabled = YES;
    }
    %orig(enabled);
}
- (void)removeTarget:(id)target {
    if (sg_like && self == sg_like && target != sg_target) {
        SGLog(@"lock star: Spotify took %@ off the like command", target ? @"its handler" : @"every handler");
        if (!target) sg_like = nil;
    }
    %orig;
}
%end

@interface SGLockScreenStar : NSObject <SGPlayerStateObserver>
@end

@implementation SGLockScreenStar
- (void)playerStateDidChange:(SPTPlayerState *)state {
    arm();
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        // Read at launch as Spotify reads the flag; the row locks from the switches as they are stored now.
        BOOL atLaunch = starOn();
        SGRegisterFlagForcer(YES, ^id(NSString *key) {
            return atLaunch && [key isEqualToString:kLikeDislikeFlag] ? @NO : nil;
        }, ^id(NSString *key) {
            return starOn() && [key isEqualToString:kLikeDislikeFlag] ? @NO : nil;
        });
        %init;
        static SGLockScreenStar *observer;
        observer = [SGLockScreenStar new];
        SGAddPlayerStateObserver(observer);
        // Heard on the writing thread and handed to main without waiting (AGENTS.md).
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            SGPrefsChanged();
            dispatch_async(dispatch_get_main_queue(), ^{ arm(); });
        }];
        SGLog(@"lock star: %@", atLaunch ? @"on, Spotify's like and dislike buttons forced off" : @"off");
    }
}
