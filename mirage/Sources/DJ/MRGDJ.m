#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString *const MRGDJChangedNotification = @"MirageDJChanged";
NSString *const MRGDJSpeakingNotification = @"MirageDJSpeaking";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static id V(NSString *k, id def) { return [D() objectForKey:k] ?: def; }

MRGDJVoiceMode MRGDJVoice(void) { NSInteger m = [V(@"mirage.dj.voice", @0) integerValue]; return (m >= 0 && m <= 2) ? m : MRGDJVoiceDevice; }
void MRGDJSetVoice(MRGDJVoiceMode m) { [D() setInteger:m forKey:@"mirage.dj.voice"]; }
BOOL MRGDJShowsPill(void) { return [V(@"mirage.dj.pill", @YES) boolValue]; }
void MRGDJSetShowsPill(BOOL on) { [D() setBool:on forKey:@"mirage.dj.pill"]; MRGPostChange(); }
BOOL MRGDJShowsPlayerButton(void) { return [V(@"mirage.dj.playerButton", @YES) boolValue]; }
void MRGDJSetShowsPlayerButton(BOOL on) { [D() setBool:on forKey:@"mirage.dj.playerButton"]; MRGPostChange(); }
BOOL MRGDJDucks(void) { return [V(@"mirage.dj.duck", @YES) boolValue]; }
void MRGDJSetDucks(BOOL on) { [D() setBool:on forKey:@"mirage.dj.duck"]; }

@implementation MRGDJTrack
@end

#pragma mark - voice

// The best English (or the phone's language) voice installed: Premium, then Enhanced, then the default.
static AVSpeechSynthesisVoice *bestVoice(void) {
    NSString *lang = [NSLocale.preferredLanguages.firstObject componentsSeparatedByString:@"-"].firstObject ?: @"en";
    AVSpeechSynthesisVoice *best = nil;
    NSInteger bestScore = -1;
    for (AVSpeechSynthesisVoice *v in AVSpeechSynthesisVoice.speechVoices) {
        if (![v.language hasPrefix:lang] && ![v.language hasPrefix:@"en"]) continue;
        NSInteger score = (NSInteger)v.quality * 10 + ([v.language hasPrefix:lang] ? 5 : 0);
        if (@available(iOS 17.0, *)) { if (v.voiceTraits & AVSpeechSynthesisVoiceTraitIsNoveltyVoice) continue; }
        if ([v.language isEqualToString:AVSpeechSynthesisVoice.currentLanguageCode]) score += 2;
        if (score > bestScore) { best = v; bestScore = score; }
    }
    return best ?: [AVSpeechSynthesisVoice voiceWithLanguage:AVSpeechSynthesisVoice.currentLanguageCode];
}

NSString *MRGDJDeviceVoiceName(void) {
    AVSpeechSynthesisVoice *v = bestVoice();
    NSString *q = v.quality == AVSpeechSynthesisVoiceQualityPremium ? @"Premium" : v.quality == AVSpeechSynthesisVoiceQualityEnhanced ? @"Enhanced" : @"Default";
    return v ? [NSString stringWithFormat:@"%@ (%@)", v.name, q] : @"System voice";
}

@interface MRGDJ () <AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate>
- (void)setSpeaking:(BOOL)speaking line:(NSString *)line;
@end

@implementation MRGDJ {
    AVSpeechSynthesizer *_synth;
    AVAudioPlayer *_audio;
    NSMutableSet<NSString *> *_spoken;
    NSArray<MRGDJTrack *> *_next;          // the set after this one, fetched as the last track starts
    BOOL _fetchingNext;
    NSUInteger _generation;                // a newer start makes older answers stale
    BOOL _introPending;
    NSString *_intro;
}

+ (instancetype)shared {
    static MRGDJ *dj;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dj = [MRGDJ new]; });
    return dj;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _currentIndex = -1;
    _spoken = [NSMutableSet set];
    _synth = [AVSpeechSynthesizer new];
    _synth.delegate = self;
    // Spoken through the system's own speech session, not Spotify's: with the app's session the synthesizer activates
    // it to speak and deactivates it when done, and a deactivation under Spotify's running audio stops the music.
    // Mirage never sets a category or activates a session; the music is lowered by MRGDuckMusic instead.
    _synth.usesApplicationAudioSession = NO;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged:) name:MRGPlayerTrackChangedNotification object:nil];
    return self;
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:MRGDJChangedNotification object:self]; }

- (void)setStatusText:(NSString *)s { _status = [s copy]; [self changed]; }

- (void)fail:(NSString *)message {
    MRGDJLog(@"error shown: %@", message);
    _error = [message copy];
    _status = nil;
    if (_state == MRGDJThinking) _state = _set.count ? MRGDJPlaying : MRGDJIdle;
    [self changed];
}

- (void)stop {
    _generation++;
    _state = MRGDJIdle;
    _set = @[];
    _next = nil;
    _currentIndex = -1;
    _status = nil;
    [_synth stopSpeakingAtBoundary:AVSpeechBoundaryWord];
    [_audio stop];
    MRGDuckMusic(NO);
    [self setSpeaking:NO line:nil];
    [self changed];
}

#pragma mark - the set

static NSString *listOf(NSArray<NSDictionary *> *tracks, NSUInteger max) {
    NSMutableArray *lines = [NSMutableArray array];
    for (NSDictionary *t in tracks) {
        if (![t[@"title"] length]) continue;
        [lines addObject:[NSString stringWithFormat:@"- %@ — %@", t[@"title"], t[@"artist"] ?: @""]];
        if (lines.count >= max) break;
    }
    return lines.count ? [lines componentsJoinedByString:@"\n"] : @"(none)";
}

static NSString *const kSystem =
    @"You are Mirage DJ, the host of a personal radio show inside the listener's Spotify. Your persona is X: casual, witty, "
    @"a little cheeky, confident, like a friend posting on X. Short and punchy, lowercase is fine, no hashtags, no emojis, "
    @"no corporate tone, never cringe.\n"
    @"Pick music this listener will love from their taste: mostly songs that fit what they play, plus a few fresh finds in the same lane. "
    @"Order the set so it flows.\n"
    @"Return ONLY a JSON object, no prose: {\"intro\": string, \"tracks\": [{\"artist\": string, \"title\": string, \"line\": string, \"why\": string}]}\n"
    @"Rules: 8 to 10 tracks. Only real, released songs you are certain exist on Spotify, with the exact official title and the primary artist "
    @"as Spotify lists them. Never invent songs, artists or versions; no made-up remixes or 'extended' edits. When unsure, pick a well-known "
    @"song by an artist you know instead. No duplicates, "
    @"nothing from 'just played'. 'line' is what you say right before that track starts: at most 18 words, mentions the song or the "
    @"artist naturally, every line different. 'why' is 1 to 4 lowercase words on why it's in the set (like \"fresh find\", \"you loved this\", \"same vibe\", \"throwback\"). 'intro' opens the set in at most 20 words. If there is a request, follow it.";

- (NSString *)promptWithTaste:(NSArray *)top artists:(NSArray *)artists liked:(NSArray *)liked request:(NSString *)request {
    NSDictionary *now = MRGNowPlaying();
    NSMutableArray *played = [NSMutableArray arrayWithArray:MRGRecentHistory()];
    for (MRGDJTrack *t in _set) [played addObject:@{@"title": t.title ?: @"", @"artist": t.artist ?: @""}];
    NSMutableString *p = [NSMutableString string];
    [p appendFormat:@"Now playing: %@\n\n", now ? [NSString stringWithFormat:@"%@ — %@", now[@"title"], now[@"artist"] ?: @""] : @"(nothing)"];
    [p appendFormat:@"Just played:\n%@\n\n", listOf(played, 25)];
    [p appendFormat:@"Around it in the queue:\n%@\n\n", listOf(MRGQueueAround(), 10)];
    [p appendFormat:@"Their top and recent tracks:\n%@\n\n", listOf(top, 20)];
    [p appendFormat:@"Their top artists: %@\n\n", artists.count ? [artists componentsJoinedByString:@", "] : @"(unknown)"];
    [p appendFormat:@"Songs they liked:\n%@\n\n", listOf(liked, 15)];
    [p appendFormat:@"Request: %@", request.length ? request : @"(none: just play something great for them right now)"];
    return p;
}

static NSDictionary *parseJSON(NSString *text) {
    NSRange open = [text rangeOfString:@"{"], close = [text rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) return nil;
    NSString *body = [text substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
    id json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

// Asks for a set and finds its tracks; `done` gets the found tracks in order (or an error) and the intro.
- (void)buildSetWithRequest:(NSString *)request generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSString *intro, NSString *error))done {
    __block BOOL tasted = NO;
    void (^ask)(NSArray *, NSArray *, NSArray *) = ^(NSArray *top, NSArray *artists, NSArray *liked) {
        if (tasted) return;
        tasted = YES;
        if (gen != self->_generation) return;
        NSString *prompt = [self promptWithTaste:top artists:artists liked:liked request:request];
        MRGAIChat(kSystem, prompt, YES, ^(NSString *text, NSString *error) {
            if (gen != self->_generation) return;
            if (error) { done(nil, nil, error); return; }
            NSDictionary *json = parseJSON(text);
            NSArray *items = [json[@"tracks"] isKindOfClass:NSArray.class] ? json[@"tracks"] : nil;
            if (!items.count) { done(nil, nil, [NSString stringWithFormat:@"%@ didn't send a playlist I could read. Try again.", MRGProviderName(MRGAIProvider())]); return; }
            NSString *intro = [json[@"intro"] isKindOfClass:NSString.class] ? json[@"intro"] : nil;
            [self resolve:items generation:gen done:^(NSArray<MRGDJTrack *> *found, NSString *resolveError) {
                if (!found.count) done(nil, nil, resolveError ?: @"Couldn't find those songs on Spotify. Try again.");
                else done(found, intro, nil);
            }];
        });
    };
    // Taste from the Web API where the token allows; never more than 4 s of waiting for it.
    MRGWebTaste(^(NSArray *top, NSArray *artists, NSArray *liked) { ask(top, artists, liked); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ ask(@[], @[], @[]); });
}

- (void)resolve:(NSArray *)items generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSString *))done {
    NSMutableArray *slots = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *title = item[@"title"], *artist = item[@"artist"], *line = item[@"line"], *why = item[@"why"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        MRGDJTrack *t = [MRGDJTrack new];
        t.title = title;
        t.artist = [artist isKindOfClass:NSString.class] ? artist : @"";
        t.line = [line isKindOfClass:NSString.class] ? line : nil;
        t.why = [why isKindOfClass:NSString.class] && why.length && why.length <= 32 ? why : nil;
        [slots addObject:t];
        if (slots.count >= 12) break;
    }
    __block NSString *lastError = nil;
    dispatch_group_t g = dispatch_group_create();
    for (MRGDJTrack *t in slots) {
        dispatch_group_enter(g);
        MRGWebResolve(t.title, t.artist, ^(NSDictionary *track, NSString *error) {
            t.uri = track[@"uri"];
            t.image = track[@"image"];
            if ([track[@"title"] length]) t.title = track[@"title"];
            if ([track[@"artist"] length]) t.artist = track[@"artist"];
            if (error) lastError = error;
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (gen != self->_generation) return;
        NSMutableArray *found = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (MRGDJTrack *t in slots) if (t.uri && ![seen containsObject:t.uri]) { [seen addObject:t.uri]; [found addObject:t]; }
        MRGDJLog(@"set: %lu picks, %lu found on Spotify%@", (unsigned long)slots.count, (unsigned long)found.count,
                 lastError ? [@", last error: " stringByAppendingString:lastError] : @"");
        done(found, lastError);
    });
}

- (void)startWithRequest:(NSString *)request {
    if (MRGAIProvider() == MRGProviderNone) { [self fail:@"Add your AI provider's API key in Mirage settings first."]; return; }
    NSUInteger gen = ++_generation;
    MRGDJLog(@"start: %@ with %@ (%@)", request.length ? @"a request" : @"no request", MRGProviderName(MRGAIProvider()), MRGAIModel() ?: @"?");
    static BOOL accountLogged;
    if (!accountLogged) { accountLogged = YES; MRGWebAccount(^(NSString *product, NSString *error) {}); }
    _state = MRGDJThinking;
    _error = nil;
    _next = nil;
    _fetchingNext = NO;
    [self setStatusText:request.length ? @"On it…" : @"Reading the room…"];
    [self buildSetWithRequest:request generation:gen done:^(NSArray<MRGDJTrack *> *found, NSString *intro, NSString *error) {
        if (gen != self->_generation) return;
        if (error) { [self fail:error]; return; }
        [self playSet:found intro:intro generation:gen];
    }];
}

// Playback, in order:
//  1. The private "Mirage DJ" playlist, refilled with the set over the Web API, played as Spotify's own playlist Play
//     button plays it (contextForURI, skipTo the first track, the player's own origin). Spotify Free plays it shuffled.
//  2. The playlist could not be filled: the first track as a context and the rest queued.
//  3. The player took neither: the playlist is opened in Spotify (its link dispatcher) so one tap on Play starts it.
// Each step is checked against the player's state (MRGWaitForPlayback), since the player can take a command and play
// nothing; every outcome ends in a status line or an error, and the debug log.
- (void)playSet:(NSArray<MRGDJTrack *> *)found intro:(NSString *)intro generation:(NSUInteger)gen {
    NSArray<NSString *> *uris = [found valueForKey:@"uri"];
    void (^started)(NSString *) = ^(NSString *mode) {
        if (gen != self->_generation) return;
        MRGDJLog(@"set: playing (%@)", mode);
        self->_set = found;
        self->_playbackMode = mode;
        self->_state = MRGDJPlaying;
        self->_status = nil;
        self->_currentIndex = -1;
        [self->_spoken removeAllObjects];
        self->_intro = intro;
        self->_introPending = intro.length > 0;
        [self changed];
        NSDictionary *now = MRGNowPlaying();
        if (now) [self arrivedAt:now];
    };
    void (^failed)(NSString *) = ^(NSString *why) {
        if (gen != self->_generation) return;
        MRGDJLog(@"set: couldn't start playback: %@", why);
        // The set stays listed, so a row can still be tried and Switch it up asks again.
        self->_set = found;
        self->_currentIndex = -1;
        self->_state = MRGDJIdle;
        [self fail:[NSString stringWithFormat:@"Couldn't start playback: %@", why]];
    };
    void (^queuePath)(NSString *) = ^(NSString *playlistError) {
        if (gen != self->_generation) return;
        [self setStatusText:@"Starting the first song…"];
        MRGPlayTrackThenQueue(uris, ^(BOOL ok, NSString *error) {
            if (gen != self->_generation) return;
            if (!ok) { failed([NSString stringWithFormat:@"%@ (playlist: %@)", error ?: @"the player refused it", playlistError ?: @"?"]); return; }
            MRGWaitForPlayback(uris, nil, 6, ^(BOOL playing, NSString *seen) {
                if (playing) started(@"queue");
                else failed([NSString stringWithFormat:@"Spotify took the song but didn't play it; %@ (playlist: %@)", seen, playlistError ?: @"?"]);
            });
        });
    };
    [self setStatusText:@"Filling your Mirage DJ playlist…"];
    MRGWebFillDJPlaylist(uris, ^(NSString *playlist, NSString *playlistError) {
        if (gen != self->_generation) return;
        if (!playlist) { queuePath(playlistError ?: @"couldn't fill it"); return; }
        [self setStatusText:@"Starting playback…"];
        // A beat for Spotify's backend to have the new contents before the player resolves the playlist.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen != self->_generation) return;
            MRGPlayContextURI(playlist, uris.firstObject, ^(BOOL ok, NSString *error) {
                if (gen != self->_generation) return;
                void (^openIt)(NSString *) = ^(NSString *why) {
                    if (MRGOpenSpotifyURI(playlist)) {
                        self->_set = found;
                        self->_playbackMode = @"opened";
                        self->_state = MRGDJPlaying;
                        self->_currentIndex = -1;
                        [self->_spoken removeAllObjects];
                        self->_intro = intro;
                        self->_introPending = intro.length > 0;
                        self->_status = nil;
                        self->_error = [NSString stringWithFormat:@"Spotify didn't start it on its own (%@). I opened your Mirage DJ playlist: tap Play and I'll talk over it.", why];
                        MRGDJLog(@"set: opened the playlist for a tap on Play");
                        [self changed];
                    } else {
                        queuePath([@"the player didn't play it: " stringByAppendingString:why]);
                    }
                };
                if (!ok) { openIt(error ?: @"the player refused it"); return; }
                MRGWaitForPlayback(uris, playlist, 6, ^(BOOL playing, NSString *seen) {
                    if (playing) started(@"playlist");
                    else openIt(seen);
                });
            });
        });
    });
}

- (void)playFromIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_set.count) return;
    if (index == _currentIndex) return;
    NSString *target = _set[index].uri;
    NSString *playlist = [NSUserDefaults.standardUserDefaults stringForKey:@"mirage.dj.playlist"];
    NSString *context = playlist ? [@"spotify:playlist:" stringByAppendingString:playlist] : nil;
    NSUInteger gen = _generation;
    _error = nil;
    [self setStatusText:@"Skipping to it…"];
    MRGDJLog(@"row: jump to %ld", (long)index);
    void (^result)(BOOL, NSString *) = ^(BOOL ok, NSString *error) {
        if (gen != self->_generation) return;
        if (!ok) { [self fail:[NSString stringWithFormat:@"Couldn't jump to that song: %@", error ?: @"Spotify refused it (Spotify Free can't pick songs on demand)."]]; return; }
        MRGWaitForPlayback(@[target], nil, 5, ^(BOOL playing, NSString *seen) {
            if (gen != self->_generation) return;
            self->_status = nil;
            if (!playing) { [self fail:[NSString stringWithFormat:@"Spotify didn't jump to that song (%@). On Spotify Free it can't pick songs on demand.", seen]]; return; }
            if (self->_state == MRGDJIdle) self->_state = MRGDJPlaying;
            [self changed];
        });
    };
    BOOL inPlaylist = context && ([self->_playbackMode isEqualToString:@"playlist"] || [self->_playbackMode isEqualToString:@"opened"]);
    if (inPlaylist) MRGPlayContextURI(context, target, result);
    else MRGPlayTrackThenQueue([[_set subarrayWithRange:NSMakeRange(index, _set.count - index)] valueForKey:@"uri"], result);
}

#pragma mark - following the player

- (void)trackChanged:(NSNotification *)n {
    if (_state != MRGDJPlaying) return;
    if ([n.userInfo[@"ad"] boolValue]) return;   // never over an ad
    [self arrivedAt:n.userInfo];
}

static NSString *plain(NSString *s) {
    NSString *l = [[s ?: @"" lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    NSRange cut = [l rangeOfString:@" ("];
    if (cut.location != NSNotFound && cut.location > 0) l = [l substringToIndex:cut.location];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < l.length; i++) { unichar c = [l characterAtIndex:i]; if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) [out appendFormat:@"%C", c]; }
    return out;
}

// The set's index of what is playing: by URI, or by title and artist (Spotify can play a relinked copy of a track, with
// another URI, in another market or on Free).
- (NSInteger)indexOf:(NSDictionary *)now {
    NSString *uri = now[@"uri"];
    for (NSInteger i = 0; i < (NSInteger)_set.count; i++) if ([_set[i].uri isEqualToString:uri]) return i;
    NSString *t = plain(now[@"title"]), *a = plain(now[@"artist"]);
    if (!t.length) return -1;
    for (NSInteger i = 0; i < (NSInteger)_set.count; i++)
        if ([plain(_set[i].title) isEqualToString:t] && (!a.length || [plain(_set[i].artist) isEqualToString:a])) return i;
    return -1;
}

- (void)arrivedAt:(NSDictionary *)now {
    NSString *uri = now[@"uri"];
    NSInteger index = [self indexOf:now];
    if (index >= 0 && [_playbackMode isEqualToString:@"opened"]) { _playbackMode = @"playlist"; _error = nil; }
    _currentIndex = index;
    if (index < 0) {
        // Past the set (Spotify's autoplay took over): the next set, fetched as the last track started, goes on.
        if (_set.count && _spoken.count && _next.count) {
            NSArray *next = _next;
            _next = nil;
            [self playSet:next intro:nil generation:_generation];
        }
        [self changed];
        return;
    }
    MRGDJTrack *t = _set[index];
    if (![_spoken containsObject:uri]) {
        [_spoken addObject:uri];
        NSString *line = t.line;
        if (_introPending) { line = line.length ? [NSString stringWithFormat:@"%@ %@", _intro, line] : _intro; _introPending = NO; }
        if (line.length) {
            _currentLine = [line copy];
            // A beat after the track starts, as a DJ would come in over the intro.
            NSUInteger gen = _generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // Only over its own track, playing: not over an ad, a pause or a track that has moved on.
                NSDictionary *still = MRGNowPlaying();
                if (gen == self->_generation && !MRGPlayerIsAd() && MRGPlayerIsPlaying() && [self indexOf:still ?: @{}] == index) [self speak:line];
                else MRGDJLog(@"voice: line skipped, its track isn't playing");
            });
        }
    }
    if (index >= (NSInteger)_set.count - 1 && !_fetchingNext && !_next) [self fetchNext];
    [self changed];
}

- (void)fetchNext {
    _fetchingNext = YES;
    NSUInteger gen = _generation;
    [self buildSetWithRequest:nil generation:gen done:^(NSArray<MRGDJTrack *> *found, NSString *intro, NSString *error) {
        if (gen != self->_generation) return;
        self->_fetchingNext = NO;
        if (found.count) self->_next = found;
    }];
}

#pragma mark - speaking

- (void)setSpeaking:(BOOL)speaking line:(NSString *)line {
    if (speaking == _speaking && !speaking) return;
    _speaking = speaking;
    [NSNotificationCenter.defaultCenter postNotificationName:MRGDJSpeakingNotification object:self
        userInfo:@{@"speaking": @(speaking), @"line": line ?: _currentLine ?: @""}];
}

- (void)speak:(NSString *)line {
    MRGDJVoiceMode mode = MRGDJVoice();
    [self setSpeaking:YES line:line];
    if (mode == MRGDJVoiceOff) {
        // No voice: the caption stays up for about as long as reading it takes.
        NSUInteger words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].count;
        NSUInteger gen = _generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(3.5, words * 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen == self->_generation && [self->_currentLine isEqualToString:line]) [self setSpeaking:NO line:line];
        });
        return;
    }
    if (MRGDJDucks()) MRGDuckMusic(YES);
    if (mode == MRGDJVoiceProvider && MRGProviderHasTTS(MRGAIProvider())) {
        MRGAISpeech(line, ^(NSData *audio, NSString *error) {
            self->_audio = audio ? [[AVAudioPlayer alloc] initWithData:audio error:nil] : nil;
            self->_audio.delegate = self;
            if (self->_audio && [self->_audio play]) return;
            [self speakOnDevice:line];   // no audio from the provider: the phone's voice instead
        });
        return;
    }
    [self speakOnDevice:line];
}

- (void)speakOnDevice:(NSString *)line {
    AVSpeechUtterance *u = [AVSpeechUtterance speechUtteranceWithString:line];
    u.voice = bestVoice();
    u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04f;
    u.pitchMultiplier = 1.0f;
    u.volume = 1.0f;
    u.preUtteranceDelay = 0.05;
    [_synth speakUtterance:u];
}

- (void)finishedSpeaking {
    // Back up after a short tail, so the last word is not stepped on.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!self->_synth.isSpeaking && !self->_audio.isPlaying) { MRGDuckMusic(NO); [self setSpeaking:NO line:nil]; }
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u { [self finishedSpeaking]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self finishedSpeaking]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { [self finishedSpeaking]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { [self finishedSpeaking]; }

@end
