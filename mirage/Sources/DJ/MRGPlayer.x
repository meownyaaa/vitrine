#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import <UIKit/UIKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <stdatomic.h>
#import <os/lock.h>
#import "MRGRebind.h"
#import "MRGDJLog.h"

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
@property (nonatomic, readonly) NSURL *contextURI;
@property (nonatomic, readonly, getter=isPlaying) BOOL playing;   // the selectors are isPlaying / isPaused:
@property (nonatomic, readonly, getter=isPaused) BOOL paused;     // there is no -paused (the 0.2.2 crash)
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
@property (copy, nonatomic) id skipTo;
@end
@interface SPTSkipToTrack : NSObject
- (id)initWithTrackURI:(id)uri;
@end
@interface NSObject (MRGEsperanto)
@property (readonly, copy, nonatomic) NSString *featureIdentifier;
- (id)playOriginWithViewURIOverride:(id)uri externalReferrer:(id)referrer;
- (id)playContext:(id)context options:(id)options origin:(id)origin;
- (id)playContext:(id)context options:(id)options;
- (void)navigateToURI:(id)uri options:(long long)options reason:(id)reason completionHandler:(id)completion resultHandler:(id)result;
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

// Every message to a Spotify object goes through these: a selector the object doesn't answer (a renamed method in
// another Spotify version) is logged once and answered with nil / NO instead of crashing. The selectors are the ones
// the 9.1.90 class dump lists (SPTPlayerState: track, contextURI, isPlaying, isPaused, future, reverse; SPTPlayerTrack:
// URI, trackTitle, artistName, metadata, provider; SPTEsperantoPlayer: state, featureIdentifier).
static void missing(id obj, NSString *sel) {
    static NSMutableSet *said;
    if (!said) said = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%@ %@", NSStringFromClass([obj class]), sel];
    if ([said containsObject:key]) return;
    [said addObject:key];
    MRGDJLog(@"selector missing: -[%@]", key);
}

static id sget(id obj, NSString *name) {
    if (!obj) return nil;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) { missing(obj, name); return nil; }
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static BOOL sflag(id obj, NSString *name) {
    if (!obj) return NO;
    SEL sel = NSSelectorFromString(name);
    if (![obj respondsToSelector:sel]) { missing(obj, name); return NO; }
    return ((BOOL (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id stateTrack(id s) { return sget(s, @"track"); }
static NSString *stateContext(id s);
static BOOL statePaused(id s) { return sflag(s, @"isPaused"); }
static BOOL statePlaying(id s) { return sflag(s, @"isPlaying"); }

static NSDictionary *infoOf(id track) {
    if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) return nil;
    id t = track;
    NSString *uri = uriString(sget(t, @"URI"));
    NSString *title = sget(t, @"trackTitle");
    NSString *artist = sget(t, @"artistName");
    NSDictionary *meta = sget(t, @"metadata");
    if (![title isKindOfClass:NSString.class]) title = nil;
    if (![artist isKindOfClass:NSString.class]) artist = nil;
    if (![meta isKindOfClass:NSDictionary.class]) meta = nil;
    if (!title.length && [meta[@"title"] isKindOfClass:NSString.class]) title = meta[@"title"];
    if (!artist.length && [meta[@"artist_name"] isKindOfClass:NSString.class]) artist = meta[@"artist_name"];
    if (!uri) return nil;
    NSMutableDictionary *d = [@{@"uri": uri} mutableCopy];
    if (title.length) d[@"title"] = title;
    if (artist.length) d[@"artist"] = artist;
    for (NSString *k in @[@"image_url", @"image_large_url", @"image_small_url", @"image_xlarge_url"]) {
        NSString *image = MRGImageURL(meta[k]);
        if (image) { d[@"image"] = image; break; }
    }
    NSString *provider = sget(t, @"provider");
    if (![provider isKindOfClass:NSString.class]) provider = nil;
    BOOL ad = [uri hasPrefix:@"spotify:ad:"] || [provider isEqualToString:@"ad"] || [meta[@"is_advertisement"] isEqual:@"true"];
    d[@"ad"] = @(ad);
    return d;
}

static NSHashTable *sg_players;      // every SPTEsperantoPlayer seen (Spotify makes one per feature)
static SPTPlayerState *sg_lastState;  // the newest state any of them emitted

static SPTPlayerState *stateOf(id p) {
    id s = sget(p, @"state");
    return [s isKindOfClass:objc_getClass("SPTPlayerState")] ? s : nil;
}

static NSString *stateContext(id s) { return uriString(sget(s, @"contextURI")); }

// The state with a track in it: the captured player's, another player's, or the last one emitted. At launch the player
// restored from the last session has a track before any observer is told of it.
static SPTPlayerState *currentState(void) {
    SPTPlayerState *s = stateOf(sg_player);
    if (stateTrack(s)) return s;
    for (id p in sg_players.allObjects) { SPTPlayerState *o = stateOf(p); if (stateTrack(o)) return o; }
    return sg_lastState ?: s;
}

id MRGPlayerInstance(void) { return sg_player; }

NSDictionary *MRGNowPlaying(void) {
    NSDictionary *d = infoOf(stateTrack(currentState()));
    return d[@"title"] ? d : nil;
}

BOOL MRGPlayerIsAd(void) { return [infoOf(stateTrack(currentState()))[@"ad"] boolValue]; }

NSArray<NSDictionary *> *MRGRecentHistory(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (id d in [NSUserDefaults.standardUserDefaults arrayForKey:@"mirage.dj.history"]) if ([d isKindOfClass:NSDictionary.class]) [a addObject:d];
    return a;
}

NSArray<NSDictionary *> *MRGQueueAround(void) {
    SPTPlayerState *s = currentState();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *key in @[@"reverse", @"future"]) {
        id list = sget(s, key);
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

// SPTPlayerState's duration (a double property), in seconds; the player keeps it in milliseconds.
static double stateDuration(id st) {
    if (![st respondsToSelector:@selector(duration)]) { missing(st, @"duration"); return 0; }
    double v = ((double (*)(id, SEL))objc_msgSend)(st, @selector(duration));
    return v > 3600 ? v / 1000.0 : v;
}

static void stateChanged(id state) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    NSMutableDictionary *d = [infoOf(stateTrack(state)) mutableCopy];
    NSString *uri = d[@"uri"];
    if (!uri || [uri isEqualToString:sg_lastURI]) return;
    sg_lastURI = uri;
    logPlayed(d);
    double duration = stateDuration(state);
    if (duration > 0) d[@"duration"] = @(duration);
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

// Spotify makes an SPTEsperantoPlayer per feature (its own DJ has com.spotify.service.endless.djmusic and
// aidjinteractivity_…). They are collected quietly and summed up once in the log.
static NSString *featureOf(id player) {
    id f = sget(player, @"featureIdentifier");
    return [f isKindOfClass:NSString.class] ? f : @"";
}

static void logPlayersSoon(void) {
    static BOOL scheduled;
    if (scheduled) return;
    scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        scheduled = NO;
        NSMutableOrderedSet *features = [NSMutableOrderedSet orderedSet];
        for (id p in sg_players.allObjects) [features addObject:featureOf(p).length ? featureOf(p) : @"(none)"];
        MRGDJLog(@"players: %lu SPTEsperantoPlayer, features: %@", (unsigned long)sg_players.count, [features.array componentsJoinedByString:@", "]);
    });
}

static void capturePlayer(id player) {
    if (!sg_players) sg_players = [NSHashTable weakObjectsHashTable];
    if ([sg_players containsObject:player]) return;
    [sg_players addObject:player];
    logPlayersSoon();
    if (!sg_player) {
        sg_player = player;
        sg_observer = [MRGPlayerObserver new];
        if ([player respondsToSelector:@selector(addPlayerObserver:)]) [player addPlayerObserver:sg_observer];
        else missing(player, @"addPlayerObserver:");
        stateChanged(currentState());
    }
}

%group MRGPlayerHooks
%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    if ([observer isKindOfClass:MRGPlayerObserver.class]) return;
    id player = self;
    dispatch_async(dispatch_get_main_queue(), ^{ capturePlayer(player); });
}
- (void)emitStateUpdate:(id)update oldState:(id)old observer:(id)observer {
    %orig;
    if (![update isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    id player = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        sg_lastState = update;
        if (!sg_player) capturePlayer(player);
    });
}
%end
%end

// Spotify's link dispatcher, the object every spotify: link in the app goes through (SPTLinkDispatcherImplementation,
// navigateToURI:options:reason:completionHandler:resultHandler:). Captured as it is made or first used.
static __weak id sg_linkDispatcher;
%group MRGLinkHooks
%hook SPTLinkDispatcherImplementation
- (id)initWithLoginNotifier:(id)a logoutNotifier:(id)b alertQueue:(id)c URISubtypeRegistry:(id)d externalLinkHandler:(id)e thirdPartyAuthLoginPromptEnabled:(BOOL)f {
    id me = %orig;
    sg_linkDispatcher = me;
    return me;
}
- (void)navigateToURI:(id)uri options:(long long)options reason:(id)reason completionHandler:(id)completion resultHandler:(id)result {
    sg_linkDispatcher = self;
    %orig;
}
- (BOOL)canOpenURI:(id)uri allowExternalApps:(BOOL)apps {
    sg_linkDispatcher = self;
    return %orig;
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

BOOL MRGPlayerIsPlaying(void) {
    id st = currentState();
    return stateTrack(st) && statePlaying(st) && !statePaused(st);
}

NSString *MRGPlayerContextURI(void) { return stateContext(currentState()); }

// The task Spotify's player hands back for a command: its callbacks say whether the command was taken.
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

// The player that plays music for the app: not one of the DJ, preview or video features' players. Among the rest, the
// one whose state holds the track that is on, then the one with no feature (the app's default), then any.
static BOOL sideFeature(NSString *f) {
    NSString *l = f.lowercaseString;
    for (NSString *bad in @[@"endless", @"djmusic", @"aidj", @"interactivity", @"preview", @"sample", @"watchfeed", @"video", @"clips", @"ads"])
        if ([l containsString:bad]) return YES;
    return NO;
}

static id playingPlayer(void) {
    NSArray *all = sg_players.allObjects;
    id best = nil;
    for (id p in all) if (!sideFeature(featureOf(p)) && stateTrack(stateOf(p))) { best = p; break; }
    if (!best) for (id p in all) if (!featureOf(p).length) { best = p; break; }
    if (!best) for (id p in all) if (!sideFeature(featureOf(p))) { best = p; break; }
    if (!best) best = sg_player ?: all.firstObject;
    static __weak id logged;
    if (best && best != logged) { logged = best; MRGDJLog(@"player: playing with feature %@", featureOf(best).length ? featureOf(best) : @"(none)"); }
    return best;
}

// The origin the player makes for itself (its own feature identifier), as Spotify's pages do.
static id originFor(id player, NSString *viewURI) {
    NSURL *view = viewURI ? [NSURL URLWithString:viewURI] : nil;
    if ([player respondsToSelector:@selector(playOriginWithViewURIOverride:externalReferrer:)])
        return [player playOriginWithViewURIOverride:view externalReferrer:nil];
    missing(player, @"playOriginWithViewURIOverride:externalReferrer:");
    return nil;
}

static id runPlay(id player, id context, id options, id origin) {
    if (origin && [player respondsToSelector:@selector(playContext:options:origin:)]) return [player playContext:context options:options origin:origin];
    if ([player respondsToSelector:@selector(playContext:options:)]) return [player playContext:context options:options];
    missing(player, @"playContext:options:");
    return nil;
}

// Plays a context by URI (a track, an album, a playlist) the way Spotify's own Play buttons do: SPTPlayerContext
// contextForURI:, SPTPlayOptions (skipTo the start track when given, sent again without it if refused) and the player's
// own origin (playOriginWithViewURIOverride:externalReferrer:), through playContext:options:origin:.
void MRGPlayContextURI(NSString *uri, NSString *startTrack, void (^done)(BOOL, NSString *)) {
    @try {
        id player = playingPlayer();
        Class contextClass = objc_getClass("SPTPlayerContext");
        id context = [contextClass respondsToSelector:@selector(contextForURI:)] ? [contextClass contextForURI:[NSURL URLWithString:uri]] : nil;
        if (!player || !context) {
            MRGDJLog(@"play %@: %@", uri, player ? @"no SPTPlayerContext contextForURI:" : @"no player captured yet");
            done(NO, player ? @"Spotify's player classes weren't found." : @"Spotify's player isn't ready yet. Play any song once, then try again.");
            return;
        }
        id origin = originFor(player, uri);
        id options = [objc_getClass("SPTPlayOptions") new];
        Class skipClass = objc_getClass("SPTSkipToTrack");
        BOOL skips = startTrack && [options respondsToSelector:@selector(setSkipTo:)] && [skipClass instancesRespondToSelector:@selector(initWithTrackURI:)];
        if (skips) [options setSkipTo:[[skipClass alloc] initWithTrackURI:[NSURL URLWithString:startTrack]]];
        id task = runPlay(player, context, options, origin);
        MRGDJLog(@"play %@ (skipTo %@): task %@", uri, skips ? @"yes" : @"no", task ? NSStringFromClass([task class]) : @"nil");
        if (!task) { done(NO, @"Spotify's player didn't take the request."); return; }
        watchTask(task, ^(BOOL ok, NSString *error) {
            MRGDJLog(@"play %@: %@", uri, ok ? @"taken" : [@"refused: " stringByAppendingString:error ?: @"?"]);
            if (ok || !skips) { done(ok, error); return; }
            id plain = runPlay(player, context, [objc_getClass("SPTPlayOptions") new], origin);
            if (!plain) { done(NO, error); return; }
            watchTask(plain, ^(BOOL ok2, NSString *error2) {
                MRGDJLog(@"play %@ without skipTo: %@", uri, ok2 ? @"taken" : [@"refused: " stringByAppendingString:error2 ?: @"?"]);
                done(ok2, error2);
            });
        });
    } @catch (NSException *e) {
        MRGDJLog(@"play %@: exception %@: %@", uri, e.name, e.reason);
        done(NO, [NSString stringWithFormat:@"Spotify's player threw %@.", e.name]);
    }
}

static NSArray *playerTracks(NSArray<NSString *> *uris) {
    Class trackClass = objc_getClass("SPTPlayerTrack");
    if (![trackClass respondsToSelector:@selector(trackWithURI:)]) { MRGDJLog(@"selector missing: +[SPTPlayerTrack trackWithURI:]"); return nil; }
    NSMutableArray *tracks = [NSMutableArray array];
    for (NSString *u in uris) {
        id t = [trackClass trackWithURI:[NSURL URLWithString:u]];
        if (t) [tracks addObject:t];
    }
    return tracks;
}

// Adds tracks to the queue (SPTPlayerQueueWrapperImpl initWithPlayer: + queueMultipleTracks:loggingParams:, the
// wrapper Spotify's "Add to queue" uses). Only called once the context is actually playing: queued earlier, the player
// answered 409 Conflict. A Conflict is tried again twice, a second apart.
void MRGQueueTracks(NSArray<NSString *> *uris, void (^done)(BOOL ok, NSString *error)) {
    __block NSUInteger tries = 0;
    __block void (^attempt)(void);
    void (^run)(void) = ^{
        @try {
            Class wrapper = objc_getClass("SPTPlayerQueueWrapperImpl");
            id player = playingPlayer();
            NSArray *tracks = playerTracks(uris);
            if (!player || !tracks.count || ![wrapper instancesRespondToSelector:@selector(initWithPlayer:)] ||
                ![wrapper instancesRespondToSelector:@selector(queueMultipleTracks:loggingParams:)]) {
                MRGDJLog(@"queue: the queue wrapper isn't reachable");
                attempt = nil;
                done(NO, @"Spotify's queue isn't reachable.");
                return;
            }
            SPTPlayerQueueWrapperImpl *queue = [[wrapper alloc] initWithPlayer:player];
            tries++;
            watchTask([queue queueMultipleTracks:tracks loggingParams:nil], ^(BOOL ok, NSString *error) {
                (void)queue;
                MRGDJLog(@"queue: %lu tracks, try %lu: %@", (unsigned long)tracks.count, (unsigned long)tries, ok ? @"queued" : [@"refused: " stringByAppendingString:error ?: @"?"]);
                if (ok || tries >= 3) { attempt = nil; done(ok, error); return; }
                void (^again)(void) = attempt;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (again) again(); });
            });
        } @catch (NSException *e) {
            MRGDJLog(@"queue: exception %@: %@", e.name, e.reason);
            attempt = nil;
            done(NO, e.reason);
        }
    };
    attempt = run;
    run();
}

BOOL MRGOpenSpotifyURI(NSString *uri) {
    id d = sg_linkDispatcher;
    SEL sel = @selector(navigateToURI:options:reason:completionHandler:resultHandler:);
    if (![d respondsToSelector:sel]) { MRGDJLog(@"open %@: link dispatcher not captured", uri); return NO; }
    [d navigateToURI:[NSURL URLWithString:uri] options:0 reason:nil completionHandler:nil resultHandler:nil];
    MRGDJLog(@"open %@: handed to Spotify's link dispatcher", uri);
    return YES;
}

// Watches the player until it plays one of the tracks (or the context), or the time runs out. Every read goes through
// the guarded accessors (isPaused, not `paused`, which SPTPlayerState doesn't answer: the 0.2.2 crash).
void MRGWaitForPlayback(NSArray<NSString *> *tracks, NSString *contextURI, NSTimeInterval timeout, void (^done)(BOOL, NSString *)) {
    CFTimeInterval end = CACurrentMediaTime() + timeout;
    __block BOOL finished = NO;
    BOOL (^check)(void) = ^BOOL {
        if (finished) return YES;
        @try {
            id st = currentState();
            NSString *track = uriString(sget(stateTrack(st), @"URI")), *context = stateContext(st);
            BOOL onTrack = track && [tracks containsObject:track];
            BOOL onContext = contextURI && [context isEqualToString:contextURI];
            if ((onTrack || onContext) && !statePaused(st)) {
                finished = YES;
                MRGDJLog(@"verify: playing %@ in %@", onTrack ? @"a set track" : @"the context", context ?: @"?");
                done(YES, nil);
                return YES;
            }
            if (CACurrentMediaTime() >= end) {
                finished = YES;
                NSString *seen = [NSString stringWithFormat:@"the player stayed on %@ (%@)", context ?: @"no context",
                                  statePaused(st) ? @"paused" : statePlaying(st) ? @"playing" : @"stopped"];
                MRGDJLog(@"verify: gave up, %@", seen);
                done(NO, seen);
                return YES;
            }
        } @catch (NSException *e) {
            finished = YES;
            MRGDJLog(@"verify: exception %@: %@", e.name, e.reason);
            done(NO, @"couldn't read the player's state");
            return YES;
        }
        return NO;
    };
    if (check()) return;
    [NSTimer scheduledTimerWithTimeInterval:0.4 repeats:YES block:^(NSTimer *t) { if (check()) [t invalidate]; }];
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
        if (objc_getClass("SPTLinkDispatcherImplementation")) %init(MRGLinkHooks);
        if (objc_getClass("SPTDataLoaderService")) %init(MRGHeadersDataLoader);
        if (objc_getClass("_TtC26Connectivity_HttpClientKit20HttpClientURLSession")) %init(MRGHeadersHttpClient);
        sg_duckReady = MRGRebindImport("AudioOutputUnitStart", (void *)startOutput, (void **)&sg_realStart) && sg_realStart;
        if (sg_duckReady) MRGRebindImport("AudioComponentInstanceDispose", (void *)disposeUnit, (void **)&sg_realDispose);
    }
}
