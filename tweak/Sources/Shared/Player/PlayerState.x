// PlayerState.h names the hooks and why they are the ones.
#import "Core/SGCore.h"
#import "PlayerState.h"

NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSString.class]) return uri;
    if ([uri isKindOfClass:NSURL.class]) return ((NSURL *)uri).absoluteString;
    return nil;
}

static NSHashTable<id<SGPlayerStateObserver>> *sg_stateObservers;
static SPTPlayerState *sg_playerState;
// What the last change was told from, so a report that moved none of them tells observers nothing.
static BOOL sg_stateSeen;
static NSString *sg_stateTrack, *sg_stateContext;
static int sg_stateBits;
// Set once the now playing platform has reported; the mod's own observer on the player stands down.
static BOOL sg_platformReported = NO;

void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) {
    if (!observer) return;
    if (!sg_stateObservers) sg_stateObservers = [NSHashTable weakObjectsHashTable];
    [sg_stateObservers addObject:observer];
}

SPTPlayerState *SGPlayerState(void) {
    return sg_playerState;
}

static BOOL sameURI(NSString *a, NSString *b) {
    return a == b || [a isEqualToString:b];
}

// What an observer is told about; the state object itself is new with every position report.
static void publish(SPTPlayerState *state) {
    sg_playerState = state;
    for (id<SGPlayerStateObserver> observer in sg_stateObservers.allObjects) {
        if ([observer respondsToSelector:@selector(playerStateDidReport:)]) [observer playerStateDidReport:state];
    }
    NSString *track = SGURIString(state.track.URI), *context = SGURIString(state.contextURI);
    SPTPlayerOptions *options = [state respondsToSelector:@selector(options)] ? state.options : nil;
    BOOL paused = state.isPaused, playing = state.isPlaying;
    BOOL loading = [state respondsToSelector:@selector(isLoading)] && state.isLoading;
    BOOL shuffling = [options respondsToSelector:@selector(shufflingContext)] && options.shufflingContext;
    int bits = paused | playing << 1 | loading << 2 | shuffling << 3;
    if (sg_stateSeen && bits == sg_stateBits && sameURI(track, sg_stateTrack) && sameURI(context, sg_stateContext)) return;
    sg_stateSeen = YES;
    sg_stateTrack = track;
    sg_stateContext = context;
    sg_stateBits = bits;
    for (id<SGPlayerStateObserver> observer in sg_stateObservers.allObjects) [observer playerStateDidChange:state];
}

static void report(id state, BOOL platform) {
    if (![state isKindOfClass:objc_getClass("SPTPlayerState")]) return;
    dispatch_block_t apply = ^{
        if (platform) sg_platformReported = YES;
        else if (sg_platformReported) return;
        publish(state);
    };
    if (NSThread.isMainThread) apply();
    else dispatch_async(dispatch_get_main_queue(), apply);
}

@interface SGPlayerObserver : NSObject
@end

@implementation SGPlayerObserver
- (void)player:(id)player stateDidChange:(id)state {
    report(state, NO);
}
@end

static SGPlayerObserver *sg_ownObserver;
static __weak id sg_player;

id SGPlayer(void) {
    return sg_player;
}

%hook _TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation
- (void)player:(id)player stateDidChange:(id)state {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        SGLog(@"player state: from %@, a %@, on the main thread %d", [player class], [state class], NSThread.isMainThread);
    });
    report(state, YES);
}
%end

// Observers are added from several threads as the app starts; the first player seen is the one
// watched, the way KaraokeSource.x takes the first player the app asks.
%hook SPTEsperantoPlayer
- (void)addPlayerObserver:(id)observer {
    %orig;
    id player = self;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_player = player;
            sg_ownObserver = [SGPlayerObserver new];
            [(id<SPTPlayer>)player addPlayerObserver:sg_ownObserver];
            id state = [player respondsToSelector:@selector(state)] ? [(id<SPTPlayer>)player state] : nil;
            if (state) report(state, NO);
        });
    });
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC23NowPlaying_PlatformImpl28StatefulPlayerImplementation", @"SPTEsperantoPlayer", @"SPTPlayerState"]);
}
