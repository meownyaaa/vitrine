// The lyrics over the lock screen's large cover below iOS 26, with a jailbreak (SGKeyLockCoverLyrics): Vitrine Addon
// draws them in MediaRemoteUI over the Canvas (addons/haptics/MediaRemoteUICanvas.x), with the lines' own code
// (Shared/Lyrics/KaraokeLines), and from here it gets the song's lines and its clock.
//
// The lines: as a song begins, "pending" is posted, and once its lines are kept (SGKaraokeLinesKeptNotification) they
// are written with the lyrics page's look (SGLyricsLookPlist, and the Lyrics page's romanized lines, word sweep and
// delay) and the song's tag to one file of Spotify's caches, kSGLockLyricsName, which SpringBoard copies where
// MediaRemoteUI can read it; a song with no timed lines gets "none". A song nobody asked lyrics for, with the app in
// the background, has them asked for here. A change of the look, or new lines for the song (a translation), writes the
// file again.
//
// The clock: the position, speed and whether the song plays, with the song's tag, in the state of a notification
// (SGLockLyricsClock), posted as the song starts, stops, seeks or changes speed and every few seconds while it plays;
// MediaRemoteUI runs it on from when it hears it, so the lines keep to the song without a timer here.
//
// A tap on a line there seeks the song: MediaRemoteUI posts the position in a notification's state
// (kSGRelayLockLyricsSeek), and it is taken here as the lyrics page's tap is.
//
// All of it runs only while the lyrics are picked with the large cover's button (lockmode.lyrics, which SpringBoard keeps
// and tells again when asked): with the switch on and the Canvas picked, as most will leave it, no lyrics are fetched,
// written or clocked. Picked, the song playing is taken up at once.
//
// Threading: main queue, but the file's writing, which has a queue of its own.
#import <notify.h>
#import "Core/SGCore.h"
#import "AnimatedArtwork.h"
#import "Shared/Haptics/SGHapticRelay.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"

// A clock is posted again at least this often while the song plays, and whenever the song is this far from where the
// last one said it would be.
static const NSTimeInterval kClockEvery = 5;
static const double kClockSlackMs = 250;

static dispatch_queue_t sg_queue;
static NSString *sg_track;          // the song the lines are for, offered or awaited
static NSUInteger sg_generation;    // which offer a write belongs to
static NSDictionary *sg_written;    // what the last file held, but the lines' order, to write a change only
static int sg_clockToken;
static NSString *sg_reportedURI;    // the track of the last report, so a report of the next one leaves the clock to follow()
static dispatch_source_t sg_clockTimer;
static NSInteger sg_clockMs = -1;
static double sg_clockSpeed;
static BOOL sg_clockPlaying;
static CFAbsoluteTime sg_clockAt;

// The lyrics picked over the Canvas with the large cover's button, as SpringBoard last told it; and whether all of it was
// wanted at the last look, to tell a turn on from the next settings write.
static BOOL sg_picked, sg_wasWanted;

BOOL SGLockCoverLyricsPicked(void) {
    return sg_picked;
}

BOOL SGLockCoverLyricsWanted(void) {
    if (@available(iOS 26.0, *)) return NO;
    return SGFlag(SGKeyLockCoverAddon, NO) && SGEnabled(SGKeyLockCoverLyrics);
}


static BOOL wanted(void) {
    return sg_picked && SGLockCoverLyricsWanted();
}

static NSURL *lyricsFile(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@kSGLockLyricsName];
}

// The lyrics page's look, and what of the Lyrics page's the lines are drawn by besides.
static NSDictionary *lookFor(NSArray<SGKaraokeLine *> *lines) {
    NSMutableDictionary *look = [SGLyricsLookPlist() mutableCopy];
    BOOL romanised = SGFlag(SGKeyLyricsRomanised, NO);
    look[@"romanised"] = @(romanised);
    look[@"romanisedReplace"] = @(romanised && SGFlag(SGKeyLyricsRomanisedReplace, NO));
    look[@"japanese"] = @(romanised && SGLyricsLooksJapanese(lines));
    look[@"sweepsEstimates"] = @(SGFlag(SGKeyLyricsSimulateWords, NO));
    look[@"delay"] = @(SGKaraokeDelayMs());
    return look;
}

// The playing song's lines for the add-on, or "none" for a song without timed lines; nothing while they are still on
// their way. `force` writes them even when the file would hold what it holds.
static void offer(BOOL force) {
    NSString *track = sg_track;
    if (!wanted() || !track) return;
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(track);
    if (!lines) {
        if (!SGKaraokeLooking(track)) SGKaraokeRequestLyrics(track);
        return;
    }
    if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) {
        sg_written = nil;
        notify_post(kSGRelayLockLyricsNone);
        return;
    }
    NSDictionary *content = @{@"tag": @(SGLockLyricsTag(track)), @"look": lookFor(lines), @"lines": SGKaraokeLinesPlist(lines)};
    if (!force && [content isEqualToDictionary:sg_written]) return;
    sg_written = content;
    NSUInteger generation = ++sg_generation;
    dispatch_async(sg_queue, ^{
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:content options:0 error:&error];
        NSURL *file = lyricsFile(), *staging = [file URLByAppendingPathExtension:@"part"];
        NSFileManager *files = NSFileManager.defaultManager;
        [files removeItemAtURL:staging error:nil];
        BOOL written = data && [data writeToURL:staging options:NSDataWritingAtomic error:&error];
        if (written) {
            [files removeItemAtURL:file error:nil];
            written = [files moveItemAtURL:staging toURL:file error:&error];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != sg_generation) return;
            if (!written) {
                SGLog(@"lock lyrics: the lines not written for the add-on: %@", error.localizedDescription);
                sg_written = nil;
                notify_post(kSGRelayLockLyricsNone);
                return;
            }
            notify_post(kSGRelayLockLyrics);
            static int logged;
            if (logged++ < 4) SGLog(@"lock lyrics: %lu lines handed to the add-on", (unsigned long)lines.count);
        });
    });
}

// The clock as the state reports it, posted when it is not where the last one said it would be, or has not been for a while.
static void sendClock(SPTPlayerState *state, BOOL force) {
    if (!wanted() || !sg_track || !state) return;
    BOOL playing = !state.isPaused;
    double speed = state.playbackSpeed > 0 ? state.playbackSpeed : 1;
    // As SGKaraokePositionMs reads it, from the state reported.
    NSInteger ms = (NSInteger)llround((state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double expected = sg_clockMs + (sg_clockPlaying ? (now - sg_clockAt) * 1000 * sg_clockSpeed : 0);
    if (!force && sg_clockMs >= 0 && playing == sg_clockPlaying && speed == sg_clockSpeed && fabs(ms - expected) <= kClockSlackMs
        && now - sg_clockAt < kClockEvery) return;
    sg_clockMs = ms;
    sg_clockSpeed = speed;
    sg_clockPlaying = playing;
    sg_clockAt = now;
    if (!sg_clockToken && notify_register_check(kSGRelayLockLyricsClock, &sg_clockToken) != NOTIFY_STATUS_OK) return;
    notify_set_state(sg_clockToken, SGLockLyricsClock(ms, speed, playing, SGLockLyricsTag(sg_track)));
    notify_post(kSGRelayLockLyricsClock);
}

// While the song plays, its clock goes out at least every kClockEvery whether the player reports or not, so a
// MediaRemoteUI that starts meanwhile has one soon; stopped, the last one stands.
static void keepClock(BOOL playing) {
    if (!playing || !wanted()) {
        if (sg_clockTimer) dispatch_source_cancel(sg_clockTimer);
        sg_clockTimer = nil;
        return;
    }
    if (sg_clockTimer) return;
    sg_clockTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(sg_clockTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kClockEvery * NSEC_PER_SEC)),
                              (uint64_t)(kClockEvery * NSEC_PER_SEC), NSEC_PER_SEC);
    dispatch_source_set_event_handler(sg_clockTimer, ^{ sendClock(SGPlayerState(), NO); });
    dispatch_resume(sg_clockTimer);
}

// A new song: what the add-on draws holds while its lines come, and its clock starts over.
static void follow(SPTPlayerState *state) {
    NSString *track = SGKaraokePlayingTrack();
    keepClock(state && !state.isPaused);
    if (!wanted() || !track.length) return;
    if (![track isEqualToString:sg_track]) {
        sg_track = track;
        sg_written = nil;
        sg_generation++;
        notify_post(kSGRelayLockLyricsPending);
        sendClock(state, YES);
        offer(YES);
        return;
    }
    sendClock(state, NO);
}

@interface SGLockAddonLyrics : NSObject <SGPlayerStateObserver>
@end

@implementation SGLockAddonLyrics
// The playing song is read once every observer of this state has run, KaraokeSource's among them.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    dispatch_async(dispatch_get_main_queue(), ^{ follow(SGPlayerState()); });
}
// A report comes before the change it carries is heard: the first report of the next song would send its position
// under the last song's tag, so a report of another track leaves the clock to follow().
- (void)playerStateDidReport:(SPTPlayerState *)state {
    // The cheap test first: this comes on every report, also when nobody picked the lyrics.
    if (!wanted()) return;
    NSString *uri = SGURIString(state.track.URI);
    BOOL sameTrack = !uri || [uri isEqualToString:sg_reportedURI];
    sg_reportedURI = uri;
    if (sg_track && sameTrack) sendClock(state, NO);
}
@end

%ctor {
    if (@available(iOS 26.0, *)) return;
    sg_queue = dispatch_queue_create("spotifyglass.lockscreen.addon-lyrics", DISPATCH_QUEUE_SERIAL);
    static SGLockAddonLyrics *observer;
    observer = [SGLockAddonLyrics new];
    SGAddPlayerStateObserver(observer);
    // The button's choice: picked, the song playing is taken up; the Canvas back, the clock stops. Asked for as Spotify
    // starts, since SpringBoard tells it only as it changes or starts itself.
    static int lyricsToken, canvasToken;
    notify_register_dispatch(kSGRelayLockModeLyrics, &lyricsToken, dispatch_get_main_queue(), ^(int t) {
        if (sg_picked) return;
        sg_picked = YES;
        sg_wasWanted = wanted();
        sg_track = nil;
        follow(SGPlayerState());
    });
    notify_register_dispatch(kSGRelayLockModeCanvas, &canvasToken, dispatch_get_main_queue(), ^(int t) {
        sg_picked = NO;
        sg_wasWanted = NO;
        keepClock(NO);
    });
    // Asked now, and again each time the add-on answers Spotify's ping: an ask SpringBoard missed (it was restarting, or
    // came up after) is not left unanswered for the launch.
    dispatch_async(dispatch_get_main_queue(), ^{ notify_post(kSGRelayLockModeAsk); });
    [NSNotificationCenter.defaultCenter addObserverForName:SGHapticRelayAvailableNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ notify_post(kSGRelayLockModeAsk); });
    }];
    static int seekToken;
    notify_register_dispatch(kSGRelayLockLyricsSeek, &seekToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t position = 0;
        if (!wanted() || notify_get_state(t, &position) != NOTIFY_STATUS_OK) return;
        SGKaraokeSeek((NSInteger)position);
    });
    [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesKeptNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        // Posted on the main queue (Lyrics.h).
        if ([note.object isEqual:sg_track]) offer(NO);
    }];
    // Heard on the writing thread and handed to main without waiting (AGENTS.md): the switches turned on start with the
    // song playing, and a change of the look or the Lyrics page's settings writes the lines again.
    sg_wasWanted = wanted();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL now = wanted();
            BOOL turnedOn = now && !sg_wasWanted;
            sg_wasWanted = now;
            if (!now) return;
            if (turnedOn) {
                sg_track = nil;
                follow(SGPlayerState());
                return;
            }
            // Most writes are of something else: the lines are written again only for a look that moved.
            NSArray<SGKaraokeLine *> *lines = sg_track ? SGKaraokeLinesForTrack(sg_track) : nil;
            if (lines && sg_written && [lookFor(lines) isEqualToDictionary:sg_written[@"look"]]) return;
            offer(NO);
        });
    }];
}
