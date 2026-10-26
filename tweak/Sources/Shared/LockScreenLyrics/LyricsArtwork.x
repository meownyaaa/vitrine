// The lock screen's full-screen artwork as the lyrics, a clip per line (SGLyricsClip.h draws it). A timer
// works out the line being sung and hands the lock screen a new artwork under a new ID each time it
// changes. It wakes for the next time the line can change, and again for whatever else changes the
// artwork: a player state, the lines kept, the moving artwork handed over or failing, the phone's heat,
// the style. Nothing is drawn until the lock screen asks for that artwork's video, so lines sung with the
// screen off cost nothing. It rides on Spotify's now playing info as an extra (NowPlayingExtras.h), like
// the moving artwork it takes the place of.
//
// Moving artwork with lyrics draws the lines over the track's moving artwork instead, which
// LockScreenMotion.x finds and hands over (SGLyricsArtworkSetMotion): each line's clip is the stretch of it
// the song is at while the line shows, taken round its length, with the line sung last dimmed above. Until the
// clip comes, and for a track that has none, the lines are drawn as Lyrics draws them; the clip coming
// changes every ID, so the line showing is offered again over it.
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "SGLyricsClip.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/NowPlayingExtras.h"
#import "Shared/Player/PlayerState.h"

// How often to look while the line cannot be worked out yet.
static const NSTimeInterval kTick = 0.25;
// A line's clip over moving artwork lasts from the line's start to the next one's, a second longer for the
// lock screen showing it late, and between these: the cost of a clip is its length.
static const double kShortest = 2, kLongest = 8;

// What a line's artwork shows, kept by its request blocks.
@interface SGLockLine : NSObject
@property (nonatomic, copy) NSString *previous, *line, *next;   // nil for none
@property (nonatomic) UIImage *cover;
@property (nonatomic) SGLyricsClipStyle style;
@property (nonatomic) NSURL *motion;          // the moving artwork under the words, nil for the blurred cover
@property (nonatomic) double from, seconds;   // where in the song the clip starts and how long it is
@end

@implementation SGLockLine
@end

static dispatch_source_t sg_timer;
static CFAbsoluteTime sg_due;
// Where the song was, how fast it went and when, as the timer was armed: a report that strays from it is a seek.
static NSInteger sg_armedMs;
static double sg_armedSpeed;
static CFAbsoluteTime sg_armedAt;
// Lyrics are picked and the player is not paused: only then does the timer run.
static BOOL sg_running;
static void tick(void);

// Looks again on main, while the timer runs, for something other than the clock that changes the artwork.
static void tickSoon(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (sg_running) tick();
    });
}
static NSString *sg_motionURI;   // the track the moving artwork is for, and its file (SGLyricsArtworkSetMotion)
static NSURL *sg_motion;
// Paths of moving artwork that would not draw (turned, its frames another size than it states, cut short, or
// gone from the store), so each line goes straight to the cover; a file handed over again is tried again. Read
// on main and both queues, so only under its own lock.
static NSMutableSet<NSString *> *sg_failedMotion;

static BOOL motionFailed(NSURL *file) {
    @synchronized (sg_failedMotion) {
        return [sg_failedMotion containsObject:file.path];
    }
}

static void markMotionFailed(NSURL *file, NSString *artworkID) {
    @synchronized (sg_failedMotion) {
        if ([sg_failedMotion containsObject:file.path]) return;
        [sg_failedMotion addObject:file.path];
    }
    SGLog(@"lock lyrics: %@ would not draw for %@, the lines go over the cover for it", file.lastPathComponent, artworkID);
    tickSoon();
}
static NSString *sg_track;     // the track the clips are for
static UIImage *sg_cover;      // its cover, once Spotify's now playing info has one for it
static NSString *sg_shownID;   // the artwork handed over last, nil for none; read on sg_queue too
static NSObject *sg_lock;
static dispatch_queue_t sg_queue;   // writes the clips, one at a time
// Draws the previews, apart from the clips: one waiting behind a clip that takes seconds left the lock screen blank.
static dispatch_queue_t sg_previewQueue;

static NSURL *folder(void) {
    NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    return [caches URLByAppendingPathComponent:@"Vitrine/Lyrics" isDirectory:YES];
}

// The blurred cover, made once per cover and shared by both queues; the caller releases it.
static CGImageRef copyBackdropFor(UIImage *cover, CGSize size) {
    static id made;
    static CGImageRef backdrop;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized (lock) {
        id key = cover ?: NSNull.null;
        if (!backdrop || made != key) {
            CGImageRelease(backdrop);
            backdrop = SGLyricsClipBackdrop(cover.CGImage, size);
            made = key;
        }
        return CGImageRetain(backdrop);
    }
}

static BOOL stillShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        return [artworkID isEqualToString:sg_shownID];
    }
}

static void setShown(NSString *artworkID) {
    @synchronized (sg_lock) {
        sg_shownID = artworkID;
    }
}

// The lock screen's last asks, as absolute times: lines are drawn ahead only while it is showing them, previews and
// clips each by their own asks, as it asks for clips far less often.
static CFAbsoluteTime sg_askedAt, sg_previewAskedAt;
// Previews drawn ahead, by artwork ID.
static NSCache<NSString *, UIImage *> *sg_previews;

static NSURL *clipFile(NSString *artworkID) {
    return [folder() URLByAppendingPathComponent:[artworkID stringByAppendingPathExtension:@"mp4"]];
}

// On sg_previewQueue. Over moving artwork that will not read, the blurred cover's.
static UIImage *previewFor(NSString *artworkID, SGLockLine *line, CGSize size) {
    UIImage *preview = [sg_previews objectForKey:artworkID];
    if (preview) return preview;
    BOOL tryMotion = line.motion && !motionFailed(line.motion);
    CGImageRef frame = tryMotion ? SGLyricsClipMotionFrame(line.motion, line.previous, line.line, line.next, line.from) : NULL;
    if (tryMotion && !frame) markMotionFailed(line.motion, artworkID);
    if (!frame) {
        CGImageRef backdrop = copyBackdropFor(line.cover, size);
        frame = SGLyricsClipFrame(backdrop, line.line, line.next, size);
        CGImageRelease(backdrop);
    }
    if (frame) [sg_previews setObject:(preview = [UIImage imageWithCGImage:frame]) forKey:artworkID];
    CGImageRelease(frame);
    return preview;
}

// On sg_queue. A clip drawn ahead is found on disk and handed over at once. Over moving artwork that will not
// read, it is drawn over the blurred cover.
static BOOL writeClip(NSString *artworkID, SGLockLine *line, CGSize size) {
    NSURL *file = clipFile(artworkID);
    if ([NSFileManager.defaultManager fileExistsAtPath:file.path]) return YES;
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    BOOL tryMotion = line.motion && !motionFailed(line.motion);
    BOOL over = tryMotion && SGLyricsClipWriteOverMotion(file, line.motion, line.previous, line.line, line.next, line.from, line.seconds);
    if (tryMotion && !over) markMotionFailed(line.motion, artworkID);
    BOOL ok = over;
    if (!ok) {
        CGImageRef backdrop = copyBackdropFor(line.cover, size);
        ok = SGLyricsClipWrite(file, backdrop, line.line, line.next, size, line.style);
        CGImageRelease(backdrop);
    }
    // The first few of a launch of each kind, and any that fails: one a line would fill the log.
    static NSUInteger told[2];
    if (!ok || told[over]++ < 5) {
        SGLog(@"lock lyrics: %@ %@ in %.0f ms%@", artworkID, ok ? @"written" : @"not written", (CFAbsoluteTimeGetCurrent() - start) * 1000,
              over ? [NSString stringWithFormat:@", up to %.1f s of %@ from %.1f s", line.seconds, line.motion.lastPathComponent, line.from] : @"");
    }
    return ok;
}

// The next line's preview and clip, drawn while this one shows: a line change then hands both over at once, where
// drawing them on request left the lock screen on the plain cover for half a second.
static void drawAhead(NSString *artworkID, SGLockLine *line) {
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    if (time - sg_previewAskedAt <= 15) dispatch_async(sg_previewQueue, ^{ previewFor(artworkID, line, size); });
    if (time - sg_askedAt <= 15) dispatch_async(sg_queue, ^{ writeClip(artworkID, line, size); });
}

API_AVAILABLE(ios(26.0))
static MPMediaItemAnimatedArtwork *artworkFor(NSString *artworkID, SGLockLine *line) {
    CGSize size = SGLyricsClipSize(SGMotionPixels());
    return [[MPMediaItemAnimatedArtwork alloc] initWithArtworkID:artworkID
        previewImageRequestHandler:^(CGSize wanted, void (^completion)(UIImage *)) {
            sg_previewAskedAt = CFAbsoluteTimeGetCurrent();
            // One drawn ahead is handed over at once, as Apple asks of a preview; only a miss waits for drawing.
            UIImage *ready = [sg_previews objectForKey:artworkID];
            if (ready) {
                completion(ready);
                return;
            }
            dispatch_async(sg_previewQueue, ^{
                completion(previewFor(artworkID, line, size));
                static NSUInteger told;
                if (told++ < 10) SGLog(@"lock lyrics: preview of %@ was not drawn ahead", artworkID);
            });
        }
        videoAssetFileURLRequestHandler:^(CGSize wanted, void (^completion)(NSURL *)) {
            sg_askedAt = CFAbsoluteTimeGetCurrent();
            dispatch_async(sg_queue, ^{
                // A line already sung by the time its turn comes is not drawn.
                if (!stillShown(artworkID)) {
                    completion(nil);
                    return;
                }
                completion(writeClip(artworkID, line, size) ? clipFile(artworkID) : nil);
            });
        }];
}

static void clear(void) {
    if (!sg_shownID) return;
    setShown(nil);
    SGNowPlayingSetExtras(@"lyrics", nil, nil);
}

static NSString *textAt(NSArray<SGKaraokeLine *> *lines, NSInteger index) {
    return index >= 0 && index < (NSInteger)lines.count ? SGKaraokeLineText(lines[index]) : nil;
}

void SGLyricsArtworkSetMotion(NSString *uri, NSURL *file) {
    @synchronized (sg_failedMotion) {
        if (file) [sg_failedMotion removeObject:file.path];
    }
    sg_motionURI = uri;
    sg_motion = file;
    tickSoon();
}

// What the artwork for line `index` shows, `resting` once its break has come (index -1, before the first line,
// always rests). Over moving artwork, the stretch of song from when it shows until the next artwork does.
static SGLockLine *lineAt(NSArray<SGKaraokeLine *> *lines, NSInteger index, BOOL resting, NSURL *motion,
                          UIImage *cover, SGLyricsClipStyle style) {
    SGLockLine *shown = [SGLockLine new];
    // Resting, the line sung is let go and the one coming shows alone.
    shown.line = resting ? nil : textAt(lines, index);
    shown.next = textAt(lines, index + 1);
    shown.previous = motion && !resting ? textAt(lines, index - 1) : nil;
    shown.cover = cover;
    shown.style = style;
    shown.motion = motion;
    NSInteger start = index < 0 ? 0 : resting ? SGKaraokeSungEnd(lines[index]) + SGKaraokeBreakMs : lines[index].start;
    NSInteger end = index + 1 < (NSInteger)lines.count ? lines[index + 1].start
                  : index < 0 ? start : SGKaraokeSungEnd(lines[index]) + SGKaraokeBreakMs;
    shown.from = start / 1000.0;
    shown.seconds = MIN(MAX((end - start) / 1000.0 + 1, kShortest), kLongest);
    return shown;
}

// Offers the artwork for where the song is, and says in how many seconds of the song's time to look again:
// kTick while it cannot be worked out yet, negative for not until something else changes. Past a line's sung
// end by SGKaraokeBreakMs, with the next line at least that far off, the line rests: it is let go and only the
// next one shows, dimmed (as the artist row does in LockScreenLyrics.x).
static NSTimeInterval update(void) {
    if (@available(iOS 26.0, *)) {
        SPTPlayerState *state = SGPlayerState();
        NSString *trackID = SGKaraokePlayingTrack();
        if (!trackID || !state) {
            clear();
            return kTick;
        }
        if (![trackID isEqualToString:sg_track]) {
            sg_track = trackID;
            sg_cover = nil;
            // The IDs name the track, so the last track's clips are never asked for again.
            dispatch_async(sg_queue, ^{
                [NSFileManager.defaultManager removeItemAtURL:folder() error:nil];
                [NSFileManager.defaultManager createDirectoryAtURL:folder() withIntermediateDirectories:YES attributes:nil error:nil];
            });
        }
        NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
        if (!lines) SGKaraokeRequestLyrics(trackID);
        // Plain text has no line being sung, nor has a song whose lines are not in yet: the lock screen keeps the cover,
        // or under Moving artwork with lyrics shows the moving artwork plain (LockScreenMotion.x, which has it).
        if (!lines.count || SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) {
            static NSString *told;
            if (lines && ![told isEqualToString:trackID]) {
                told = trackID;
                SGLog(@"lock lyrics: %@ has no synced lines, the lock screen keeps the cover or the moving artwork", trackID);
            }
            clear();
            SGLockMotionShowPlain(YES);
            return lines ? -1 : kTick;
        }
        NSInteger position = SGKaraokePositionMs();
        if (position < 0) return kTick;
        position -= SGKaraokeDelayMs();
        NSInteger index = SGKaraokeLeadLine(lines, position);
        NSInteger ms = SGKaraokeMsToChange(lines, position, -1);
        // A ms on, past the truncation of the position.
        NSTimeInterval wait = ms > 0 ? (ms + 1) / 1000.0 : -1;
        BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > SGKaraokeBreakMs;
        BOOL resting = index < 0 || (position > SGKaraokeSungEnd(lines[index]) + SGKaraokeBreakMs && nextFarOff);
        SGLyricsClipStyle style = (SGLyricsClipStyle)SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
        NSURL *motion = SGLockScreenArtwork() == SGLockArtworkMotionLyrics && [sg_motionURI isEqualToString:SGURIString(state.track.URI)]
            ? sg_motion : nil;
        if (motion && motionFailed(motion)) motion = nil;
        // A line over moving artwork decodes and encodes up to 240 frames, one over the cover a still frame: a phone
        // already hot gets the cover, as Sing.x keeps its model below Serious, and the motion back once it cools.
        if (motion && NSProcessInfo.processInfo.thermalState >= NSProcessInfoThermalStateSerious) {
            static CFAbsoluteTime told;
            if (CFAbsoluteTimeGetCurrent() - told > 60) SGLog(@"lock lyrics: the phone is hot, the lines go over the cover");
            told = CFAbsoluteTimeGetCurrent();
            motion = nil;
        }
        NSString *look = SGLyricsClipLook(motion, style);
        NSString *artworkID = [NSString stringWithFormat:@"%@-%ld%@-%@", trackID, (long)index, resting ? @"r" : @"", look];
        if ([artworkID isEqualToString:sg_shownID]) return wait;
        // Spotify's request block for its cover, read on main and kept once it is this track's.
        if (!sg_cover) {
            NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
            MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
            if ([info[MPMediaItemPropertyTitle] isEqual:state.track.trackTitle] && [artwork isKindOfClass:MPMediaItemArtwork.class]) {
                sg_cover = [artwork imageWithSize:CGSizeMake(600, 600)];
            }
        }
        if (![sg_shownID hasPrefix:trackID]) SGLog(@"lock lyrics: lines offered for %@", trackID);
        if (motion && ![sg_shownID hasSuffix:[@"-" stringByAppendingString:look]]) SGLog(@"lock lyrics: the lines of %@ over %@", trackID, motion.lastPathComponent);
        setShown(artworkID);
        SGLockMotionShowPlain(NO);
        SGNowPlayingSetExtras(@"lyrics", @{MPNowPlayingInfoProperty3x4AnimatedArtwork:
                                               artworkFor(artworkID, lineAt(lines, index, resting, motion, sg_cover, style))},
                              state.track.trackTitle);
        if (index + 1 < (NSInteger)lines.count) {
            NSString *ahead = [NSString stringWithFormat:@"%@-%ld-%@", trackID, (long)index + 1, look];
            drawAhead(ahead, lineAt(lines, index + 1, NO, motion, sg_cover, style));
        }
        return wait;
    }
    return -1;
}

static void stopTicking(void) {
    if (sg_timer) dispatch_source_cancel(sg_timer);
    sg_timer = nil;
}

// Main thread, as everything the timer touches is. Offers the artwork for now and, while sg_running, arms the
// timer for the next look; else stops it.
static void tick(void) {
    NSTimeInterval wait = update();
    if (!sg_running || wait < 0) {
        stopTicking();
        return;
    }
    if (!sg_timer) {
        // A strict GCD timer: the main run loop's timers are throttled while the screen is off, and the lines stood
        // still on a locked phone.
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sg_timer, ^{
            static int late;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - sg_due > 2 && late++ < 5) SGLog(@"%s: ticked %.1f s late", __FILE_NAME__, now - sg_due);
            tick();
        });
        dispatch_resume(sg_timer);
    }
    double speed = SGPlayerState().playbackSpeed;
    NSTimeInterval seconds = wait / (speed > 0 ? speed : 1);
    sg_armedMs = SGKaraokePositionMs();
    sg_armedSpeed = speed;
    sg_armedAt = CFAbsoluteTimeGetCurrent();
    sg_due = sg_armedAt + seconds;
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
}

@interface SGLyricsArtwork : NSObject <SGPlayerStateObserver>
@end

@implementation SGLyricsArtwork
// A paused player's line does not move, and the lock screen keeps the clip it was left on. Picked or not is read
// each time, so a change on the Lock screen page applies at once.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL on = SGLockArtworkShowsLyrics(SGLockScreenArtwork());
    sg_running = on && !state.isPaused;
    if (on) tick();
    else {
        stopTicking();
        clear();
    }
}
// A seek, or a new speed, moves the next change; a report where the song is where it was headed does not.
- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (!sg_running) return;
    double speed = sg_armedSpeed > 0 ? sg_armedSpeed : 1;
    double expected = sg_armedMs + (CFAbsoluteTimeGetCurrent() - sg_armedAt) * 1000 * speed;
    // As SGKaraokePositionMs reads it, from the state reported.
    double position = (state.isPaused ? state.positionAsOfTimestamp : state.position) * 1000;
    // An unknown position is looked at kTick anyway.
    if (!sg_timer || (sg_armedMs >= 0 && (state.playbackSpeed != sg_armedSpeed || fabs(position - expected) > 500))) tick();
}
@end

%ctor {
    if (@available(iOS 26.0, *)) {
        sg_lock = [NSObject new];
        sg_queue = dispatch_queue_create("spotifyglass.lockscreen.lyrics", DISPATCH_QUEUE_SERIAL);
        sg_previewQueue = dispatch_queue_create("spotifyglass.lockscreen.lyrics.preview", DISPATCH_QUEUE_SERIAL);
        sg_previews = [NSCache new];
        sg_failedMotion = [NSMutableSet set];
        sg_previews.countLimit = 4;
        static SGLyricsArtwork *observer;
        observer = [SGLyricsArtwork new];
        SGAddPlayerStateObserver(observer);
        // Every write in the app posts this, so the settings are compared on the writing thread and handed to main
        // without waiting only when one moved (AGENTS.md).
        static SGLockArtwork choice;
        static NSInteger style, delay;
        choice = SGLockScreenArtwork();
        style = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill);
        delay = SGKaraokeDelayMs();
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            // The style and the lyrics' delay apply at once, and move the artwork or its next change.
            SGPrefsChanged();
            NSInteger nowStyle = SGInt(SGKeyLockScreenLyricsStyle, SGLyricsClipStill), nowDelay = SGKaraokeDelayMs();
            if (nowStyle != style || nowDelay != delay) {
                style = nowStyle;
                delay = nowDelay;
                tickSoon();
            }
            SGLockArtwork picked = SGLockScreenArtwork();
            if (picked == choice) return;
            choice = picked;
            dispatch_async(dispatch_get_main_queue(), ^{
                SGLog(@"lock lyrics: %@", !SGLockArtworkShowsLyrics(picked) ? @"no longer picked" : picked == SGLockArtworkLyrics ? @"picked" : @"picked over the moving artwork");
                [observer playerStateDidChange:SGPlayerState()];
            });
        }];
        // Lines kept for the track, or better timed ones in their place, are posted on main.
        [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesKeptNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            if (sg_running) tick();
        }];
        // A hot phone puts the lines over the cover, and they go back over the motion once it cools.
        [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { tickSoon(); }];
        SGLog(@"lock lyrics: %@, the lock screen takes %@", !SGLockArtworkShowsLyrics(choice) ? @"off" : choice == SGLockArtworkLyrics ? @"on" : @"on over the moving artwork",
              MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys);
    }
}
