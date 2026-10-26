// What the Sing page and the Spatial voice page call outside their own files: Sing.x's and SGSingModel.m's state,
// a model on the phone and Sing off, and Shared/HeadGestures' motion, played from a script of the head's yaw
// at 25 motions a second, as AirPods send them, while the preview listens.
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Shared/Sing/Sing.h"

#pragma mark - Sing

// From main.m's launch line: the state Sing is in, the model's, and whether the song plays.
SGSingState sg_singState = SGSingStateOff;
long long sg_pausedBytes;
BOOL sg_playing;
static float sg_level = 0.15f;

NSString *const SGSingChangedNotification = @"SGSingChangedNotification";
SGSingState SGSingCurrentState(void) { return SGSingOn() || sg_singState <= SGSingStateDownloading ? sg_singState : SGSingStateOff; }
NSString *SGSingStatusText(void) {
    return @[@"Unavailable", @"Needs its voice model", @"Downloading 42%", @"Off", @"Loading the voice model, 12 s", @"Ready", @"Listening ahead", @"On",
             @"Too slow", @"Held, too hot", @"Failed"][SGSingCurrentState()];
}
NSString *SGSingStatusDetail(void) {
    SGSingState state = SGSingCurrentState();
    return state == SGSingStateFailed ? @"The voice model did not load in 120 s, so that load was given up. Switch Sing off and on again to try again."
         : state == SGSingStateSinging ? @"Karaoke runs on the Neural Engine." : nil;
}
NSString *SGSingMissing(void) { return nil; }
BOOL SGSingOn(void) { return SGHidden(SGKeySing); }
void SGSetSingOn(BOOL on) { SGSetEnabled(SGKeySing, on); }
float SGSingLevel(void) { return sg_level; }
void SGSetSingLevel(float level) {
    sg_level = level;
    NSLog(@"[harness] level %.2f", level);
}
void SGSetSingIgnoresHeat(BOOL ignores) {}
BOOL SGSingSpatialAvailable(void) { return YES; }
BOOL SGSingSpatial(void) { return SGHidden(SGKeySingSpatial); }
void SGSetSingSpatial(BOOL on) {
    SGSetEnabled(SGKeySingSpatial, on);
    NSLog(@"[harness] spatial voice %@", on ? @"on" : @"off");
}
// Sing.x's stored sound, with its defaults and ranges; no engine to hand it to.
static double storedNumber(NSString *key, double fallback, double low, double high) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    double number = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : fallback;
    return isfinite(number) ? fmin(high, fmax(low, number)) : fallback;
}
double SGSingSpatialDistance(void) { return storedNumber(SGKeySingSpatialDistance, 1.5, 1, 6.5); }
double SGSingSpatialRoom(void) { return storedNumber(SGKeySingSpatialRoom, 25, 0, 100); }
double SGSingSpatialFront(void) { return storedNumber(SGKeySingSpatialFront, 5, 5, 60); }
double SGSingSpatialWidth(void) { return storedNumber(SGKeySingSpatialWidth, 110, 0, 200); }
void SGSetSingSpatialSound(double meters, double roomPercent, double frontSeconds, double widthPercent) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setDouble:meters forKey:SGKeySingSpatialDistance];
    [defaults setDouble:roomPercent forKey:SGKeySingSpatialRoom];
    [defaults setDouble:frontSeconds forKey:SGKeySingSpatialFront];
    [defaults setDouble:widthPercent forKey:SGKeySingSpatialWidth];
    NSLog(@"[harness] spatial sound %.1f m, room %.0f%%, front %.0f s, width %.0f%%", meters, roomPercent, frontSeconds, widthPercent);
}
// From main.m's launch line (chunk=<ms>): what plays moves on in renders this long, as the engine's clock does, a
// part of a tenth out of step with the wall clock; 0 for a clock that moves smoothly.
double sg_renderChunk;
// The newest tenth the last read handed out, for main.m's `lines`.
long sg_newestTenth;
// A made-up song: a voice that comes in phrases over a steadier band, a tenth of a second at a time.
BOOL SGSingReadLevels(float *vocals, float *rest, int count) {
    if (SGSingCurrentState() != SGSingStateSinging) return NO;
    double played = CACurrentMediaTime() + (sg_renderChunk > 0 ? 0.037 : 0);
    if (sg_renderChunk > 0) played = floor(played / sg_renderChunk) * sg_renderChunk;
    long now = (long)(played * 10);
    sg_newestTenth = now;
    float level = sg_level, vocalsGain = fminf(level, 1), restGain = level <= 1 ? 1 : 2 - level;
    for (int k = 0; k < count; k++) {
        double t = (now - count + 1 + k) / 10.0;
        double phrase = fmax(0, sin(t * 0.9)) * (0.7 + 0.3 * sin(t * 7.3));
        vocals[k] = (float)(0.2 * phrase + 0.004) * vocalsGain;
        rest[k] = (float)(0.07 * (1 + 0.35 * sin(t * 2.1) + 0.2 * fabs(sin(t * 12.6)))) * restGain;
    }
    return YES;
}
void SGSingComputeUnitsChanged(void) {}
SGSingModelState SGSingModelCurrentState(void) {
    return sg_singState == SGSingStateDownloading ? SGSingModelDownloading : sg_singState == SGSingStateNoModel ? SGSingModelMissing : SGSingModelReady;
}
double SGSingModelProgress(void) { return 0.42; }
BOOL SGSingModelWaitingForNetwork(void) { return NO; }
BOOL SGSingModelChecking(void) { return NO; }
BOOL SGSingModelOverCellular(void) { return NO; }
void SGSingDownloadModelOverCellular(void) {}
long long SGSingModelPausedBytes(void) { return SGSingModelCurrentState() == SGSingModelMissing ? sg_pausedBytes : 0; }
NSString *SGSingModelError(void) { return nil; }
NSString *SGSingModelSizeText(void) { return @"210.4 MB"; }
// `-update 1` on the launch line: the old model in place, its update not downloaded.
BOOL SGSingModelUpdateAvailable(void) { return SGSingModelCurrentState() == SGSingModelReady && [NSUserDefaults.standardUserDefaults boolForKey:@"update"]; }
BOOL SGSingModelUpdateDownloading(void) { return NO; }
NSString *SGSingModelInUseSizeText(void) { return SGSingModelUpdateAvailable() ? @"489.7 MB" : @"210.4 MB"; }
void SGSingDownloadModel(void) {}
void SGSingCancelModelDownload(void) {}
void SGSingDeleteModel(void) {}
SGSingModelKind SGSingChosenModel(void) { return [NSUserDefaults.standardUserDefaults integerForKey:SGKeySingModel] == 1 ? SGSingModelLight : SGSingModelFull; }
void SGSetSingChosenModel(SGSingModelKind kind) { [NSUserDefaults.standardUserDefaults setInteger:kind forKey:SGKeySingModel]; }
NSString *SGSingModelSizeTextOf(SGSingModelKind kind) { return kind == SGSingModelLight ? @"30.8 MB" : @"210.4 MB"; }
long long SGSingOtherModelBytes(void) { return 0; }
void SGSingDeleteOtherModel(void) {}
NSArray<NSString *> *SGSingComputeUnitNames(void) { return @[@"Automatic", @"CPU only"]; }
BOOL SGSingOSSupported(void) { return YES; }
BOOL SGSingDeviceSupported(void) { return YES; }

#pragma mark - the player

@interface FakeTrack : NSObject
@property (nonatomic, copy) NSString *trackTitle, *artistName;
@property (nonatomic, strong) id URI;
@end
@implementation FakeTrack
@end

// From main.m's launch line (title=<text>): the playing track's title; and (none) no track at all, as before
// anything has played this launch.
NSString *sg_trackTitle = @"Northern Lights";
BOOL sg_noTrack;

NSString *SGURIString(id uri) { return [uri isKindOfClass:NSString.class] ? uri : nil; }
void SGAddPlayerStateObserver(id observer) {}
NSString *SGLocalFileCoverInURL(NSString *url) { return nil; }
NSURL *SGMotionCanvasIn(NSDictionary *metadata) { return nil; }

@interface FakePlayerState : NSObject
@property (nonatomic, strong) FakeTrack *track;
@property (nonatomic) BOOL isPaused;
@end
@implementation FakePlayerState
@end

@interface FakePlayer : NSObject
@end
@implementation FakePlayer
- (id)pause:(id)options {
    sg_playing = NO;
    NSLog(@"[harness] pause");
    return nil;
}
- (id)resume:(id)options {
    sg_playing = YES;
    NSLog(@"[harness] resume");
    return nil;
}
@end

id SGPlayerState(void) {
    static FakePlayerState *state;
    if (sg_noTrack) return nil;
    if (!state) {
        state = [FakePlayerState new];
        state.track = [FakeTrack new];
        state.track.trackTitle = sg_trackTitle;
        state.track.artistName = @"The Paper Kites";
        state.track.URI = @"spotify:track:harness";
    }
    state.isPaused = !sg_playing;
    return state;
}

id SGKaraokePlayer(void) {
    static FakePlayer *player;
    if (!player) player = [FakePlayer new];
    return player;
}

#pragma mark - the head

@interface FakeAttitude : NSObject
@property (nonatomic) double yaw;
@end
@implementation FakeAttitude
@end

@interface FakeMotion : NSObject
@property (nonatomic) NSTimeInterval timestamp;
@property (nonatomic, strong) FakeAttitude *attitude;
@end
@implementation FakeMotion
@end

// From main.m's launch line: what Motion & Fitness answers, and the head's yaw at a time since launch (NAN: no
// headphones, so no motion).
CMAuthorizationStatus sg_motionAllowed = CMAuthorizationStatusNotDetermined;
double (^sg_headYaw)(double seconds);

static CMAuthorizationStatus fakeAuthorization(id self, SEL _cmd) { return sg_motionAllowed; }

__attribute__((constructor)) static void sg_takeOverPermission(void) {
    method_setImplementation(class_getClassMethod(CMHeadphoneMotionManager.class, @selector(authorizationStatus)), (IMP)fakeAuthorization);
}

static NSMutableDictionary<NSString *, void (^)(CMDeviceMotion *)> *sg_listeners;
static dispatch_queue_t sg_queue;
static dispatch_source_t sg_timer;
// When the head's script started, and the yaw in the last motion sent, for main.m's `lag`.
CFTimeInterval sg_headStarted;
double sg_sentYaw;

void SGHeadMotionListen(NSString *name, void (^handler)(CMDeviceMotion *motion)) {
    if (!sg_listeners) {
        sg_listeners = [NSMutableDictionary dictionary];
        sg_queue = dispatch_queue_create("harness.motion", DISPATCH_QUEUE_SERIAL);
    }
    void (^old)(CMDeviceMotion *) = sg_listeners[name];
    sg_listeners[name] = [handler copy];
    NSLog(@"[harness] %@ %@ the head", name, handler ? @"listens to" : @"stops listening to");
    if (old && !handler) dispatch_async(sg_queue, ^{ old(nil); });
    NSArray *handlers = sg_listeners.allValues;
    if (handlers.count && !sg_timer && sg_headYaw) {
        if (!sg_headStarted) sg_headStarted = CACurrentMediaTime();
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, sg_queue);
        dispatch_source_set_timer(sg_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 25, 0);
        dispatch_source_set_event_handler(sg_timer, ^{
            double now = CACurrentMediaTime() - sg_headStarted, yaw = sg_headYaw(now);
            if (isnan(yaw)) return;
            sg_sentYaw = yaw;
            FakeMotion *motion = [FakeMotion new];
            motion.timestamp = CACurrentMediaTime();
            motion.attitude = [FakeAttitude new];
            motion.attitude.yaw = yaw;
            for (void (^each)(CMDeviceMotion *) in handlers) each((CMDeviceMotion *)motion);
        });
        dispatch_resume(sg_timer);
    } else if (!handlers.count && sg_timer) {
        dispatch_source_cancel(sg_timer);
        sg_timer = nil;
    }
}

void SGHeadMotionAskPermission(void) {
    NSLog(@"[harness] Motion & Fitness asked for");
}
