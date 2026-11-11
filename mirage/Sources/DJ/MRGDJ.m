#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPrefs.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString *const MRGDJChangedNotification = @"MirageDJChanged";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static id V(NSString *k, id def) { return [D() objectForKey:k] ?: def; }

MRGDJVoiceMode MRGDJVoice(void) { NSInteger m = [V(@"mirage.dj.voice", @0) integerValue]; return (m >= 0 && m <= 2) ? m : MRGDJVoiceDevice; }
void MRGDJSetVoice(MRGDJVoiceMode m) { [D() setInteger:m forKey:@"mirage.dj.voice"]; }
BOOL MRGDJShowsPill(void) { return [V(@"mirage.dj.pill", @YES) boolValue]; }
void MRGDJSetShowsPill(BOOL on) { [D() setBool:on forKey:@"mirage.dj.pill"]; MRGPostChange(); }
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
    // Spoken through Spotify's own audio session (the default), so it mixes with the music rather than
    // interrupting it; the session's category is never changed here.
    _synth.usesApplicationAudioSession = YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged:) name:MRGPlayerTrackChangedNotification object:nil];
    return self;
}

- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:MRGDJChangedNotification object:self]; }

- (void)setStatusText:(NSString *)s { _status = [s copy]; [self changed]; }

- (void)fail:(NSString *)message {
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
    @"Return ONLY a JSON object, no prose: {\"intro\": string, \"tracks\": [{\"artist\": string, \"title\": string, \"line\": string}]}\n"
    @"Rules: 8 to 10 tracks. Real released songs that are on Spotify, with the official title and the primary artist. No duplicates, "
    @"nothing from 'just played'. 'line' is what you say right before that track starts: at most 18 words, mentions the song or the "
    @"artist naturally, every line different. 'intro' opens the set in at most 20 words. If there is a request, follow it.";

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
        NSString *title = item[@"title"], *artist = item[@"artist"], *line = item[@"line"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        MRGDJTrack *t = [MRGDJTrack new];
        t.title = title;
        t.artist = [artist isKindOfClass:NSString.class] ? artist : @"";
        t.line = [line isKindOfClass:NSString.class] ? line : nil;
        [slots addObject:t];
        if (slots.count >= 12) break;
    }
    __block NSString *lastError = nil;
    dispatch_group_t g = dispatch_group_create();
    for (MRGDJTrack *t in slots) {
        dispatch_group_enter(g);
        MRGWebResolve(t.title, t.artist, ^(NSString *uri, NSString *error) {
            t.uri = uri;
            if (error) lastError = error;
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (gen != self->_generation) return;
        NSMutableArray *found = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (MRGDJTrack *t in slots) if (t.uri && ![seen containsObject:t.uri]) { [seen addObject:t.uri]; [found addObject:t]; }
        done(found, lastError);
    });
}

- (void)startWithRequest:(NSString *)request {
    if (MRGAIProvider() == MRGProviderNone) { [self fail:@"Add your AI provider's API key in Mirage settings first."]; return; }
    NSUInteger gen = ++_generation;
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

- (void)playSet:(NSArray<MRGDJTrack *> *)found intro:(NSString *)intro generation:(NSUInteger)gen {
    [self setStatusText:@"Cueing it up…"];
    NSArray *uris = [found valueForKey:@"uri"];
    void (^started)(NSString *) = ^(NSString *mode) {
        if (gen != self->_generation) return;
        self->_set = found;
        self->_playbackMode = mode;
        self->_state = MRGDJPlaying;
        self->_status = nil;
        self->_currentIndex = -1;
        [self->_spoken removeAllObjects];
        self->_intro = intro;
        self->_introPending = intro.length > 0;
        [self changed];
        // The player may already be on the first track by now.
        NSDictionary *now = MRGNowPlaying();
        if (now) [self arrivedAt:now[@"uri"]];
    };
    MRGPlayURIs(uris, ^(BOOL ok, NSString *how, NSString *error) {
        if (ok) { started(how); return; }
        // The player would not take the list (Spotify Free can refuse a list of tracks played on demand): the
        // private Mirage DJ playlist, which Free plays too (shuffled).
        MRGWebFillDJPlaylist(uris, ^(NSString *playlist, NSString *playlistError) {
            if (!playlist) { [self fail:playlistError ?: error ?: @"Spotify wouldn't play the set."]; return; }
            MRGPlayContextURI(playlist, ^(BOOL ok2, NSString *error2) {
                if (ok2) started(@"playlist");
                else [self fail:error2 ?: @"Spotify wouldn't play the Mirage DJ playlist."];
            });
        });
    });
}

#pragma mark - following the player

- (void)trackChanged:(NSNotification *)n {
    if (_state != MRGDJPlaying) return;
    if ([n.userInfo[@"ad"] boolValue]) return;   // never over an ad
    [self arrivedAt:n.userInfo[@"uri"]];
}

- (void)arrivedAt:(NSString *)uri {
    NSInteger index = -1;
    for (NSInteger i = 0; i < (NSInteger)_set.count; i++) if ([_set[i].uri isEqualToString:uri]) { index = i; break; }
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
                if (gen == self->_generation && !MRGPlayerIsAd()) [self speak:line];
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

- (void)speak:(NSString *)line {
    MRGDJVoiceMode mode = MRGDJVoice();
    if (mode == MRGDJVoiceOff) return;
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
        if (!self->_synth.isSpeaking && !self->_audio.isPlaying) MRGDuckMusic(NO);
    });
}

- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didFinishSpeechUtterance:(AVSpeechUtterance *)u { [self finishedSpeaking]; }
- (void)speechSynthesizer:(AVSpeechSynthesizer *)s didCancelSpeechUtterance:(AVSpeechUtterance *)u { [self finishedSpeaking]; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)p successfully:(BOOL)flag { [self finishedSpeaking]; }
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)p error:(NSError *)error { [self finishedSpeaking]; }

@end
