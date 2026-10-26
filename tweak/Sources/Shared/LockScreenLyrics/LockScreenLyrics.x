// Spotify's now playing info passes through with the artist swapped for the current line, and a timer
// sends it again each time the line changes. Spotify itself only ever sees its own dictionary back.
//
// The timer runs only while the sound moves, and wakes once for the next time the line can change: the
// next start or end of a line or word the line shown hangs on. While the lyrics or the player's track
// are not in yet it looks four times a second. The lock screen keeps the line it was left on until the
// sound starts again.
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "LockScreenLyrics.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Headers/SPTPlayer.h"

// How often to look while the line cannot be worked out yet.
static const NSTimeInterval kTick = 0.25;
// About what the lock screen's artist row fits before it cuts the text off.
static const NSUInteger kMaxChars = 30;

// Spotify may set the info from any thread; the timer reads it on the main one.
static NSObject *sg_lock;
static NSDictionary *sg_spotifyInfo;
static CFAbsoluteTime sg_spotifyInfoAt;
static NSString *sg_shownLine;
static BOOL sg_resending;
static dispatch_source_t sg_timer;
static CFAbsoluteTime sg_due;
// SGKeyLockScreenTranslation, read at launch.
static BOOL sg_translation;

static NSString *textOf(NSArray<SGKaraokeWord *> *words) {
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    return SGKaraokeLineText(line);
}

// A line longer than the artist row holds, split into even pieces rather than a full one and a stub.
// Each piece shows from its first word's estimated start.
static NSArray<NSArray<SGKaraokeWord *> *> *piecesOf(SGKaraokeLine *line) {
    NSUInteger length = textOf(line.words).length;
    NSUInteger count = MAX((length + kMaxChars - 1) / kMaxChars, 1);
    NSUInteger target = (length + count - 1) / count;
    NSMutableArray<NSArray<SGKaraokeWord *> *> *pieces = [NSMutableArray array];
    NSMutableArray<SGKaraokeWord *> *piece = [NSMutableArray array];
    NSUInteger pieceLength = 0;
    for (SGKaraokeWord *word in line.words) {
        NSUInteger gap = pieceLength && !word.joined ? 1 : 0;
        NSUInteger withWord = pieceLength ? pieceLength + gap + word.text.length : word.text.length;
        if (pieceLength && (withWord > kMaxChars || (withWord > target && pieces.count + 1 < count))) {
            [pieces addObject:piece];
            piece = [NSMutableArray array];
            withWord = word.text.length;
        }
        [piece addObject:word];
        pieceLength = withWord;
    }
    if (piece.count) [pieces addObject:piece];
    return pieces;
}

static char kTranslatedKey;

// A line's translation as a line of its own, its words' times estimated over the line's, so piecesOf splits it
// by its own length and its pieces turn over at the line's wakes. Made once for each translation the line has.
static SGKaraokeLine *translatedLine(SGKaraokeLine *line) {
    NSString *translation = line.translation;
    if (!translation.length) return nil;
    NSArray *made = objc_getAssociatedObject(line, &kTranslatedKey);
    if (made.firstObject != translation) {
        SGKaraokeLine *translated = SGKaraokeEstimatedLines(@[@(line.start), @(MAX(line.end, line.start))], @[translation, @""]).firstObject;
        made = @[translation, translated ?: NSNull.null];
        objc_setAssociatedObject(line, &kTranslatedKey, made, OBJC_ASSOCIATION_RETAIN);
    }
    return made.lastObject == NSNull.null ? nil : made.lastObject;
}

// Seconds into the track at `now`, run on from what Spotify last reported. A rate it left out runs at 1, as
// playingBy counts it: read as 0, every line written pinned the lock screen's time to Spotify's last report.
static double elapsedAt(NSDictionary *info, CFAbsoluteTime reportedAt, CFAbsoluteTime now) {
    NSNumber *reported = info[MPNowPlayingInfoPropertyPlaybackRate];
    double rate = reported ? reported.doubleValue : 1;
    return [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue] + rate * (now - reportedAt);
}

// nil between lines and for a track without synced lyrics, plain text included. Past a line's end by
// SGKaraokeBreakMs, with the next line at least that far off, the artist comes back. With translations on, a
// line that has one shows it instead. `wait` is the playback time in seconds until it can change: kTick while it
// cannot be worked out yet, negative for not again.
static NSString *lineFor(NSDictionary *info, double elapsed, NSTimeInterval *wait) {
    *wait = kTick;
    SPTPlayerState *state = [(id<SPTPlayer>)SGKaraokePlayer() state];
    // The player's track can lag behind the now playing info; its lyrics would then be another song's.
    if (![state.track.trackTitle isEqualToString:info[MPMediaItemPropertyTitle]]) return nil;
    NSString *trackID = SGKaraokePlayingTrack();
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        return nil;
    }
    *wait = -1;
    // Plain text has no line being sung to show.
    if (SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) return nil;
    NSInteger position = (NSInteger)(elapsed * 1000) - SGKaraokeDelayMs();
    NSInteger index = SGKaraokeLeadLine(lines, position);
    // The pieces below turn over at the shown line's word starts.
    NSInteger ms = SGKaraokeMsToChange(lines, position, index);
    // A ms on, past the truncation of `position` above.
    if (ms > 0) *wait = (ms + 1) / 1000.0;
    if (index < 0) return nil;
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > SGKaraokeBreakMs;
    if (position > lines[index].end + SGKaraokeBreakMs && nextFarOff) return nil;
    SGKaraokeLine *line = (sg_translation ? translatedLine(lines[index]) : nil);
    if (!line && SGFlag(SGKeyLyricsRomanised, NO) && SGFlag(SGKeyLyricsRomanisedReplace, NO)) {
        line = SGLyricsRomanisedLine(lines[index], SGLyricsLooksJapanese(lines));
    }
    if (!line) line = lines[index];
    NSString *shown = nil;
    for (NSArray<SGKaraokeWord *> *piece in piecesOf(line)) {
        NSInteger pieceStart = piece.firstObject.start;
        if (!shown || pieceStart <= position) {
            shown = textOf(piece);
        } else if (pieceStart > position && (ms <= 0 || pieceStart - position < ms)) {
            ms = pieceStart - position;
            *wait = (ms + 1) / 1000.0;
        }
    }
    return shown;
}

// Spotify's info with the line in place of the artist, or its own artist for nil. The clock always moves
// on to `elapsed`: the system takes the elapsed time as now's, so the one Spotify reported a while ago
// would pull the progress bar back.
static NSDictionary *withLine(NSDictionary *info, NSString *line, double elapsed) {
    NSMutableDictionary *shown = [info mutableCopy];
    if (line) shown[MPMediaItemPropertyArtist] = line;
    shown[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsed);
    return shown;
}

// The rate the song's time moves at; 1 for one Spotify left out, as elapsedAt counts it.
static double rateOf(NSDictionary *info) {
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    return rate.doubleValue > 0 ? rate.doubleValue : 1;
}

static void tick(void);

// Main thread, as everything the timer touches is. Stops the timer, or arms it to look again `wait`
// seconds of the song's time from now; a negative wait leaves it to Spotify's next info.
static void lookIn(NSTimeInterval wait, NSDictionary *info) {
    if (wait < 0) {
        if (sg_timer) dispatch_source_cancel(sg_timer);
        sg_timer = nil;
        return;
    }
    if (!sg_timer) {
        // A strict GCD timer: the main run loop's timers are throttled while the screen is off, and the lines
        // stood still on a locked phone.
        sg_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, DISPATCH_TIMER_STRICT, dispatch_get_main_queue());
        dispatch_source_set_event_handler(sg_timer, ^{
            static int late;
            CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
            if (now - sg_due > 2 && late++ < 5) SGLog(@"%s: ticked %.1f s late", __FILE_NAME__, now - sg_due);
            tick();
        });
        dispatch_resume(sg_timer);
    }
    NSTimeInterval seconds = wait / rateOf(info);
    sg_due = CFAbsoluteTimeGetCurrent() + seconds;
    dispatch_source_set_timer(sg_timer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
}

static void tick(void) {
    NSDictionary *info;
    CFAbsoluteTime reportedAt;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
        reportedAt = sg_spotifyInfoAt;
    }
    if (!info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = elapsedAt(info, reportedAt, now);
    NSTimeInterval wait;
    NSString *line = lineFor(info, elapsed, &wait);
    lookIn(wait, info);
    if (line == sg_shownLine || [line isEqualToString:sg_shownLine]) return;
    sg_shownLine = line;
    sg_resending = YES;
    MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo = withLine(info, line, elapsed);
    sg_resending = NO;
}

// Whether the sound is moving. A rate Spotify did not report at all counts as moving: the line would
// stand still either way, and a missing key is no reason to leave the feature switched off for good.
static BOOL playingBy(NSDictionary *info) {
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    return !rate || rate.doubleValue > 0;
}

// Looks again at once while the sound moves, for something other than the clock that moves the line.
static void lookNow(void) {
    NSDictionary *info;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
    }
    if (playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) lookIn(0, info);
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    if (sg_resending) {
        %orig;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    @synchronized (sg_lock) {
        sg_spotifyInfo = info;
        sg_spotifyInfoAt = now;
    }
    BOOL playing = playingBy(info) && info[MPNowPlayingInfoPropertyElapsedPlaybackTime] != nil;
    // Karaoke's lyrics are main-thread state; off it the info goes out as it is and a tick at once adds the line.
    if (!NSThread.isMainThread || !info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            sg_shownLine = nil;
            lookIn(playing ? 0 : -1, info);
        });
        %orig;
        return;
    }
    double elapsed = elapsedAt(info, now, now);
    NSTimeInterval wait;
    NSString *line = lineFor(info, elapsed, &wait);
    lookIn(playing ? wait : -1, info);
    sg_shownLine = line;
    %orig(withLine(info, line, elapsed));
}

- (NSDictionary *)nowPlayingInfo {
    NSDictionary *info;
    @synchronized (sg_lock) {
        info = sg_spotifyInfo;
    }
    return info ?: %orig;
}
%end

%ctor {
    if (!SGFlag(SGKeyLockScreenLyrics, NO)) return;
    sg_lock = [NSObject new];
    sg_translation = SGFlag(SGKeyLockScreenTranslation, NO);
    %init;
    // Lines kept for a track, or replaced by better timed ones, can change the line at once.
    [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesKeptNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
        lookNow();
    }];
    // The lyrics' delay applies at once, and moves the next change. Every write in the app posts this, so it is
    // compared on the writing thread and handed to main without waiting only when it moved (AGENTS.md).
    static NSInteger delay;
    delay = SGKaraokeDelayMs();
    [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        SGPrefsChanged();
        NSInteger now = SGKaraokeDelayMs();
        if (now == delay) return;
        delay = now;
        dispatch_async(dispatch_get_main_queue(), ^{ lookNow(); });
    }];
    // The timer waits for Spotify to report a playing track; nothing before that has a line to show.
    SGLog(@"lock screen lyrics: on%@", sg_translation ? @", translations" : @"");
}
