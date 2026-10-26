// Polls the player and sends the activity a new state only when what its view shows changes: the
// lyrics' line, what is up next, the control menu's tab, track, shuffle, repeat or sleep timer, or a
// pause. The view is read on every tick, so picking another one shows within a tick. Spotify keeps
// playing in the background, so the timer keeps running there too. The sleep timer is
// Shared/Player/SleepTimer's, which keeps its own time; the card only sets it and shows it.
// The activity is started only while the app is in front, the one place ActivityKit allows it.
//
// The shortcuts (LiveActivityShared.swift's SGShortcutNotification) are answered here too, with the
// activity on or off: the control menu's actions, the like, Sing, and the same sleep timer, whose own clock
// runs whether anything here ticks or not.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SleepTimer.h"
#import "Headers/SPTPlayer.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/HeadGestures/HeadGestures.h"
#import "Shared/Sing/Sing.h"
#import "LiveActivity.h"

API_AVAILABLE(ios(17.0))
@interface SGLiveActivityBridge : NSObject
@property (class, nonatomic, readonly) BOOL isShowing;
@property (class, nonatomic, readonly) NSDate *startedAt;
@property (class, nonatomic, readonly) BOOL canStart;
+ (void)showWithView:(NSInteger)view paused:(BOOL)paused line:(NSString *)line nextLine:(NSString *)nextLine
              titles:(NSArray<NSString *> *)titles artists:(NSArray<NSString *> *)artists uris:(NSArray<NSString *> *)uris
                 tab:(NSInteger)tab title:(NSString *)title artist:(NSString *)artist shuffle:(BOOL)shuffle repeatMode:(NSInteger)repeatMode
            timerEnd:(NSDate *)timerEnd timerEndOfTrack:(BOOL)timerEndOfTrack timerEndOfAlbum:(BOOL)timerEndOfAlbum
                tint:(NSString *)tint trackStart:(NSDate *)trackStart trackEnd:(NSDate *)trackEnd pausedAt:(NSNumber *)pausedAt
         translation:(NSString *)translation cover:(NSData *)cover textSize:(NSInteger)textSize
           alignment:(NSInteger)alignment noLyrics:(BOOL)noLyrics withoutLyrics:(NSInteger)withoutLyrics
             colors:(NSInteger)colors accent:(NSString *)accent progressBar:(BOOL)progressBar;
+ (void)end;
+ (void)endBeforeExit;
@end

// The control menu's tabs, SGLyricsAttributes.Tab's values.
typedef NS_ENUM(NSInteger, SGLiveActivityTab) {
    SGLiveActivityTabControls = 0,
    SGLiveActivityTabQueue,
    SGLiveActivityTabTimer,
};

static const NSTimeInterval kTick = 0.25;
// Paused, or in a view without lyrics, the only thing on the card that moves by itself is the sleep timer
// (the bar runs from its dates), and a slower tick shows
// its end well within the second the card shows. Four ticks a second for a still card is a wake up
// eighty times a minute for a picture that does not change.
static const NSTimeInterval kPausedTick = 1;
// Past a line's sung end by this much, with the next line at least this far off, the line gives way to a note.
static const NSInteger kBreakMs = 4000;
// Seconds between attempts to start one, so a refused request (activities turned off) is not retried every tick.
static const NSTimeInterval kStartRetry = 10;
// A card that has not changed for this long is sent again, so its stale date (the bridge's staleAfter,
// three times this) keeps moving on while Spotify runs, and runs out only once Spotify is gone.
static const NSTimeInterval kRefresh = 20;
// iOS ends a card 8 h after it starts and leaves it frozen on the lock screen for up to 4 h more. With Spotify in
// front, a card older than kRenewAfter (or of unknown age) is swapped for a fresh one; in the
// background, where none can start, the card is ended at kEndAfter, just short of the 8 h, so it goes rather than freezes.
static const NSTimeInterval kRenewAfter = 60 * 60;
static const NSTimeInterval kEndAfter = 8 * 60 * 60 - 5 * 60;
// Tracks up next: the queue view shows three on the lock screen and in the Dynamic Island, the
// control menu's queue tab three.
static const NSUInteger kUpNextQueue = 3;
static const NSUInteger kUpNextPanel = 3;
// The cover goes to the card in the state itself, which ActivityKit caps at 4 KB with everything else in
// it and encodes as JSON, the cover in base64: this many bytes of JPEG come to about 1.9 KB of it.
static const NSUInteger kCoverBytes = 1400;
// A new state takes about this long to show on the card, so the line is picked this far ahead and
// lands as it is sung rather than a beat after.
static const NSInteger kRenderLeadMs = 800;
// A track start this close to the one sent is the same start, rounded the other way.
static const NSTimeInterval kStartSlack = 1.5;
// The card's background is at most this light, as relative luminance (about #383838), so every white on
// it keeps 4.5:1: the dimmest, at 0.6, comes to about 5.3:1 there, the line itself over 11:1.
static const double kTintLuminance = 0.04;
// Colors' Artwork accent is at least this light, as relative luminance: about Spotify's green's, so a lit chip
// reads as well as it does in Spotify's colors, and text in it keeps over 5:1 on the lightest card,
// (0.48 + 0.05) / (0.04 + 0.05).
static const double kAccentLuminance = 0.48;

static NSTimer *sg_timer;
static NSTimeInterval sg_tickEvery;
static NSString *sg_shown;
static NSArray *sg_shownFields;   // the fields sg_shown was built from, as read
static NSString *sg_missingLyrics;
// The tracks whose look for lyrics ended (SGKaraokeLinesKeptNotification), with lines or without: a set, since
// the track up next is looked up too, ahead of the one playing.
// ponytail: grows by one short ID a track for the session; clear it on a track change if that ever matters.
static NSMutableSet<NSString *> *sg_lookEnded;
static NSDate *sg_lastStart;
static NSDate *sg_lastSent;
static SGLiveActivityTab sg_tab;

static void tick(void) API_AVAILABLE(ios(17.0));
// When ActivityKit last said none is showing, with the app in the background; until kRefresh on, nothing is sent.
static NSDate *sg_noneAt;

// In the background with none showing, as ActivityKit said within kRefresh: send() sends nothing.
static BOOL heldBack(void) {
    return sg_noneAt && -sg_noneAt.timeIntervalSinceNow < kRefresh
        && UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
}

// An NSTimer cannot be asked to change pace, so changing it is putting one down and another up.
static void startTimer(NSTimeInterval every) API_AVAILABLE(ios(17.0)) {
    [sg_timer invalidate];
    sg_tickEvery = every;
    sg_timer = [NSTimer timerWithTimeInterval:every repeats:YES block:^(NSTimer *t) { tick(); }];
    [NSRunLoop.mainRunLoop addTimer:sg_timer forMode:NSRunLoopCommonModes];
}

// Sends `shown`, what the activity is to show as one string, unless it is showing that already and was
// sent within kRefresh; starts the activity when there is none and the app is in front.
static void send(NSString *shown, NSArray *fields, void (^show)(void)) API_AVAILABLE(ios(17.0)) {
    // ActivityKit is asked only when there is something to send: each question is a round trip to the system,
    // and this runs four times a second. An activity ended from outside is started again within kRefresh.
    if ([shown isEqualToString:sg_shown] && -sg_lastSent.timeIntervalSinceNow < kRefresh) return;
    if (heldBack()) return;
    sg_noneAt = nil;
    BOOL background = UIApplication.sharedApplication.applicationState != UIApplicationStateActive;
    BOOL showing = SGLiveActivityBridge.isShowing;
    NSDate *started = showing ? SGLiveActivityBridge.startedAt : nil;
    NSTimeInterval age = started ? -started.timeIntervalSinceNow : 0;
    // In front, only when a fresh one can start: activities turned off since would leave none.
    if (showing && (background ? age > kEndAfter : (!started || age > kRenewAfter) && SGLiveActivityBridge.canStart)) {
        SGLog(@"live activity: %.0f min old, %@", age / 60, background ? @"ended before iOS freezes it" : @"started again");
        [SGLiveActivityBridge end];
        sg_lastStart = nil;
        showing = NO;
    }
    if (!showing) {
        if (background) {
            // Nothing to send to, and none can start in the background: asked again after kRefresh.
            static NSUInteger told;
            if (told++ < 5) SGLog(@"live activity: none showing, not sent in the background");
            sg_noneAt = [NSDate date];
            return;
        }
        if (sg_lastStart && -sg_lastStart.timeIntervalSinceNow < kStartRetry) return;
        sg_lastStart = [NSDate date];
    }
    sg_shown = shown;
    sg_shownFields = fields;
    sg_lastSent = [NSDate date];
    show();
}

// A track's URI as a string; the player hands out NSURL or NSString.
static NSString *uriOf(SPTPlayerTrack *track) {
    id uri = track.URI;
    if ([uri isKindOfClass:NSURL.class]) return [(NSURL *)uri absoluteString];
    return [uri isKindOfClass:NSString.class] ? uri : nil;
}

// The state's tracks up next, skipping what is not a track or has no title or URI.
static NSArray<SPTPlayerTrack *> *upNext(SPTPlayerState *state) {
    NSMutableArray<SPTPlayerTrack *> *tracks = [NSMutableArray array];
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    for (id track in [future isKindOfClass:NSArray.class] ? future : @[]) {
        if (![track isKindOfClass:objc_getClass("SPTPlayerTrack")]) continue;
        if (![(SPTPlayerTrack *)track trackTitle].length || !uriOf(track)) continue;
        [tracks addObject:track];
    }
    return tracks;
}

// 0 off, 1 the playlist or album, 2 the track.
static NSInteger repeatModeOf(SPTPlayerOptions *options) {
    return options.repeatingTrack ? 2 : options.repeatingContext ? 1 : 0;
}

// The line being sung and the one after it; before the first line, between lines and without lyrics
// at all, a note holds the place. `none` says the track has no timed lines to follow, no lyrics or plain text,
// and only once a look for them has ended and no other is under way: a look that never ends, as with
// EeveeSpotify answering the lyrics, leaves the track in the note's place without the line saying so.
static NSString *lyricsLine(NSString *trackID, NSString **next, NSString **translation, BOOL *none) {
    NSArray<SGKaraokeLine *> *lines = SGKaraokeLinesForTrack(trackID);
    if (!lines) {
        SGKaraokeRequestLyrics(trackID);
        if (trackID && ![trackID isEqualToString:sg_missingLyrics]) {
            sg_missingLyrics = trackID;
            SGLog(@"live activity: no lyrics yet for %@", trackID);
        }
    }
    // Plain text has no line being sung: the note, as for a track with no lyrics.
    if (lines && SGKaraokeLinesTiming(lines) == SGKaraokeTimingNone) lines = nil;
    *none = !lines && [sg_lookEnded containsObject:trackID] && !SGKaraokeLooking(trackID);
    NSInteger position = SGKaraokePositionMs();
    if (position >= 0 && !SGPlayerState().isPaused) position += kRenderLeadMs;
    if (position >= 0) position -= SGKaraokeDelayMs();
    // With two voices at once, the one that came in first, and the one singing over it as the next.
    NSInteger index = SGKaraokeLeadLine(lines, position);
    BOOL replace = SGFlag(SGKeyLyricsRomanised, NO) && SGFlag(SGKeyLyricsRomanisedReplace, NO);
    BOOL japanese = replace && SGLyricsLooksJapanese(lines);
    if (index + 1 < (NSInteger)lines.count) {
        SGKaraokeLine *nextLine = lines[index + 1];
        if (replace) nextLine = SGLyricsRomanisedLine(nextLine, japanese) ?: nextLine;
        *next = SGKaraokeLineText(nextLine);
    } else {
        *next = @"";
    }
    if (index < 0) return @"♪";
    SGKaraokeLine *current = lines[index];
    if (replace) current = SGLyricsRomanisedLine(current, japanese) ?: current;
    BOOL nextFarOff = index + 1 == (NSInteger)lines.count || lines[index + 1].start - position > kBreakMs;
    if (position > current.end + kBreakMs && nextFarOff) return @"♪";
    *translation = current.translation;
    return SGKaraokeLineText(current);
}

// The cover for the card, read once a track from Spotify's now playing artwork: its color, darkened so
// white text keeps its contrast, and a small JPEG of it. At a track change the player moves a moment
// before Spotify hands over the new artwork, so it is read only once the now playing title is the
// track's (as Shared/LockScreenLyrics/LyricsArtwork.x does); until then the last track's stays. Spotify
// hands over a placeholder first and the cover after it, a new artwork object each time, so a new
// object for the same track is read again.
static NSString *sg_artTrack, *sg_tint, *sg_accent;
static NSData *sg_cover;
static __weak id sg_artObject;

// The cover at the largest of a few sizes whose JPEG fits kCoverBytes, drawn in device RGB so no color
// profile rides along; nil when none fits.
static NSData *coverJPEG(CGImageRef image) {
    for (NSNumber *side in @[@56, @48, @40, @32]) {
        size_t pixels = side.unsignedIntegerValue;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(NULL, pixels, pixels, 8, 0, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
        CGColorSpaceRelease(space);
        if (!context) return nil;
        CGContextSetInterpolationQuality(context, kCGInterpolationHigh);
        CGContextDrawImage(context, CGRectMake(0, 0, pixels, pixels), image);
        CGImageRef small = CGBitmapContextCreateImage(context);
        CGContextRelease(context);
        NSData *data = small ? UIImageJPEGRepresentation([UIImage imageWithCGImage:small], 0.5) : nil;
        CGImageRelease(small);
        if (data.length && data.length <= kCoverBytes) return data;
    }
    return nil;
}

// A channel of 0 to 255 as light, the sRGB curve undone.
static double linear(double channel) {
    channel /= 255;
    return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4);
}

// The card's background, RRGGBB: at most 0.55 of the cover's color, the rest black, and darker still
// until it is no lighter than kTintLuminance. At a fixed 0.55 a white or yellow cover came out #8C8C8C.
static NSString *tintOf(double red, double green, double blue) {
    double keep = 0.55;
    while (keep > 0 && 0.2126 * linear(red * keep) + 0.7152 * linear(green * keep) + 0.0722 * linear(blue * keep) > kTintLuminance) keep -= 0.01;
    keep = MAX(keep, 0);
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)(red * keep), (int)(green * keep), (int)(blue * keep)];
}

// Colors' Artwork accent, RRGGBB: the cover's color mixed with white until it is at least kAccentLuminance.
static NSString *accentOf(double red, double green, double blue) {
    double white = 0;
    while (white < 1 && 0.2126 * linear(red + (255 - red) * white) + 0.7152 * linear(green + (255 - green) * white)
                        + 0.0722 * linear(blue + (255 - blue) * white) < kAccentLuminance) white += 0.02;
    white = MIN(white, 1);
    return [NSString stringWithFormat:@"%02X%02X%02X", (int)(red + (255 - red) * white), (int)(green + (255 - green) * white),
            (int)(blue + (255 - blue) * white)];
}

static void readArtwork(SPTPlayerState *state, NSString *trackID) {
    if (!trackID) return;
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    if (![info[MPMediaItemPropertyTitle] isEqual:state.track.trackTitle]) return;
    MPMediaItemArtwork *artwork = info[MPMediaItemPropertyArtwork];
    if ([trackID isEqualToString:sg_artTrack] && artwork == sg_artObject) return;
    sg_artObject = artwork;
    UIImage *image = [artwork isKindOfClass:MPMediaItemArtwork.class] ? [artwork imageWithSize:CGSizeMake(64, 64)] : nil;
    if (!image.CGImage) return;
    unsigned char pixel[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixel, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, 1, 1), image.CGImage);
    CGContextRelease(context);
    sg_artTrack = trackID;
    sg_tint = tintOf(pixel[0], pixel[1], pixel[2]);
    sg_accent = accentOf(pixel[0], pixel[1], pixel[2]);
    sg_cover = coverJPEG(image.CGImage);
    static int logged;
    if (logged++ < 6) SGLog(@"live activity: cover of %@, %lu bytes", trackID, (unsigned long)sg_cover.length);
}

static void tick(void) API_AVAILABLE(ios(17.0)) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    SPTPlayerTrack *track = state.track;
    if (!track.trackTitle.length) return;
    NSString *trackID = SGKaraokePlayingTrack();

    NSInteger view = SGInt(SGKeyLiveActivityView, SGLiveActivityLyrics);
    BOOL paused = state.isPaused;
    // Only the lyrics follow the song line by line; the other views' bar runs by itself from its dates.
    NSTimeInterval every = paused || view != SGLiveActivityLyrics ? kPausedTick : kTick;
    if (sg_timer && sg_tickEvery != every) startTimer(every);
    // send() would send nothing yet, so nothing is worked out for it.
    // The lyrics are still asked for, so they are there when it sends again.
    if (heldBack()) {
        if (view == SGLiveActivityLyrics && !SGKaraokeLinesForTrack(trackID)) SGKaraokeRequestLyrics(trackID);
        return;
    }
    NSString *line = @"", *next = @"", *translation = nil;
    BOOL noLyrics = NO;
    if (view == SGLiveActivityLyrics) line = lyricsLine(trackID, &next, &translation, &noLyrics);
    if (!SGFlag(SGKeyLiveActivityTranslation, NO)) translation = nil;
    NSInteger textSize = view == SGLiveActivityLyrics ? SGInt(SGKeyLiveActivityTextSize, SGLiveActivityTextMedium) : SGLiveActivityTextMedium;
    NSInteger alignment = SGInt(SGKeyLiveActivityAlignment, SGLiveActivityAlignCenter);
    NSInteger withoutLyrics = SGInt(SGKeyLiveActivityWithoutLyrics, SGLiveActivityWithoutLyricsNote);
    readArtwork(state, trackID);
    NSString *tint = sg_tint;
    // Artwork off: no cover anywhere, the Dynamic Island's note in its place; the color is still the cover's.
    NSData *cover = SGEnabled(SGKeyLiveActivityArtwork) ? sg_cover : nil;
    NSInteger colors = SGInt(SGKeyLiveActivityColors, SGLiveActivityColorsSpotify);
    NSString *accent = colors == SGLiveActivityColorsArtwork ? sg_accent : nil;
    BOOL progressBar = SGEnabled(SGKeyLiveActivityProgressBar);
    // The bar runs by itself from where the track started; paused, it holds at the share played.
    double duration = [state respondsToSelector:@selector(duration)] ? state.duration : 0;
    NSInteger position = SGKaraokePositionMs();
    NSDate *trackStart = nil, *trackEnd = nil;
    NSNumber *pausedAt = nil;
    static NSDate *sentStart;
    if (duration > 0 && position >= 0) {
        double played = position / 1000.0;
        trackStart = [NSDate dateWithTimeIntervalSinceNow:-played];
        trackStart = [NSDate dateWithTimeIntervalSince1970:round(trackStart.timeIntervalSince1970)];
        // Playing, the start only moves on a seek or a new track; paused, it creeps on with the clock and
        // the bar is drawn from pausedAt, so it is left out of what tells a new state.
        if (paused) pausedAt = @(MIN(1, played / duration));
        else if (sentStart && fabs([trackStart timeIntervalSinceDate:sentStart]) < kStartSlack) trackStart = sentStart;
        else sentStart = trackStart;
        trackEnd = [trackStart dateByAddingTimeInterval:duration];
    }

    NSMutableArray<NSString *> *titles = [NSMutableArray array], *artists = [NSMutableArray array], *uris = [NSMutableArray array];
    if (view != SGLiveActivityLyrics) {
        NSUInteger limit = view == SGLiveActivityQueue ? kUpNextQueue : kUpNextPanel;
        for (SPTPlayerTrack *upcoming in upNext(state)) {
            if (titles.count == limit) break;
            [titles addObject:upcoming.trackTitle];
            [artists addObject:upcoming.artistName ?: @""];
            [uris addObject:uriOf(upcoming)];
        }
    }

    BOOL panel = view == SGLiveActivityPanel;
    // Every view sends the track, which Apple Watch and CarPlay show beside the cover.
    NSString *title = track.trackTitle ?: @"", *artist = track.artistName ?: @"";
    BOOL shuffle = panel && state.options.shufflingContext;
    NSInteger repeatMode = panel ? repeatModeOf(state.options) : 0;
    NSInteger tab = panel ? sg_tab : 0;
    SGSleepTimerMode sleepMode = SGSleepTimerCurrentMode();
    NSDate *sleepEnd = SGSleepTimerEnd();

    // The fields as read, before the string below is built from them: equal fields give an equal string, which
    // send would set aside, so the string and its two dozen pieces are built only once a field moved or kRefresh
    // has passed. The string stays what send compares, as two fields with a line break between them could read as
    // one. The small numbers are tagged pointers, so this is one array a tick.
    NSArray *fields = @[@(view), @(paused), line, next, @(tab), title, artist, @(shuffle), @(repeatMode),
        @((long long)sleepEnd.timeIntervalSince1970), @(sleepMode), tint ?: @"", translation ?: @"",
        paused ? @0 : @((long long)trackStart.timeIntervalSince1970), paused ? @(round(pausedAt.doubleValue * 100)) : @0,
        cover ? sg_artTrack : @"", @(textSize), @(alignment), @(noLyrics), @(withoutLyrics), @(colors), accent ?: @"", @(progressBar),
        titles, artists, uris];
    if ([fields isEqualToArray:sg_shownFields] && -sg_lastSent.timeIntervalSinceNow < kRefresh) return;

    NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithObjects:@(view).stringValue, paused ? @"1" : @"0", line, next,
        @(tab).stringValue, title, artist, shuffle ? @"1" : @"0", @(repeatMode).stringValue,
        @((long long)sleepEnd.timeIntervalSince1970).stringValue, @(sleepMode).stringValue, tint ?: @"", translation ?: @"",
        paused ? @"" : @((long long)trackStart.timeIntervalSince1970).stringValue, paused ? @(round(pausedAt.doubleValue * 100)).stringValue : @"",
        cover ? sg_artTrack : @"", @(textSize).stringValue, @(alignment).stringValue, noLyrics ? @"1" : @"0",
        @(withoutLyrics).stringValue, @(colors).stringValue, accent ?: @"", progressBar ? @"1" : @"0", nil];
    for (NSUInteger i = 0; i < titles.count; i++) [parts addObject:[NSString stringWithFormat:@"%@\t%@\t%@", titles[i], artists[i], uris[i]]];
    send([parts componentsJoinedByString:@"\n"], fields, ^{
        [SGLiveActivityBridge showWithView:view paused:paused line:line nextLine:next titles:titles artists:artists uris:uris
                                        tab:tab title:title artist:artist shuffle:shuffle repeatMode:repeatMode
                                   timerEnd:sleepEnd timerEndOfTrack:sleepMode == SGSleepTimerEndOfTrack
                            timerEndOfAlbum:sleepMode == SGSleepTimerEndOfAlbum
                                       tint:tint trackStart:trackStart trackEnd:trackEnd pausedAt:pausedAt translation:translation
                                      cover:cover textSize:textSize alignment:alignment noLyrics:noLyrics
                              withoutLyrics:withoutLyrics colors:colors accent:accent progressBar:progressBar];
    });
}

// A tap on a track up next: skips ahead to it, found again by its URI in case the queue moved since
// the card was drawn.
static void playQueued(NSString *uri) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerTrack *target = nil;
    for (SPTPlayerTrack *track in upNext(player.state)) {
        if ([uriOf(track) isEqualToString:uri]) { target = track; break; }
    }
    if (!target || ![player respondsToSelector:@selector(skipToNextTrackWithOptions:track:)]) {
        SGLog(@"live activity: cannot play %@ (in the queue: %@, player %@)", uri, target ? @"yes" : @"no", player ? NSStringFromClass([player class]) : @"nil");
        return;
    }
    id result = [player skipToNextTrackWithOptions:nil track:target];
    SGLog(@"live activity: play %@ -> %@", uri, result);
}

// A tap in the control menu, one of SGLiveActivityActionIntent's actions.
static void runAction(NSString *action) {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = player.state;
    NSArray<NSString *> *parts = [action componentsSeparatedByString:@":"];
    NSString *name = parts.firstObject, *value = parts.count > 1 ? parts[1] : @"";
    id result = nil;
    if ([name isEqualToString:@"tab"]) {
        sg_tab = MAX(SGLiveActivityTabControls, MIN(SGLiveActivityTabTimer, value.integerValue));
    } else if ([name isEqualToString:@"toggle"]) {
        result = state.isPaused ? [player resume:nil] : [player pause:nil];
    } else if ([name isEqualToString:@"previous"]) {
        result = [player skipToPreviousTrackWithOptions:nil];
    } else if ([name isEqualToString:@"next"]) {
        result = [player skipToNextTrackWithOptions:nil];
    } else if ([name isEqualToString:@"shuffle"]) {
        result = [player setShufflingContext:!state.options.shufflingContext];
    } else if ([name isEqualToString:@"repeat"]) {
        // Off, then the playlist or album, then the track, then off again, the way Spotify's button goes.
        switch (repeatModeOf(state.options)) {
            case 0: result = [player setRepeatingContext:YES]; break;
            case 1: result = [player setRepeatingTrack:YES]; break;
            default:
                [player setRepeatingTrack:NO];
                result = [player setRepeatingContext:NO];
        }
    } else if ([name isEqualToString:@"timer"]) {
        if ([value isEqualToString:@"cancel"]) SGSetSleepTimer(SGSleepTimerOff, 0);
        else if ([value isEqualToString:@"track"]) SGSetSleepTimer(SGSleepTimerEndOfTrack, 0);
        else if ([value isEqualToString:@"album"]) SGSetSleepTimer(SGSleepTimerEndOfAlbum, 0);
        else if ([value isEqualToString:@"add"]) SGSleepTimerAdd(15 * 60);
        else if (value.integerValue > 0) SGSetSleepTimer(SGSleepTimerAtTime, value.integerValue * 60);
    } else {
        SGLog(@"live activity: unknown action %@", action);
        return;
    }
    SGLog(@"live activity: %@ -> %@", action, result);
}

// What a shortcut set the sleep timer to, for Siri to say.
static NSString *sleepTimerText(void) {
    switch (SGSleepTimerCurrentMode()) {
        case SGSleepTimerEndOfTrack: return @"Spotify will pause at the end of this track.";
        case SGSleepTimerEndOfAlbum: return @"Spotify will pause at the end of this album or playlist.";
        case SGSleepTimerAtTime: {
            NSInteger minutes = lround(SGSleepTimerEnd().timeIntervalSinceNow / 60);
            return [NSString stringWithFormat:@"Spotify will pause in %ld minutes.", (long)minutes];
        }
        default: return @"The sleep timer is off.";
    }
}

// A shortcut's action, LiveActivityShared.swift's SGShortcutNotification: done, and answered in `reply`
// with "said" or "failed"; left unanswered while the player has no track, which a launch in the background
// takes a moment to load, and the intent asks again.
static void runShortcut(NSString *action, NSMutableDictionary *reply) API_AVAILABLE(ios(17.0)) {
    id<SPTPlayer> player = SGKaraokePlayer();
    NSString *title = player.state.track.trackTitle;
    if ([action hasPrefix:@"sing:"]) {
        NSString *mode = [action substringFromIndex:5];
        BOOL on = [mode isEqualToString:@"toggle"] ? !SGSingOn() : [mode isEqualToString:@"on"];
        NSString *missing = on ? SGSingMissing() : nil;
        if (missing) {
            reply[@"failed"] = missing;
        } else {
            if (on != SGSingOn()) SGSetSingOn(on);
            reply[@"said"] = on ? @"Karaoke is on." : @"Karaoke is off.";
        }
    } else if (!title.length) {
        SGLog(@"shortcut: %@ waits for the player", action);
        return;
    } else if ([action isEqualToString:@"like"]) {
        // The like reads the shared player state and the collection platform, which a launch in the background
        // can reach after the player has a track: only what is surely no track fails, the rest waits.
        NSString *uri = SGURIString(SGPlayerState().track.URI);
        if (SGLikePlayingTrack()) {
            reply[@"said"] = [NSString stringWithFormat:@"Added %@ to Liked Songs.", title];
        } else if (uri.length && ![uri hasPrefix:@"spotify:track:"]) {
            reply[@"failed"] = @"What's playing can't be added to Liked Songs.";
        } else {
            SGLog(@"shortcut: like waits for the player state and the collection platform");
            return;
        }
    } else {
        runAction(action);
        if (sg_timer) tick();
        reply[@"said"] = [action hasPrefix:@"timer:"] ? sleepTimerText() : @"";
    }
    SGLog(@"shortcut: %@ -> %@", action, reply);
}

void SGSetLiveActivityEnabled(BOOL on) {
    if (@available(iOS 17.0, *)) {
        [sg_timer invalidate];
        sg_timer = nil;
        sg_shown = nil;
        sg_shownFields = nil;
        sg_lastStart = nil;
        // A sleep timer runs on its own clock (SleepTimer.m) and stays set: the shortcut and the control set it
        // with the card off, and a card switched back on shows it from its first tick.
        if (!on) {
            [SGLiveActivityBridge end];
            SGLog(@"live activity: off");
            return;
        }
        static dispatch_once_t observing;
        dispatch_once(&observing, ^{
            NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
            // The card's intents post from a background thread. With a queue, the post would wait for main, which
            // waits on Spotify's core at a launch in the background: no queue, and on to main without waiting.
            [center addObserverForName:@"SGLiveActivityPlay" object:nil queue:nil usingBlock:^(NSNotification *note) {
                id uri = note.object;
                if (![uri isKindOfClass:NSString.class]) return;
                dispatch_async(dispatch_get_main_queue(), ^{ playQueued(uri); });
            }];
            // The new state goes out at once rather than on the next tick, the card being slow enough to redraw.
            [center addObserverForName:@"SGLiveActivityAction" object:nil queue:nil usingBlock:^(NSNotification *note) {
                id action = note.object;
                if (![action isKindOfClass:NSString.class]) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    runAction(action);
                    if (sg_timer) tick();
                });
            }];
            // Swiped away while it plays, Spotify is told it is ending, and the card goes with it rather than
            // staying up frozen over other apps' activities. No queue, so the block runs before the notification
            // returns, and with it the process. Killed while suspended, Spotify is told nothing: the stale date
            // and the %ctor's cleanup cover that.
            [center addObserverForName:UIApplicationWillTerminateNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
                SGLog(@"live activity: app ending");
                [SGLiveActivityBridge endBeforeExit];
            }];
        });
        startTimer(kTick);
        SGLog(@"live activity: on");
    }
}

%ctor {
    if (@available(iOS 17.0, *)) {
        // It was the redesign's alone until it moved to Shared/; whoever had it on keeps it on.
        SGMigrateKey(SGKeyLiveActivityWas, SGKeyLiveActivity);
        SGMigrateKey(SGKeyLiveActivityViewWas, SGKeyLiveActivityView);
        BOOL on = SGFlag(SGKeyLiveActivity, NO);
        // From launch, card on or off, so a look that ends before the card is switched on still counts. Posted on
        // the main queue, so no queue: it is noted before the post returns.
        sg_lookEnded = [NSMutableSet set];
        [NSNotificationCenter.defaultCenter addObserverForName:SGKaraokeLinesKeptNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            if ([note.object isKindOfClass:NSString.class]) [sg_lookEnded addObject:note.object];
        }];
        // Answered inside the post, which the intent makes on the main thread, so the reply is there when it returns.
        [NSNotificationCenter.defaultCenter addObserverForName:@"SGShortcut" object:nil queue:nil usingBlock:^(NSNotification *note) {
            NSMutableDictionary *reply = note.userInfo[@"reply"];
            if (!NSThread.isMainThread || ![note.object isKindOfClass:NSString.class] || ![reply isKindOfClass:NSMutableDictionary.class]) return;
            runShortcut(note.object, reply);
        }];
        // One left from the launch before is ended: Spotify may have been killed under it, so it shows a moment
        // long gone. On, a fresh one starts once it is: until then the first ticks update the leftover, which is
        // harmless, an update after the end being ignored. A launch in the background (a play from AirPods,
        // CarPlay or the lock screen) keeps it, since no new one can start there, and the first tick updates it.
        // Off, it is ended only if one shows, so nothing is queued for the many who never turned it on.
        dispatch_async(dispatch_get_main_queue(), ^{
            if ((!on && SGLiveActivityBridge.isShowing) || (on && UIApplication.sharedApplication.applicationState != UIApplicationStateBackground))
                [SGLiveActivityBridge end];
            if (on) SGSetLiveActivityEnabled(YES);
        });
    }
}
