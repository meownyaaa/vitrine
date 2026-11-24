// The lock screen's full-screen cover below iOS 26, with a jailbreak (SGKeyLockCoverAddon): Vitrine Addon
// in SpringBoard draws it (addons/haptics/LockCover.x), and from here it gets the track's moving artwork to draw in place
// of the still cover, the Canvas else Apple Music's animated cover, as iOS 26 takes them (LockScreenMotion.x).
//
// Each track is walked through the sources the lock screen's motion walks (SGMotionFollower). A clip found is copied to
// one file of Spotify's caches, kSGLockClipName, which SpringBoard reads through Spotify's data container (it finds the
// container by the now playing app), and the add-on is told by kSGRelayLockClip; a track with none tells it
// kSGRelayLockClipNone, and the add-on draws the still cover, or nothing with Cover without moving artwork off. A clip is
// drawn whole, 9:16 most of them, fitted to the screen's width on its cover blurred: nothing is cut to a key's shape here,
// as SpringBoard is not bound to the system's.
//
// Threading: the walk answers on the main queue; the copy runs on a queue of its own.
#import <notify.h>
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "AnimatedArtwork.h"
#import "Shared/Haptics/SGHapticRelay.h"
#import "Shared/Player/PlayerState.h"

static SGMotionFollower *sg_follower;
static dispatch_queue_t sg_queue;
static NSUInteger sg_walk;

static NSURL *clipFile(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@kSGLockClipName];
}

static BOOL wanted(void) {
    return SGFlag(SGKeyLockCoverAddon, NO);
}

// The clip for the add-on, or none: copied over the last one, then announced, all for the walk it belongs to.
static void offer(NSURL *file, NSUInteger walk) {
    if (!file) {
        notify_post(kSGRelayLockClipNone);
        return;
    }
    dispatch_async(sg_queue, ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *target = clipFile();
        NSURL *staging = [target URLByAppendingPathExtension:@"part"];
        [files removeItemAtURL:staging error:nil];
        NSError *error = nil;
        BOOL copied = [files copyItemAtURL:file toURL:staging error:&error];
        if (copied) {
            [files removeItemAtURL:target error:nil];
            copied = [files moveItemAtURL:staging toURL:target error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (walk != sg_walk) return;
            if (!copied) {
                SGLog(@"lock clip: %@ not copied for the add-on: %@", file.lastPathComponent, error.localizedDescription);
                notify_post(kSGRelayLockClipNone);
                return;
            }
            notify_post(kSGRelayLockClip);
            static int logged;
            if (logged++ < 4) SGLog(@"lock clip: %@ handed to the add-on", file.lastPathComponent);
        });
    });
}

%ctor {
    if (@available(iOS 26.0, *)) return;
    // Only a jailbroken phone can have the add-on that draws it.
    if (!SGJailbroken()) return;
    sg_queue = dispatch_queue_create("spotifyglass.lockscreen.addon-clip", DISPATCH_QUEUE_SERIAL);
    sg_follower = [[SGMotionFollower alloc] initWithBegin:^BOOL(NSString *uri, SPTPlayerState *state) {
        sg_walk++;
        // Until the new track's clip is in, the add-on draws its cover rather than the last track's clip.
        if (wanted()) notify_post(kSGRelayLockClipNone);
        return wanted();
    } found:^(NSString *uri, NSURL *file) {
        offer(file, sg_walk);
    }];
    // Heard on the writing thread and handed to main without waiting (AGENTS.md): the switch turned on looks the track up.
    __block BOOL was = wanted();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL now = wanted();
            if (now == was) return;
            was = now;
            if (now) [sg_follower restart];
        });
    }];
}
