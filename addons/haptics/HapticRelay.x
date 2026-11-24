// Vitrine Addon, an add-on package of its own for a jailbroken phone, loaded into SpringBoard: it plays the taps and
// the rumble Spotify's Music Haptics hands it while Spotify is not in front (tweak/Sources/Shared/Haptics/SGHapticRelay.h,
// which names the notifications), since iOS plays haptics for SpringBoard at any time and for an app in the background
// never. Vitrine itself (its IPA or its .deb) does not carry it: it is installed once with a package manager.
//
// Each name is registered once and played the moment it is posted: a tap is a transient of its intensity and
// sharpness, the rumble one looping continuous event whose intensity control follows the level it is posted at, and
// stopped at 0. It answers Spotify's ping with a pong, and posts one as it starts, so Spotify hears it whichever
// came up first.
//
// Threading: the notifications and Core Haptics on one serial queue of its own.
#import <CoreHaptics/CoreHaptics.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

// The rumble's loop, as Spotify's own (MusicHaptics.x: kRumbleLength), restarted by its loop for as long as it plays.
static const NSTimeInterval kRumbleLength = 30;

static dispatch_queue_t sg_queue;
static CHHapticEngine *sg_engine;
static id<CHHapticAdvancedPatternPlayer> sg_rumble;
static BOOL sg_rumbling;
// When the rumble was last asked for, and whether it may play while the phone is locked (Spotify's switch) and is.
static CFTimeInterval sg_rumbleHeardAt;
static BOOL sg_lockScreen = NO, sg_locked;
// Stops a rumble Spotify has stopped speaking for: armed for kSGRelayRumbleLapse on every rumble post, idle otherwise, so
// SpringBoard is woken only while a rumble plays.
static dispatch_source_t sg_lapse;

static BOOL engineUp(void) {
    if (!CHHapticEngine.capabilitiesForHardware.supportsHaptics) return NO;
    NSError *error = nil;
    if (!sg_engine) {
        sg_engine = [[CHHapticEngine alloc] initAndReturnError:&error];
        if (!sg_engine) return NO;
        sg_engine.playsHapticsOnly = YES;
        sg_engine.autoShutdownEnabled = YES;
        sg_engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) {
            dispatch_async(sg_queue, ^{
                sg_rumble = nil;
                sg_rumbling = NO;
            });
        };
        sg_engine.resetHandler = ^{
            dispatch_async(sg_queue, ^{
                sg_rumble = nil;
                sg_rumbling = NO;
                [sg_engine startAndReturnError:nil];
            });
        };
    }
    return [sg_engine startAndReturnError:&error];
}

static CHHapticEventParameter *parameter(CHHapticEventParameterID identifier, float value) {
    return [[CHHapticEventParameter alloc] initWithParameterID:identifier value:value];
}

// Whether a tap or the rumble may play now: not while the phone is locked with the lock screen switch off.
static BOOL plays(void) {
    return sg_lockScreen || !sg_locked;
}

static void tap(float intensity, float sharpness) {
    if (!plays() || !engineUp()) return;
    CHHapticEvent *hit = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticTransient parameters:@[
        parameter(CHHapticEventParameterIDHapticIntensity, intensity),
        parameter(CHHapticEventParameterIDHapticSharpness, sharpness),
    ] relativeTime:0];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[hit] parameters:@[] error:nil];
    id<CHHapticPatternPlayer> player = pattern ? [sg_engine createPlayerWithPattern:pattern error:nil] : nil;
    [player startAtTime:CHHapticTimeImmediate error:nil];
}

static void armLapse(BOOL armed) {
    dispatch_time_t when = armed ? dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSGRelayRumbleLapse * NSEC_PER_SEC)) : DISPATCH_TIME_FOREVER;
    dispatch_source_set_timer(sg_lapse, when, DISPATCH_TIME_FOREVER, (uint64_t)(0.05 * NSEC_PER_SEC));
}

static void rumble(float level) {
    sg_rumbleHeardAt = CACurrentMediaTime();
    if (level <= 0 || !plays()) {
        if (sg_rumbling) [sg_rumble stopAtTime:CHHapticTimeImmediate error:nil];
        sg_rumbling = NO;
        armLapse(NO);
        return;
    }
    armLapse(YES);
    if (!engineUp()) return;
    if (!sg_rumble) {
        CHHapticEvent *hum = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
            parameter(CHHapticEventParameterIDHapticIntensity, 1),
            parameter(CHHapticEventParameterIDHapticSharpness, 0),
        ] relativeTime:0 duration:kRumbleLength];
        CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[hum] parameters:@[] error:nil];
        sg_rumble = pattern ? [sg_engine createAdvancedPlayerWithPattern:pattern error:nil] : nil;
        sg_rumble.loopEnabled = YES;
        if (!sg_rumble) return;
    }
    CHHapticDynamicParameter *control = [[CHHapticDynamicParameter alloc] initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl
                                                                                         value:level relativeTime:0];
    [sg_rumble sendParameters:@[control] atTime:CHHapticTimeImmediate error:nil];
    if (!sg_rumbling) sg_rumbling = [sg_rumble startAtTime:CHHapticTimeImmediate error:nil];
}

static void watchRumble(void) {
    sg_lapse = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_queue);
    dispatch_source_set_timer(sg_lapse, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(sg_lapse, ^{
        if (CACurrentMediaTime() - sg_rumbleHeardAt >= kSGRelayRumbleLapse) rumble(0);
        else armLapse(YES);
    });
    dispatch_resume(sg_lapse);
}

static void listen(const char *name, void (^handler)(void)) {
    int token;
    notify_register_dispatch(name, &token, sg_queue, ^(int t) { handler(); });
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    sg_queue = dispatch_queue_create("com.vitrine.haptics", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    watchRumble();
    for (int level = 1; level <= kSGRelayLevels; level++) {
        for (int sharp = 0; sharp < kSGRelaySharpnesses; sharp++) {
            char name[64];
            snprintf(name, sizeof name, kSGRelayPrefix "tap.%d.%d", level, sharp);
            float intensity = (float)level / kSGRelayLevels, sharpness = (sharp + 0.5f) / kSGRelaySharpnesses;
            listen(name, ^{ tap(intensity, sharpness); });
        }
    }
    for (int level = 0; level <= kSGRelayLevels; level++) {
        char name[64];
        snprintf(name, sizeof name, kSGRelayPrefix "rumble.%d", level);
        float value = (float)level / kSGRelayLevels;
        listen(name, ^{ rumble(value); });
    }
    listen(kSGRelayLockOn, ^{ sg_lockScreen = YES; });
    listen(kSGRelayLockOff, ^{
        sg_lockScreen = NO;
        if (sg_locked) rumble(0);
    });
    // SpringBoard's own lock state, as its notification's state has it (1 locked).
    static int lockToken;
    notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, sg_queue, ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        sg_locked = state != 0;
        if (sg_locked && !sg_lockScreen) rumble(0);
    });
    // As it is now: SpringBoard starts locked after a respring, and nothing is posted until it changes. Read on the queue
    // the handler writes it on.
    dispatch_async(sg_queue, ^{
        uint64_t lockState = 0;
        if (notify_get_state(lockToken, &lockState) == NOTIFY_STATUS_OK) sg_locked = lockState != 0;
    });
    // The pong carries the add-on's build, so Spotify can tell an older one from the copy it carries.
    static int pong;
    notify_register_check(kSGRelayPong, &pong);
    notify_set_state(pong, kSGRelayAddonBuild);
    listen(kSGRelayPing, ^{
        notify_set_state(pong, kSGRelayAddonBuild);
        notify_post(kSGRelayPong);
    });
    notify_post(kSGRelayPong);
}
