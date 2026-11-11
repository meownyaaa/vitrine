#import "MRGPlayer.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <os/lock.h>
#import "MRGRebind.h"

NSString *const MRGPlayerTrackChangedNotification = @"MiragePlayerTrackChanged";

@interface SPTPlayerTrack : NSObject
@property (nonatomic, readonly) id URI;
@property (nonatomic, readonly) NSString *artistName;
@property (nonatomic, readonly) NSString *trackTitle;
@property (nonatomic, readonly) NSDictionary *metadata;
@property (nonatomic, readonly, copy) NSString *provider;
+ (id)trackWithURI:(id)uri;
@end
@interface SPTPlayerState : NSObject
@property (nonatomic, readonly) SPTPlayerTrack *track;
@property (nonatomic, readonly) NSArray *future;
@property (nonatomic, readonly) NSArray *reverse;
@end
@interface NSObject (MRGPlayerObserving)
- (void)addPlayerObserver:(id)observer;
@end
@interface SPTPlayerContext : NSObject
+ (id)contextWithTracks:(id)tracks;
+ (id)contextForURI:(id)uri;
@end
@interface SPTPlayOptions : NSObject
@end
@interface SPTPlayOrigin : NSObject
- (id)initWithFeatureIdentifier:(id)f featureVersion:(id)v viewURI:(id)u externalReferrer:(id)r;
@end
@interface SPTask : NSObject
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue;
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue;
@end
@interface SPTPlayerQueueWrapperImpl : NSObject
- (instancetype)initWithPlayer:(id)player;
- (id)queueMultipleTracks:(NSArray *)tracks loggingParams:(id)params;
@end

static __weak id sg_player;
static NSString *sg_lastURI;
static NSDictionary<NSString *, NSString *> *sg_headers;

static NSString *uriString(id uri) {
    if ([uri isKindOfClass:NSString.class]) return uri;
    if ([uri isKindOfClass:NSURL.class]) return ((NSURL *)uri).absoluteString;
    return nil;
}

static NSDictionary *infoOf(id track) {
    if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) return nil;
    SPTPlayerTrack *t = track;
    NSString *uri = uriString(t.URI);
    NSString *title = [t respondsToSelector:@selector(trackTitle)] ? t.trackTitle : nil;
    NSString *artist = [t respondsToSelector:@selector(artistName)] ? t.artistName : nil;
    NSDictionary *meta = [t respondsToSelector:@selector(metadata)] ? t.metadata : nil;
    if (!title.length && [meta[@"title"] isKindOfClass:NSString.class]) title = meta[@"title"];
    if (!artist.length && [meta[@"artist_name"] isKindOfClass:NSString.class]) artist = meta[@"artist_name"];
    if (!uri) return nil;
    NSMutableDictionary *d = [@{@"uri": uri} mutableCopy];
    if (title.length) d[@"title"] = title;
    if (artist.length) d[@"artist"] = artist;
    NSString *provider = [t respondsToSelector:@selector(provider)] ? t.provider : nil;
    BOOL ad = [uri hasPrefix:@"spotify:ad:"] || [provider isEqualToString:@"ad"] || [meta[@"is_advertisement"] isEqual:@"true"];
    d[@"ad"] = @(ad);
    return d;
}

static SPTPlayerState *currentState(void) {
    id p = sg_player;
    id s = [p respondsToSelector:@selector(state)] ? [p performSelector:@selector(state)] : nil;
    return [s isKindOfClass:objc_getClass("SPTPlayerState")] ? s : nil;
}

id MRGPlayerInstance(void) { return sg_player; }

NSDictionary *MRGNowPlaying(void) {
    NSDictionary *d = infoOf(currentState().track);
    return d[@"title"] ? d : nil;
}

BOOL MRGPlayerIsAd(void) { return [infoOf(currentState().track)[@"ad"] boolValue]; }

NSArray<NSDictionary *> *MRGRecentHistory(void) {
    return [NSUserDefaults.standardUserDefaults arrayForKey:@"mirage.dj.history"] ?: @[];
}

NSArray<NSDictionary *> *MRGQueueAround(void) {
    SPTPlayerState *s = currentState();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in @[@"reverse", @"future"]) {
        id list = [s respondsToSelector:NSSelectorFromString(key)] ? [s valueForKey:key] : nil;
        NSUInteger n = 0;
        for (id t in [list isKindOfClass:NSArray.class] ? list : nil) {
            NSDictionary *d = infoOf(t);
            if (d[@"title"] && ![d[@"ad"] boolValue]) [out addObject:@{@"title": d[@"title"], @"artist": d[@"artist"] ?: @""}];
            if (++n >= 10) break;
        }
    }
    return out;
}

static void logPlayed(NSDictionary *d) {
    if (!d[@"title"] || [d[@"ad"] boolValue]) return;
    NSMutableArray *h = [MRGRecentHistory() mutableCopy];
    NSDictionary *entry = @{@"title": d[@"title"], @"artist": d[@"artist"] ?: @""};
    [h removeObject:entry];
    [h insertObject:entry atIndex:0];
    while (h.count > 40) [h removeLastObject];
    [NSUserDefaults.standardUserDefaults setObject:h forKey:@"mirage.dj.history"];
}

static void stateChanged(id state) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    NSDictionary *d = infoOf(((SPTPlayerState *)state).track);
    NSString *uri = d[@"uri"];
    if (!uri || [uri isEqualToString:sg_lastURI]) return;
    sg_lastURI = uri;
    logPlayed(d);
    [NSNotificationCenter.defaultCenter postNotificationName:MRGPlayerTrackChangedNotification object:nil userInfo:d];
}

@interface MRGPlayerObserver : NSObject
@end
@implementation MRGPlayerObserver
- (void)player:(id)player stateDidChange:(id)state {
    if (NSThread.isMainThread) stateChanged(state);
    else dispatch_async(dispatch_get_main_queue(), ^{ stateChanged(state); });
}
- (void)player:(id)player stateDidChange:(id)state fromState:(id)old { [self player:player stateDidChange:state]; }
@end
static MRGPlayerObserver *sg_observer;

%group MRGPlayerHooks
%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    if ([observer isKindOfClass:MRGPlayerObserver.class]) return;
    id player = self;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_player = player;
            sg_observer = [MRGPlayerObserver new];
            [player addPlayerObserver:sg_observer];
            stateChanged(currentState());
        });
    });
}
%end
%end

#pragma mark - spclient headers

static NSString *const kHeaders[] = {@"authorization", @"client-token", @"app-platform", @"spotify-app-version", @"user-agent", @"accept-language"};

static void rememberHeaders(NSURLSession *session, NSURLRequest *request) {
    if (sg_headers || ![request.URL.host containsString:@"spclient"]) return;
    NSMutableDictionary *all = [NSMutableDictionary dictionary];
    [session.configuration.HTTPAdditionalHeaders enumerateKeysAndObjectsUsingBlock:^(id k, id v, BOOL *stop) {
        if ([k isKindOfClass:NSString.class] && [v isKindOfClass:NSString.class]) all[[k lowercaseString]] = v;
    }];
    [request.allHTTPHeaderFields enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { all[k.lowercaseString] = v; }];
    if (![all[@"authorization"] hasPrefix:@"Bearer "]) return;
    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < sizeof(kHeaders) / sizeof(*kHeaders); i++) if (all[kHeaders[i]]) h[kHeaders[i]] = all[kHeaders[i]];
    dispatch_async(dispatch_get_main_queue(), ^{ sg_headers = h; });
}

// The token expires (about an hour): the next request Spotify makes refreshes the copy.
static void refreshHeaders(NSURLSession *session, NSURLRequest *request) {
    if (![request.URL.host containsString:@"spclient"]) return;
    NSString *auth = request.allHTTPHeaderFields[@"authorization"] ?: request.allHTTPHeaderFields[@"Authorization"];
    if (auth && sg_headers && ![auth isEqualToString:sg_headers[@"authorization"]]) {
        dispatch_async(dispatch_get_main_queue(), ^{ sg_headers = nil; rememberHeaders(session, request); });
        return;
    }
    rememberHeaders(session, request);
}

%group MRGHeadersDataLoader
%hook SPTDataLoaderService
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    refreshHeaders(session, task.currentRequest);
    %orig;
}
%end
%end

%group MRGHeadersHttpClient
%hook _TtC26Connectivity_HttpClientKit20HttpClientURLSession
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    refreshHeaders(session, task.currentRequest);
    %orig;
}
%end
%end

NSDictionary<NSString *, NSString *> *MRGSpotifyHeaders(void) { return sg_headers; }

#pragma mark - playing

static void watchTask(id task, void (^done)(BOOL ok, NSString *error)) {
    if (![task respondsToSelector:@selector(addCallback:on:)] || ![task respondsToSelector:@selector(addErrorCallback:on:)]) {
        done(task != nil, task ? nil : @"Spotify's player didn't take the request.");
        return;
    }
    __block BOOL called = NO;
    [task addCallback:^(id result) {
        if (called) return; called = YES;
        done(YES, nil);
    } on:dispatch_get_main_queue()];
    [task addErrorCallback:^(NSError *error) {
        if (called) return; called = YES;
        done(NO, error.localizedDescription ?: @"Spotify's player refused it.");
    } on:dispatch_get_main_queue()];
}

static id playOrigin(void) {
    Class c = objc_getClass("SPTPlayOrigin");
    if (![c instancesRespondToSelector:@selector(initWithFeatureIdentifier:featureVersion:viewURI:externalReferrer:)]) return nil;
    return [[c alloc] initWithFeatureIdentifier:@"mirage_dj" featureVersion:@MRG_VERSION viewURI:nil externalReferrer:nil];
}

static id playContext(id context) {
    id player = sg_player;
    id options = [objc_getClass("SPTPlayOptions") new];
    id origin = playOrigin();
    SEL withOrigin = @selector(playContext:options:origin:);
    if (origin && [player respondsToSelector:withOrigin])
        return ((id (*)(id, SEL, id, id, id))objc_msgSend)(player, withOrigin, context, options, origin);
    if ([player respondsToSelector:@selector(playContext:options:)])
        return ((id (*)(id, SEL, id, id))objc_msgSend)(player, @selector(playContext:options:), context, options);
    return nil;
}

static NSArray *playerTracks(NSArray<NSString *> *uris) {
    Class trackClass = objc_getClass("SPTPlayerTrack");
    if (![trackClass respondsToSelector:@selector(trackWithURI:)]) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSString *u in uris) {
        id t = [trackClass trackWithURI:[NSURL URLWithString:u]];
        if (t) [tracks addObject:t];
    }
    return tracks;
}

static void queueAndSkip(NSArray<NSString *> *uris, void (^done)(BOOL, NSString *, NSString *)) {
    id player = sg_player;
    Class wrapper = objc_getClass("SPTPlayerQueueWrapperImpl");
    NSArray *tracks = playerTracks(uris);
    if (!player || !tracks.count || ![wrapper instancesRespondToSelector:@selector(initWithPlayer:)] ||
        ![wrapper instancesRespondToSelector:@selector(queueMultipleTracks:loggingParams:)]) {
        done(NO, nil, @"Spotify's queue isn't reachable.");
        return;
    }
    SPTPlayerQueueWrapperImpl *queue = [[wrapper alloc] initWithPlayer:player];
    id task = [queue queueMultipleTracks:tracks loggingParams:nil];
    watchTask(task, ^(BOOL ok, NSString *error) {
        (void)queue;
        if (!ok) { done(NO, nil, error); return; }
        if ([player respondsToSelector:@selector(skipToNextTrack)]) [player performSelector:@selector(skipToNextTrack)];
        done(YES, @"queue", nil);
    });
}

void MRGPlayURIs(NSArray<NSString *> *uris, void (^done)(BOOL, NSString *, NSString *)) {
    if (!sg_player) { done(NO, nil, @"Play something in Spotify once, then try again."); return; }
    Class contextClass = objc_getClass("SPTPlayerContext");
    NSArray *tracks = playerTracks(uris);
    id context = tracks.count && [contextClass respondsToSelector:@selector(contextWithTracks:)] ? [contextClass contextWithTracks:tracks] : nil;
    id task = context ? playContext(context) : nil;
    if (!task) { queueAndSkip(uris, done); return; }
    watchTask(task, ^(BOOL ok, NSString *error) {
        if (ok) done(YES, @"context", nil);
        else queueAndSkip(uris, done);
    });
}

void MRGPlayContextURI(NSString *uri, void (^done)(BOOL, NSString *)) {
    Class contextClass = objc_getClass("SPTPlayerContext");
    id context = [contextClass respondsToSelector:@selector(contextForURI:)] ? [contextClass contextForURI:[NSURL URLWithString:uri]] : nil;
    id task = context && sg_player ? playContext(context) : nil;
    if (!task) { done(NO, @"Spotify's player didn't take the playlist."); return; }
    watchTask(task, done);
}

#pragma mark - ducking

// Spotify plays through Core Audio units of its own (a RemoteIO output unit started with AudioOutputUnitStart,
// no Objective-C method in between; Vitrine's Shared/Haptics/MusicHaptics.x describes the chain). Spotify's
// import of AudioOutputUnitStart is rebound (MRGRebind.h, as Vitrine's Shared/Player/SpeedPitch.x does; the two
// chain), and every output unit Spotify starts gets a render notify that, after each render, scales the buffer
// bound for the speaker by the duck gain. The gain eases toward its target over ~80 ms per buffer so nothing
// clicks; at 1 the notify returns at once. The DJ's own voice (AVSpeechSynthesizer, AVAudioPlayer) does not
// pass these units, so it stays at full level over the lowered music. Spotify's audio session is never touched.
static _Atomic float sg_duckTarget = 1.0f;
static float sg_duckGain = 1.0f;   // render thread only
static OSStatus (*sg_realStart)(AudioUnit unit);
static BOOL sg_duckReady;

typedef struct { UInt32 flags, channels, bytes; BOOL ok; } MRGFormat;

static MRGFormat formatOf(AudioUnit unit) {
    AudioStreamBasicDescription f = {0};
    UInt32 size = sizeof f;
    MRGFormat out = {0};
    if (AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &f, &size) != noErr) return out;
    out.flags = f.mFormatFlags;
    out.channels = f.mChannelsPerFrame;
    out.bytes = f.mBitsPerChannel / 8;
    out.ok = f.mFormatID == kAudioFormatLinearPCM && out.channels >= 1 &&
             (((f.mFormatFlags & kAudioFormatFlagIsFloat) && out.bytes == 4) || ((f.mFormatFlags & kAudioFormatFlagIsSignedInteger) && out.bytes == 2));
    return out;
}

static OSStatus rendered(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time, UInt32 bus,
                         UInt32 frames, AudioBufferList *data) {
    if (!(*flags & kAudioUnitRenderAction_PostRender) || bus != 0 || !data) return noErr;
    float target = atomic_load_explicit(&sg_duckTarget, memory_order_relaxed);
    float start = sg_duckGain;
    if (target >= 0.999f && start >= 0.999f) return noErr;
    MRGFormat *f = (MRGFormat *)ref;
    if (!f || !f->ok) return noErr;
    // From the gain the last buffer ended on, a fifth of the way to the target per buffer (about 80 ms at 512 frames, 48 kHz).
    float end = start + (target - start) * 0.2f;
    if (fabsf(end - target) < 0.002f) end = target;
    BOOL isFloat = (f->flags & kAudioFormatFlagIsFloat) != 0;
    for (UInt32 b = 0; b < data->mNumberBuffers; b++) {
        AudioBuffer *buf = &data->mBuffers[b];
        if (!buf->mData) continue;
        UInt32 samples = buf->mDataByteSize / f->bytes;
        UInt32 perFrame = buf->mNumberChannels ?: 1;
        UInt32 n = samples / perFrame;
        if (!n) continue;
        float step = (end - start) / (float)n;
        if (isFloat) {
            float *s = buf->mData;
            for (UInt32 i = 0; i < n; i++) { float g = start + step * i; for (UInt32 c = 0; c < perFrame; c++) s[i * perFrame + c] *= g; }
        } else {
            SInt16 *s = buf->mData;
            for (UInt32 i = 0; i < n; i++) { float g = start + step * i; for (UInt32 c = 0; c < perFrame; c++) s[i * perFrame + c] = (SInt16)(s[i * perFrame + c] * g); }
        }
    }
    sg_duckGain = end;
    return noErr;
}

// One notify per unit, with the unit's output format read each time it is started (Spotify starts it again
// after each pause and after a route change, which can change the format). A few units per run at most.
#define MRG_MAX_UNITS 16
static struct { AudioUnit unit; MRGFormat *format; } sg_units[MRG_MAX_UNITS];
static os_unfair_lock sg_unitsLock = OS_UNFAIR_LOCK_INIT;

static OSStatus startOutput(AudioUnit unit) {
    if (unit) {
        os_unfair_lock_lock(&sg_unitsLock);
        MRGFormat *f = NULL;
        int free_ = -1;
        for (int i = 0; i < MRG_MAX_UNITS; i++) {
            if (sg_units[i].unit == unit) { f = sg_units[i].format; break; }
            if (!sg_units[i].unit && free_ < 0) free_ = i;
        }
        BOOL added = NO;
        if (!f && free_ >= 0) {
            f = calloc(1, sizeof *f);   // kept for the run: the notify may still read it
            sg_units[free_].unit = unit;
            sg_units[free_].format = f;
            added = YES;
        }
        if (f) *f = formatOf(unit);
        os_unfair_lock_unlock(&sg_unitsLock);
        if (added) AudioUnitAddRenderNotify(unit, rendered, f);
    }
    return sg_realStart ? sg_realStart(unit) : AudioOutputUnitStart(unit);
}

// A disposed unit's slot is let go, so a new unit at the same address gets its own notify.
static OSStatus (*sg_realDispose)(AudioComponentInstance instance);
static OSStatus disposeUnit(AudioComponentInstance instance) {
    os_unfair_lock_lock(&sg_unitsLock);
    for (int i = 0; i < MRG_MAX_UNITS; i++) if (sg_units[i].unit == instance) { sg_units[i].unit = NULL; sg_units[i].format = NULL; }
    os_unfair_lock_unlock(&sg_unitsLock);
    return sg_realDispose ? sg_realDispose(instance) : AudioComponentInstanceDispose(instance);
}

BOOL MRGDuckMusic(BOOL duck) {
    atomic_store(&sg_duckTarget, duck ? 0.3f : 1.0f);
    return sg_duckReady;
}

%ctor {
    @autoreleasepool {
        if (objc_getClass("SPTEsperantoPlayer")) %init(MRGPlayerHooks);
        if (objc_getClass("SPTDataLoaderService")) %init(MRGHeadersDataLoader);
        if (objc_getClass("_TtC26Connectivity_HttpClientKit20HttpClientURLSession")) %init(MRGHeadersHttpClient);
        sg_duckReady = MRGRebindImport("AudioOutputUnitStart", (void *)startOutput, (void **)&sg_realStart) && sg_realStart;
        if (sg_duckReady) MRGRebindImport("AudioComponentInstanceDispose", (void *)disposeUnit, (void **)&sg_realDispose);
    }
}
