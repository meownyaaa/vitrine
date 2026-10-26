// Checks what reaches the system's now playing through the mod's two hooks of the setter,
// Shared/Player/NowPlayingExtras.x and Shared/LockScreenLyrics/LockScreenLyrics.x, built as the tweak
// builds them. The system's setter and getter are replaced underneath both (this file links first, so its
// constructor runs before their %ctors), and Karaoke is a stub with two lines. Run with LSL=1 for lock
// screen lyrics on, without it for off; it exits non-zero on the first check that fails.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#include <stdlib.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Headers/SPTPlayer.h"

#pragma mark - the system, underneath

static NSDictionary *sg_system;   // what the system was last given
static NSUInteger sg_sets;

static void systemSet(id self, SEL _cmd, NSDictionary *info) {
    sg_system = info;
    sg_sets++;
}

static NSDictionary *systemGet(id self, SEL _cmd) {
    return sg_system;
}

__attribute__((constructor)) static void underneath(void) {
    Class center = MPNowPlayingInfoCenter.class;
    class_replaceMethod(center, @selector(setNowPlayingInfo:), (IMP)systemSet, "v@:@");
    class_replaceMethod(center, @selector(nowPlayingInfo), (IMP)systemGet, "@@:");
}

#pragma mark - stubs

BOOL SGFlag(NSString *key, BOOL fallback) { return getenv("LSL") != NULL; }
void SGPrefsChanged(void) {}

@implementation SPTPlayerTrack {
@public
    NSString *_title;
}
- (NSString *)trackTitle { return _title; }
@end

@implementation SPTPlayerState {
@public
    SPTPlayerTrack *_track;
}
- (SPTPlayerTrack *)track { return _track; }
@end

@interface SGStubPlayer : NSObject
@property (nonatomic) SPTPlayerState *state;
@end
@implementation SGStubPlayer
@end

static SGStubPlayer *sg_player;
static NSArray<SGKaraokeLine *> *sg_lines;

id SGKaraokePlayer(void) { return sg_player; }
NSString *SGKaraokePlayingTrack(void) { return @"track"; }
NSArray<SGKaraokeLine *> *SGKaraokeLinesForTrack(NSString *trackID) { return sg_lines; }
void SGKaraokeRequestLyrics(NSString *trackID) {}
// The lines are there from the start, so nothing is posted under it.
NSNotificationName const SGKaraokeLinesKeptNotification = @"harness.karaokeLinesKept";
NSInteger SGKaraokeDelayMs(void) { return [NSUserDefaults.standardUserDefaults integerForKey:SGKeyLyricsDelay]; }

static SGKaraokeLine *lineOf(NSString *text, NSInteger start, NSInteger end) {
    SGKaraokeWord *word = [SGKaraokeWord new];
    word.text = text;
    word.start = start;
    word.end = end;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = @[word];
    line.start = start;
    line.end = end;
    line.timing = SGKaraokeTimingWords;
    return line;
}

#pragma mark - checks

static int failures;

static void check(BOOL ok, NSString *what) {
    printf("%s %s\n", ok ? "ok  " : "FAIL", what.UTF8String);
    if (!ok) failures++;
}

static void runFor(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}

static NSDictionary *spotifyInfo(NSString *title, double elapsed, double rate) {
    return @{MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: @"Artist",
             MPNowPlayingInfoPropertyElapsedPlaybackTime: @(elapsed), MPNowPlayingInfoPropertyPlaybackRate: @(rate)};
}

static double systemElapsed(void) {
    return [sg_system[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
}

// Lock screen lyrics: once the line is let go, the artist comes back with the clock moved on, and the
// extras' clock, which records what passes, is not pulled back by it either.
static void progressBar(void) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    // Rate 4, so the 4 s break after the line's end comes in about a second of wall time.
    const double rate = 4;
    CFAbsoluteTime setAt = CFAbsoluteTimeGetCurrent();
    center.nowPlayingInfo = spotifyInfo(@"Song", 0, rate);
    check([sg_system[MPMediaItemPropertyArtist] isEqual:@"Hello"], @"the line sung shows in place of the artist");
    runFor(1.6);
    double expected = rate * (CFAbsoluteTimeGetCurrent() - setAt);
    check([sg_system[MPMediaItemPropertyArtist] isEqual:@"Artist"], @"the artist comes back in the break");
    // The line is let go 4 s past its end at 0.1 s, so the info that lets it go is from 4.1 s on.
    check(systemElapsed() > 4.1 && systemElapsed() <= expected,
          [NSString stringWithFormat:@"the break's info is at %.2f s, not Spotify's 0", systemElapsed()]);
    SGNowPlayingSetExtras(@"haptics", @{MPNowPlayingInfoPropertyInternationalStandardRecordingCode: @"ISRC"}, @"Song");
    expected = rate * (CFAbsoluteTimeGetCurrent() - setAt);
    check(fabs(systemElapsed() - expected) < 1.5,
          [NSString stringWithFormat:@"an extra's resend is at %.2f s (expected about %.2f)", systemElapsed(), expected]);
    SGNowPlayingSetExtras(@"haptics", nil, nil);
}

// Lock screen translation (on with LSL, as every flag is): a translation longer than the row is cut by its own
// length, not the line's, and its pieces follow the line's clock.
static void translation(void) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSArray<SGKaraokeLine *> *was = sg_lines;
    SGKaraokeLine *line = lineOf(@"Hola", 0, 4000);
    line.translation = @"This translation runs well past what the lock screen's artist row holds";
    sg_lines = @[line];
    center.nowPlayingInfo = spotifyInfo(@"Song", 0, 0);
    NSString *first = sg_system[MPMediaItemPropertyArtist];
    check(first.length > 0 && first.length <= 30 && [line.translation hasPrefix:first],
          [NSString stringWithFormat:@"the translation's first piece shows: \"%@\"", first]);
    center.nowPlayingInfo = spotifyInfo(@"Song", 3.9, 0);
    NSString *last = sg_system[MPMediaItemPropertyArtist];
    check(last.length > 0 && last.length <= 30 && [line.translation hasSuffix:last],
          [NSString stringWithFormat:@"its last piece shows by the line's end: \"%@\"", last]);
    sg_lines = was;
}

// Two tracks with one title: what the first had must not stay on the second's info once it is cleared.
static void sameTitle(void) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSString *key = MPNowPlayingInfoPropertyInternationalStandardRecordingCode;
    center.nowPlayingInfo = spotifyInfo(@"Intro", 50, 0);
    SGNowPlayingSetExtras(@"lyrics", @{key: @"first"}, @"Intro");
    check([sg_system[key] isEqual:@"first"], @"the extra rides on its title's info");
    center.nowPlayingInfo = spotifyInfo(@"Intro", 0, 0);   // the next track, also called Intro
    check([sg_system[key] isEqual:@"first"], @"it rides on the next track of that title until cleared");
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
    check(sg_system && !sg_system[key], @"cleared, it is taken off the info at once");
    check(fabs(systemElapsed()) < 0.01, @"the paused clock is kept");

    // Spotify building its next info from the one it reads back, so the extra comes along under a new title.
    SGNowPlayingSetExtras(@"lyrics", @{key: @"second"}, @"Intro");
    NSMutableDictionary *copied = [center.nowPlayingInfo mutableCopy];
    copied[MPMediaItemPropertyTitle] = @"Outro";
    center.nowPlayingInfo = copied;
    check([sg_system[key] isEqual:@"second"], @"copied, it rides on another title's info");
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
    check(!sg_system[key], @"cleared, it comes off an info it was copied onto");

    // Nothing to take off: nothing is sent.
    SGNowPlayingSetExtras(@"lyrics", @{key: @"third"}, @"Intro");
    NSUInteger sets = sg_sets;
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
    check(sg_sets == sets, @"cleared for another title, the info is not sent again");

    // Another owner's extra for the same title stays.
    center.nowPlayingInfo = spotifyInfo(@"Intro", 0, 0);
    SGNowPlayingSetExtras(@"haptics", @{@"other": @"kept"}, @"Intro");
    SGNowPlayingSetExtras(@"lyrics", @{key: @"fourth"}, @"Intro");
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
    check(!sg_system[key] && [sg_system[@"other"] isEqual:@"kept"], @"another owner's extra stays on");
    SGNowPlayingSetExtras(@"haptics", nil, nil);
}

int main(void) {
    @autoreleasepool {
        SPTPlayerTrack *track = [SPTPlayerTrack new];
        track->_title = @"Song";
        SPTPlayerState *state = [SPTPlayerState new];
        state->_track = track;
        sg_player = [SGStubPlayer new];
        sg_player.state = state;
        sg_lines = @[lineOf(@"Hello", 0, 100), lineOf(@"Later", 60000, 61000)];
        BOOL lyrics = getenv("LSL") != NULL;
        printf("lock screen lyrics %s\n", lyrics ? "on" : "off");
        if (lyrics) progressBar();
        if (lyrics) translation();
        sameTitle();
        printf(failures ? "%d failed\n" : "all passed\n", failures);
        return failures ? 1 : 0;
    }
}
