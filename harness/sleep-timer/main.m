// SleepTimer.m on the Mac, over a player stood in for: the fade's curve and its length (the Fade out choice,
// per mode), which track ends the album, and the timer itself in real time (a 2 s timer fades, pauses and
// gives the gain back a second later). Fails
// with the checks that did not hold.
//
//     ./build.sh && build/sleep-timer
#import <Foundation/Foundation.h>
#import "Headers/SPTPlayer.h"
#import "Shared/Player/SleepTimer.h"
#import "Shared/Player/PlayerState.h"
#import "Core/SGPrefs.h"

@interface SPTPlayerTrack ()
@property (nonatomic, readwrite) id URI;
@property (nonatomic, readwrite, copy) NSString *provider;
@property (nonatomic, readwrite) NSDictionary<NSString *, NSString *> *metadata;
@property (nonatomic, readwrite) NSString *trackTitle;
@end
@implementation SPTPlayerTrack
@end

@interface SPTPlayerOptions ()
@property (nonatomic, readwrite) BOOL repeatingContext;
@end
@implementation SPTPlayerOptions
@end

@interface SPTSleepTimer ()
@property (nonatomic, readwrite) NSUInteger type;
@property (nonatomic, readwrite) NSDate *timestamp;
@end
@implementation SPTSleepTimer
@end

@interface SPTPlayerState ()
@property (nonatomic, readwrite) SPTPlayerTrack *track;
@property (nonatomic, readwrite) id contextURI;
@property (nonatomic, readwrite) SPTPlayerOptions *options;
@property (nonatomic, readwrite) BOOL isPaused;
@property (nonatomic, readwrite) BOOL isPlaying;
@property (nonatomic, readwrite) SPTSleepTimer *sleepTimer;
@property (nonatomic, readwrite) double duration;
@property (nonatomic, readwrite) NSArray *future;
@property (nonatomic, readwrite) NSArray *reverse;
@end
@implementation SPTPlayerState
@end

// The player: its state, and the pauses asked of it.
@interface MockPlayer : NSObject
@property (nonatomic) SPTPlayerState *state;
@property (nonatomic) NSInteger pauses;
@end
@implementation MockPlayer
- (id)pause:(id)options {
    self.pauses++;
    self.state.isPaused = YES;
    self.state.isPlaying = NO;
    return nil;
}
@end

// SpotifySleepTimer.m's player state observer, and Spotify's own Fade out flag as forced (nil for not).
static id<SGPlayerStateObserver> sg_observer;
void SGAddPlayerStateObserver(id<SGPlayerStateObserver> observer) { sg_observer = observer; }
static NSNumber *sg_spotifyFadeForced;
id SGForcedFlagValue(NSString *key) {
    return [key isEqualToString:@"ios-feature-sleeptimer.enable_fade_out"] ? sg_spotifyFadeForced : nil;
}

static MockPlayer *sg_player;
static NSInteger sg_positionMs = -1;
static float sg_gain = 1;
// The Fade out choice as stored, nil for none picked.
static NSNumber *sg_fadeChoice;

NSInteger SGInt(NSString *key, NSInteger fallback) {
    return [key isEqualToString:SGKeySleepTimerFade] && sg_fadeChoice ? sg_fadeChoice.integerValue : fallback;
}
// The curve over a one minute fade, the one the timer checks below run with.
static float SGSleepTimerGainAt(NSTimeInterval left) {
    return SGSleepTimerGain(left, 60);
}

NSInteger SGKaraokePositionMs(void) { return sg_positionMs; }
// How often the player's state was asked for: SpotifySleepTimer.m's check asks it four times a second.
static NSInteger sg_playerAsks;
id SGKaraokePlayer(void) { sg_playerAsks++; return sg_player; }
void SGPlayerSetGain(float gain) { sg_gain = gain; }
NSString *SGURIString(id uri) {
    if ([uri isKindOfClass:NSString.class]) return uri;
    if ([uri isKindOfClass:NSURL.class]) return ((NSURL *)uri).absoluteString;
    return nil;
}

static int sg_failures;
#define CHECK(condition, what) do { \
    BOOL held = (condition); \
    if (!held) sg_failures++; \
    printf("%s  %s\n", held ? "ok  " : "FAIL", what); \
} while (0)

static SPTPlayerTrack *track(NSString *name, NSString *provider, NSDictionary *metadata) {
    SPTPlayerTrack *track = [SPTPlayerTrack new];
    track.URI = [NSURL URLWithString:[@"spotify:track:" stringByAppendingString:name]];
    track.trackTitle = name;
    track.provider = provider;
    track.metadata = metadata ?: @{};
    return track;
}

static SPTPlayerState *state(SPTPlayerTrack *playing, NSArray *future, NSArray *reverse, BOOL repeating) {
    SPTPlayerState *state = [SPTPlayerState new];
    state.track = playing;
    state.contextURI = @"spotify:album:one";
    state.options = [SPTPlayerOptions new];
    state.options.repeatingContext = repeating;
    state.duration = 100;
    state.future = future;
    state.reverse = reverse;
    return state;
}

// Spotify's own timer as its state reports it: type 1 at `seconds` from now, 2 at the end of the track.
static SPTSleepTimer *spotifyTimer(NSUInteger type, NSTimeInterval seconds) {
    SPTSleepTimer *timer = [SPTSleepTimer new];
    timer.type = type;
    if (type == 1) timer.timestamp = [NSDate dateWithTimeIntervalSinceNow:seconds];
    return timer;
}

// The core reports a new state with every change, the timer's too: told to the observer before the wait.
static void runFor(NSTimeInterval seconds) {
    [sg_observer playerStateDidReport:sg_player.state];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static BOOL near(float a, float b) {
    return fabsf(a - b) < 0.0005f;
}

int main(void) {
    @autoreleasepool {
        // The fade.
        CHECK(SGSleepTimerGainAt(120) == 1 && SGSleepTimerGainAt(60) == 1, "gain is 1 until the last minute");
        CHECK(near(SGSleepTimerGainAt(30), 0.0316f), "halfway through the minute it is 30 dB down");
        CHECK(near(SGSleepTimerGainAt(0), 0.001f) && near(SGSleepTimerGainAt(-3), 0.001f), "at the end it is 60 dB down");
        BOOL falls = YES;
        for (int left = 59; left > 0; left--) falls = falls && SGSleepTimerGainAt(left) < SGSleepTimerGainAt(left + 1);
        CHECK(falls, "it falls every second of the minute");
        BOOL ends = YES;
        for (NSNumber *fade in @[@10, @30, @60, @120]) {
            NSTimeInterval f = fade.doubleValue;
            ends = ends && SGSleepTimerGain(f, f) == 1 && SGSleepTimerGain(f + 5, f) == 1 && near(SGSleepTimerGain(0, f), 0.001f)
                && near(SGSleepTimerGain(f / 2, f), 0.0316f);
        }
        CHECK(ends, "each fade length: 1 at its start, 30 dB down halfway, 60 dB at the end");
        CHECK(SGSleepTimerGain(0, 0) == 1 && SGSleepTimerGain(5, 0) == 1, "fade Off: 1 all the way");

        // The choice.
        CHECK(SGSleepTimerFadeChoice() == 2 && SGSleepTimerFade() == 30, "none picked: 30 s");
        NSArray *lengths = @[@0, @10, @30, @60, @120];
        BOOL picks = SGSleepTimerFadeNames().count == lengths.count;
        for (NSInteger i = 0; i < (NSInteger)lengths.count; i++) {
            sg_fadeChoice = @(i);
            picks = picks && SGSleepTimerFade() == [lengths[i] doubleValue];
        }
        CHECK(picks, "Off, 10 s, 30 s, 1 minute, 2 minutes read as 0, 10, 30, 60, 120 s");
        sg_fadeChoice = @9;
        CHECK(SGSleepTimerFade() == 30, "a choice out of range: 30 s");
        sg_fadeChoice = @3;

        // Which track ends the album.
        SPTPlayerTrack *a = track(@"a", @"context", nil), *b = track(@"b", @"context", nil), *c = track(@"c", @"context", nil);
        SPTPlayerTrack *queued = track(@"q", @"queue", nil), *queuedByKey = track(@"k", nil, @{@"is_queued": @"true"});
        SPTPlayerTrack *autoplay = track(@"r", @"autoplay", nil), *autoplayByKey = track(@"s", nil, @{@"autoplay.is_autoplay": @"true"});
        SPTPlayerTrack *unknown = track(@"u", nil, nil);
        CHECK(!SGSleepTimerOnLastOfContext(state(b, @[c], @[a], NO)), "a track of the album to come: not the last");
        CHECK(SGSleepTimerOnLastOfContext(state(c, @[], @[a, b], NO)), "nothing to come: the last");
        CHECK(SGSleepTimerOnLastOfContext(state(c, @[queued, queuedByKey], @[a, b], NO)), "only tracks queued by hand to come: the last");
        CHECK(SGSleepTimerOnLastOfContext(state(c, @[autoplay, autoplayByKey], @[a, b], NO)), "only autoplay's to come: the last");
        CHECK(!SGSleepTimerOnLastOfContext(state(b, @[queued, c, autoplay], @[a], NO)), "a queued track, then the album's: not the last");
        CHECK(!SGSleepTimerOnLastOfContext(state(b, @[unknown], @[a], NO)), "a track that names no provider counts as the album's");
        CHECK(SGSleepTimerOnLastOfContext(state(c, @[a, b], @[b, a], YES)), "repeating, the album starting over: the last");
        CHECK(SGSleepTimerOnLastOfContext(state(a, @[a], @[], YES)), "repeating a one track album: the last");
        CHECK(!SGSleepTimerOnLastOfContext(state(b, @[c, a], @[a], YES)), "repeating, mid album: not the last");
        CHECK(!SGSleepTimerOnLastOfContext(state(c, @[a, b], @[b, a], NO)), "not repeating, a track played before to come: not the last");
        CHECK(!SGSleepTimerOnLastOfContext(state(b, @[@"not a track", c], @[a], NO)), "what is not a track is skipped");

        // The timer, in real time.
        sg_player = [MockPlayer new];
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_positionMs = 10000;
        SGSetSleepTimer(SGSleepTimerAtTime, 2);
        CHECK(SGSleepTimerCurrentMode() == SGSleepTimerAtTime && SGSleepTimerEnd() != nil, "a 2 s timer is set");
        CHECK(sg_gain < SGSleepTimerGainAt(2.1) && sg_gain > SGSleepTimerGainAt(1.9), "a timer inside the last minute starts faded");
        runFor(1);
        CHECK(sg_player.pauses == 0 && sg_gain < 0.002f, "a second on, still playing, quieter");
        runFor(1.4);
        CHECK(sg_player.pauses == 1 && SGSleepTimerCurrentMode() == SGSleepTimerOff && !SGSleepTimerEnd(), "at its end it paused and is off");
        CHECK(sg_gain < 0.002f, "the gain stays down while the pause lands");
        runFor(1.2);
        CHECK(sg_gain == 1, "a second after the pause the gain is back");

        sg_player.state = state(a, @[b, c], @[], NO);
        SGSetSleepTimer(SGSleepTimerAtTime, 30);
        CHECK(near(sg_gain, SGSleepTimerGainAt(30)), "30 s to go: 30 dB down");
        SGSleepTimerAdd(15 * 60);
        CHECK(fabs(SGSleepTimerEnd().timeIntervalSinceNow - 930) < 1 && sg_gain == 1, "15 minutes more: the end moves on and the gain is back");
        SGSetSleepTimer(SGSleepTimerOff, 0);
        CHECK(SGSleepTimerCurrentMode() == SGSleepTimerOff && sg_gain == 1, "canceled");
        SGSleepTimerAdd(15 * 60);
        CHECK(fabs(SGSleepTimerEnd().timeIntervalSinceNow - 900) < 1, "15 minutes more with none set: 15 minutes from now");
        SGSetSleepTimer(SGSleepTimerOff, 0);

        // The end of the track.
        sg_positionMs = 70000;
        SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        CHECK(!SGSleepTimerEnd() && near(sg_gain, SGSleepTimerGainAt(30)), "end of track, 30 s left: 30 dB down");
        sg_positionMs = 99700;
        runFor(0.4);
        CHECK(sg_player.pauses == 2 && SGSleepTimerCurrentMode() == SGSleepTimerOff, "end of track: paused just before the end");
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_positionMs = 5000;
        SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        CHECK(sg_gain == 1, "end of track, more than a minute left: full volume");
        sg_player.state = state(b, @[c], @[a], NO);
        runFor(0.4);
        CHECK(sg_player.pauses == 3, "end of track, the next track already on: paused at once");
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_player.state.isPaused = YES;
        sg_positionMs = 99900;
        SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        CHECK(sg_player.pauses == 3 && SGSleepTimerCurrentMode() == SGSleepTimerOff, "up while paused: no pause sent, and off");
        runFor(1.2);

        // The end of the album.
        sg_player.state = state(b, @[c, autoplay], @[a], NO);
        sg_positionMs = 99800;
        SGSetSleepTimer(SGSleepTimerEndOfAlbum, 0);
        CHECK(SGSleepTimerCurrentMode() == SGSleepTimerEndOfAlbum && sg_gain == 1 && sg_player.pauses == 3,
              "end of album, a track still to come: plays on at full volume past this track's end");
        sg_player.state = state(c, @[autoplay], @[a, b], NO);
        sg_positionMs = 70000;
        runFor(0.4);
        CHECK(sg_player.pauses == 3 && near(sg_gain, SGSleepTimerGainAt(30)), "on the last track, 30 s left: 30 dB down");
        sg_positionMs = 99700;
        runFor(0.4);
        CHECK(sg_player.pauses == 4 && SGSleepTimerCurrentMode() == SGSleepTimerOff, "end of album: paused just before the last track's end");
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_positionMs = 1000;
        SGSetSleepTimer(SGSleepTimerEndOfAlbum, 0);
        sg_player.state = state(autoplay, @[autoplayByKey], @[a, b, c], NO);
        runFor(0.4);
        CHECK(sg_player.pauses == 5, "end of album, autoplay playing already: paused at once");
        sg_player.state = state(a, @[b, c], @[], NO);
        SGSetSleepTimer(SGSleepTimerEndOfAlbum, 0);
        sg_player.state = state(b, @[c], @[a], NO);
        sg_player.state.contextURI = @"spotify:playlist:other";
        runFor(0.4);
        CHECK(sg_player.pauses == 6, "end of album, another album or playlist on: paused at once");
        runFor(1.2);
        CHECK(sg_gain == 1, "and the gain is back after");

        // The fade's length, per mode.
        sg_fadeChoice = @1;   // 10 s
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_positionMs = 80000;
        SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        CHECK(sg_gain == 1, "end of track, 10 s fade, 20 s left: full volume");
        sg_positionMs = 95000;
        runFor(0.4);
        CHECK(near(sg_gain, SGSleepTimerGain(5, 10)), "end of track, 10 s fade, 5 s left: 30 dB down");
        sg_fadeChoice = @4;   // 2 minutes, picked while it runs
        runFor(0.4);
        CHECK(near(sg_gain, SGSleepTimerGain(5, 100)), "2 minutes picked while it runs, on a 100 s track: the fade spans the track");
        sg_fadeChoice = @0;   // Off
        runFor(0.4);
        CHECK(sg_gain == 1, "Off picked while it runs: full volume");
        sg_positionMs = 99700;
        runFor(0.4);
        CHECK(sg_player.pauses == 7 && sg_gain == 1, "fade Off: paused at the end at full volume");
        runFor(1.2);

        sg_fadeChoice = @3;   // 1 minute
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_player.state.duration = 20;
        sg_positionMs = 0;
        SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        CHECK(sg_gain == 1, "end of track, a 20 s track and a 1 minute fade: full volume at its start");
        sg_positionMs = 10000;
        runFor(0.4);
        CHECK(near(sg_gain, SGSleepTimerGain(10, 20)) && near(sg_gain, 0.0316f), "halfway through it: 30 dB down, the fade spanning the track");
        SGSetSleepTimer(SGSleepTimerOff, 0);

        sg_player.state = state(c, @[], @[a, b], NO);
        sg_player.state.duration = 20;
        sg_positionMs = 10000;
        SGSetSleepTimer(SGSleepTimerEndOfAlbum, 0);
        CHECK(near(sg_gain, 0.0316f), "end of album, its last track 20 s long, halfway: 30 dB down");
        SGSetSleepTimer(SGSleepTimerOff, 0);

        sg_fadeChoice = @2;   // 30 s
        SGSetSleepTimer(SGSleepTimerAtTime, 45);
        CHECK(sg_gain == 1, "a time, 30 s fade, 45 s to go: full volume");
        SGSetSleepTimer(SGSleepTimerAtTime, 15);
        CHECK(near(sg_gain, SGSleepTimerGain(15, 30)) && near(sg_gain, 0.0316f), "a time, 30 s fade, 15 s to go: 30 dB down");
        SGSetSleepTimer(SGSleepTimerOff, 0);
        CHECK(sg_gain == 1, "canceled: full volume");

        // Spotify's own timer (SpotifySleepTimer.m), read off the state; the core pauses, never the mod.
        CHECK(sg_observer != nil, "Spotify's timer: an observer of the player's state is added at load");
        sg_fadeChoice = @2;   // 30 s
        NSInteger pauses = sg_player.pauses;
        sg_player.state = state(a, @[b, c], @[], NO);
        sg_player.state.isPlaying = YES;
        [sg_observer playerStateDidChange:sg_player.state];
        NSInteger asks = sg_playerAsks;
        runFor(0.6);
        CHECK(sg_gain == 1, "Spotify's: playing with no timer, full volume");
        CHECK(sg_playerAsks == asks, "Spotify's: playing with no timer, no check runs");
        sg_player.state.sleepTimer = spotifyTimer(1, 20);
        runFor(0.4);
        CHECK(sg_gain < SGSleepTimerGain(20.5, 30) && sg_gain > SGSleepTimerGain(19, 30), "Spotify's, at a time 20 s on: faded as 20 s into a 30 s fade");
        sg_player.state.sleepTimer = spotifyTimer(1, 15 * 60);
        runFor(0.4);
        CHECK(sg_gain == 1, "Spotify's moved 15 minutes on: the gain is back");
        sg_player.state.sleepTimer = spotifyTimer(1, 15);
        runFor(0.4);
        CHECK(sg_gain < 0.1f, "Spotify's 15 s on: 30 dB down or so");
        sg_player.state.sleepTimer = nil;
        runFor(0.4);
        CHECK(sg_gain == 1, "Spotify's canceled mid fade: the gain is back at once");

        sg_player.state.sleepTimer = spotifyTimer(1, 1.5);
        runFor(0.4);
        CHECK(sg_gain < 0.01f, "Spotify's 1.5 s on: nearly silent");
        runFor(1.5);
        CHECK(sg_gain < 0.002f && sg_player.pauses == pauses, "its time came: held down, and no pause from the mod");
        sg_player.state.isPaused = YES;   // the core pauses, the expired timer still in its state
        sg_player.state.isPlaying = NO;
        runFor(0.4);
        CHECK(sg_gain < 0.002f, "Spotify paused: still down while the pause lands");
        runFor(1.2);
        CHECK(sg_gain == 1, "a second after Spotify's pause the gain is back");
        sg_player.state.isPaused = NO;
        sg_player.state.isPlaying = YES;
        [sg_observer playerStateDidChange:sg_player.state];
        runFor(0.4);
        CHECK(sg_gain == 1, "played again with the expired timer still reported: not faded again");
        sg_player.state.sleepTimer = nil;
        runFor(0.4);

        sg_player.state.sleepTimer = spotifyTimer(1, 1);
        runFor(0.5);
        sg_player.state.sleepTimer = nil;   // dropped at its end, before the pause
        runFor(0.4);
        CHECK(sg_gain < 0.002f, "Spotify's dropped at its end while still playing: held down");
        sg_player.state.isPaused = YES;
        sg_player.state.isPlaying = NO;
        runFor(1.6);
        CHECK(sg_gain == 1, "then paused: the gain is back a second later");

        sg_player.state = state(a, @[b, c], @[], NO);
        sg_player.state.isPlaying = YES;
        [sg_observer playerStateDidChange:sg_player.state];
        sg_positionMs = 85000;
        sg_player.state.sleepTimer = spotifyTimer(2, 0);
        runFor(0.4);
        CHECK(near(sg_gain, SGSleepTimerGain(15, 30)), "Spotify's end of track, 15 s left of a 30 s fade: 30 dB down");
        sg_player.state = state(b, @[c], @[a], NO);
        sg_player.state.isPlaying = YES;
        sg_player.state.sleepTimer = spotifyTimer(2, 0);
        sg_positionMs = 1000;
        runFor(0.4);
        CHECK(sg_gain == 1, "skipped to another track with time to go: its end is the one now, full volume");
        sg_positionMs = 99500;
        runFor(0.4);
        CHECK(sg_gain < 0.002f, "half a second before that track's end: nearly silent");
        sg_player.state = state(c, @[], @[a, b], NO);   // the next track, the timer still reported
        sg_player.state.isPlaying = YES;
        sg_player.state.sleepTimer = spotifyTimer(2, 0);
        sg_positionMs = 0;
        runFor(0.4);
        CHECK(sg_gain < 0.002f && sg_player.pauses == pauses, "the track ended into the next: held down, no pause from the mod");
        sg_player.state.isPaused = YES;
        sg_player.state.isPlaying = NO;
        runFor(1.6);
        CHECK(sg_gain == 1, "Spotify paused: the gain is back");
        sg_player.state.sleepTimer = nil;
        sg_player.state.isPaused = NO;
        sg_player.state.isPlaying = YES;
        [sg_observer playerStateDidChange:sg_player.state];
        runFor(0.4);

        sg_player.state.duration = 20;
        sg_positionMs = 10000;
        sg_player.state.sleepTimer = spotifyTimer(2, 0);
        runFor(0.4);
        CHECK(near(sg_gain, 0.0316f), "Spotify's end of a 20 s track, halfway: the fade spans the track, 30 dB down");
        sg_player.state.sleepTimer = nil;
        runFor(0.4);

        sg_fadeChoice = @0;   // Off
        sg_player.state.sleepTimer = spotifyTimer(1, 5);
        runFor(0.4);
        CHECK(sg_gain == 1, "Spotify's with fade Off: full volume");
        sg_fadeChoice = @2;
        runFor(0.4);
        CHECK(sg_gain < 0.1f, "30 s picked while it runs: faded");
        sg_spotifyFadeForced = @YES;
        runFor(0.4);
        CHECK(sg_gain == 1, "Spotify's own Fade out forced on: the mod stands aside, full volume");
        sg_spotifyFadeForced = nil;
        sg_player.state.sleepTimer = nil;
        runFor(0.4);

        SGSetSleepTimer(SGSleepTimerAtTime, 300);
        sg_player.state.sleepTimer = spotifyTimer(1, 10);
        runFor(0.4);
        CHECK(sg_gain == 1, "the mod's own timer running (300 s): it has the gain, Spotify's is not faded");
        SGSetSleepTimer(SGSleepTimerOff, 0);
        runFor(0.4);
        CHECK(sg_gain < 0.1f, "the mod's own canceled: Spotify's, 10 s on, is faded");
        sg_player.state.sleepTimer = nil;
        runFor(0.4);
        CHECK(sg_gain == 1 && sg_player.pauses == pauses, "and canceled: full volume; the mod sent no pause for Spotify's");
    }
    printf("%s\n", sg_failures ? "FAILED" : "all held");
    return sg_failures ? 1 : 0;
}
