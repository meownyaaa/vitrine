#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import "MRGVoice.h"
#import "MRGHistory.h"
#import "MRGInfo.h"
#import "MRGChat.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

NSString *const MRGDJChangedNotification = @"MirageDJChanged";
NSString *const MRGDJSpeakingNotification = @"MirageDJSpeaking";

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
// Typed: a stored value of another type (a string, an array) is ignored and the default used.
static id V(NSString *k, id def) { id v = [D() objectForKey:k]; return [v isKindOfClass:NSNumber.class] ? v : def; }

BOOL MRGDJShowsPill(void) { return [V(@"mirage.dj.pill", @YES) boolValue]; }
void MRGDJSetShowsPill(BOOL on) { [D() setBool:on forKey:@"mirage.dj.pill"]; MRGPostChange(); }
BOOL MRGDJShowsPlayerButton(void) { return [V(@"mirage.dj.playerButton", @YES) boolValue]; }
void MRGDJSetShowsPlayerButton(BOOL on) { [D() setBool:on forKey:@"mirage.dj.playerButton"]; MRGPostChange(); }
BOOL MRGDJDucks(void) { return [V(@"mirage.dj.duck", @YES) boolValue]; }
void MRGDJSetDucks(BOOL on) { [D() setBool:on forKey:@"mirage.dj.duck"]; }

static NSArray<NSString *> *urisOf(NSArray *tracks) {
    NSMutableArray *a = [NSMutableArray array];
    for (id t in tracks) { NSString *u = [t isKindOfClass:MRGDJTrack.class] ? ((MRGDJTrack *)t).uri : nil; if ([u isKindOfClass:NSString.class] && u.length) [a addObject:u]; }
    return a;
}

@implementation MRGDJTrack
- (instancetype)init { if ((self = [super init])) _popularity = -1; return self; }
@end

#pragma mark - personas

// name, blurb, style, default talk, words per line
static NSArray<NSArray *> *personas(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            @[@"Classic", @"Casual, witty, a little cheeky.",
              @"casual, witty, a little cheeky, confident, like a friend posting on X. Short and punchy, lowercase is fine, no hashtags, no emojis, never cringe.", @(MRGDJTalkEvery), @18],
            @[@"Chill radio host", @"Warm late-night host, relaxed and smooth.",
              @"a warm, relaxed late-night radio host: smooth, unhurried, friendly, a little poetic about the mood, never loud. Plain sentences, no slang overload, no emojis.", @(MRGDJTalkEvery), @20],
            @[@"Hype", @"High energy, short, loud.",
              @"a high-energy hype host: short, exciting, punchy bursts, gets the listener going, big energy but never cringe or corny. No emojis, no hashtags.", @(MRGDJTalkEvery), @12],
            @[@"Underground curator", @"Knows the deep cuts; talks sound and scene.",
              @"an underground music curator and crate digger: understated, talks about the sound, the texture and the scene it fits; no invented trivia. Never hype, never generic.", @(MRGDJTalkFew), @24],
            @[@"Storyteller", @"Paints the mood of each song.",
              @"a storyteller: paints the mood and the picture the song puts in your head, vivid but brief, as feeling, never as invented facts about how it was made.", @(MRGDJTalkFew), @40],
            @[@"Minimal", @"Barely talks: names and nothing else.",
              @"a minimal host: almost silent, just the song and artist or a two-word mood, nothing more.", @(MRGDJTalkSwitches), @8],
            @[@"Soft & soothing", @"Gentle, warm and calm, close to the mic.",
              @"a soft, soothing, warm host: gentle, calm, caring and reassuring, unhurried and intimate, like someone talking to you quietly late at night. Short tender lines in simple words; no hype, no slang overload, no emojis.", @(MRGDJTalkFew), @16],
        ];
    });
    return list;
}

// Not [personas() valueForKey:@"firstObject"]: on an array of arrays KVC maps into each inner array too and asks its
// strings for "firstObject", which throws (0.3.0's crash in Settings → AI DJ → Vibe).
NSArray<NSString *> *MRGDJPersonaNames(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSArray *p in personas()) [a addObject:[p isKindOfClass:NSArray.class] && [p.firstObject isKindOfClass:NSString.class] ? p.firstObject : @"—"];
    return a;
}
NSArray<NSString *> *MRGDJPersonaBlurbs(void) { NSMutableArray *a = [NSMutableArray array]; for (NSArray *p in personas()) [a addObject:p[1]]; return a; }
NSInteger MRGDJPersona(void) { NSInteger i = [V(@"mirage.dj.persona", @0) integerValue]; return (i >= 0 && i < (NSInteger)personas().count) ? i : 0; }
void MRGDJSetPersona(NSInteger i) { [D() setInteger:i forKey:@"mirage.dj.persona"]; }
MRGDJTalk MRGDJTalkSetting(void) { NSInteger t = [V(@"mirage.dj.talk", @0) integerValue]; return (t >= 0 && t <= 3) ? t : MRGDJTalkAuto; }
void MRGDJSetTalkSetting(MRGDJTalk t) { [D() setInteger:t forKey:@"mirage.dj.talk"]; }
MRGDJTalk MRGDJTalkEffective(void) { MRGDJTalk t = MRGDJTalkSetting(); return t == MRGDJTalkAuto ? [personas()[MRGDJPersona()][3] integerValue] : t; }
NSString *MRGDJCustomPrompt(void) { NSString *s = [D() stringForKey:@"mirage.dj.customPrompt"]; return s.length ? s : nil; }
void MRGDJSetCustomPrompt(NSString *s) {
    NSString *t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.length) [D() setObject:[t substringToIndex:MIN(t.length, (NSUInteger)2000)] forKey:@"mirage.dj.customPrompt"];
    else [D() removeObjectForKey:@"mirage.dj.customPrompt"];
}
NSString *MRGDJPersonaStyle(void) { return personas()[MRGDJPersona()][2]; }
static NSInteger personaWords(void) { return [personas()[MRGDJPersona()][4] integerValue]; }

NSString *MRGDJDeviceVoiceName(void) { return MRGVoiceSummary(); }

#pragma mark - talking like the listener

BOOL MRGDJMirrorsUser(void) { return [V(@"mirage.dj.mirror", @YES) boolValue]; }
void MRGDJSetMirrorsUser(BOOL on) { [D() setBool:on forKey:@"mirage.dj.mirror"]; }

// The listener's own chat messages (the last 30, on this phone), as samples of how they write.
void MRGDJNoteUserMessage(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.length < 2 || t.length > 400) return;
    NSMutableArray *a = [NSMutableArray array];
    for (id x in [D() arrayForKey:@"mirage.dj.userVoice"]) if ([x isKindOfClass:NSString.class]) [a addObject:x];
    [a removeObject:t];
    [a addObject:t];
    while (a.count > 30) [a removeObjectAtIndex:0];
    [D() setObject:a forKey:@"mirage.dj.userVoice"];
}
void MRGDJForgetUserStyle(void) { [D() removeObjectForKey:@"mirage.dj.userVoice"]; }

NSString *MRGDJStyleInstructions(void) {
    if (!MRGDJMirrorsUser()) return nil;
    NSMutableArray *a = [NSMutableArray array];
    for (id x in [D() arrayForKey:@"mirage.dj.userVoice"]) if ([x isKindOfClass:NSString.class]) [a addObject:x];
    if (a.count < 2) return nil;
    NSArray *recent = [a subarrayWithRange:NSMakeRange(a.count - MIN(a.count, (NSUInteger)6), MIN(a.count, (NSUInteger)6))];
    NSMutableString *p = [NSMutableString stringWithString:@"Talk the way this listener talks. Things they've written to you:\n"];
    for (NSString *m in recent) [p appendFormat:@"- \"%@\"\n", m];
    [p appendString:@"Mirror their register: casing, slang, abbreviations, emoji (or none), sentence length and energy, blended with your persona. Sound like a friend who talks like them, never a parody; don't copy their typos or overdo slang."];
    return p;
}

// What the DJ knows of the listener's taste, from the history on this phone, as prompt text (nil when empty).
NSString *MRGDJTasteText(void) {
    NSDictionary *t = MRGHistoryTaste();
    NSMutableString *p = [NSMutableString string];
    NSArray *rep = t[@"onRepeat"], *recentA = t[@"recentArtists"], *allA = t[@"allTimeArtists"], *old = t[@"throwbacks"];
    if ([rep count]) {
        [p appendString:@"On repeat lately (last 4 weeks, plays):\n"];
        for (NSDictionary *x in [rep subarrayWithRange:NSMakeRange(0, MIN([rep count], (NSUInteger)8))]) [p appendFormat:@"- %@ — %@ (%@)\n", x[@"title"], x[@"artist"], x[@"plays"]];
    }
    if ([recentA count]) [p appendFormat:@"Artists they've played most lately: %@\n", [[recentA subarrayWithRange:NSMakeRange(0, MIN([recentA count], (NSUInteger)10))] componentsJoinedByString:@", "]];
    if ([allA count]) [p appendFormat:@"Their top artists of all time (by time listened): %@\n", [[allA subarrayWithRange:NSMakeRange(0, MIN([allA count], (NSUInteger)10))] componentsJoinedByString:@", "]];
    if ([old count]) {
        [p appendString:@"Throwbacks (played a lot, not for months; last year):\n"];
        for (NSDictionary *x in [old subarrayWithRange:NSMakeRange(0, MIN([old count], (NSUInteger)4))]) [p appendFormat:@"- %@ — %@ (%@)\n", x[@"title"], x[@"artist"], x[@"year"]];
    }
    return p.length ? p : nil;
}

#pragma mark - requests that name an artist

static BOOL matches(NSString *s, NSString *pattern) {
    if (!s.length) return NO;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}
static NSString *replaced(NSString *s, NSString *pattern, NSString *with) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return [re stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:with];
}

// The part of a request that could be an artist's name, and the mode (1 artist + neighbours, 2 only them, 3 like them).
// "play some yvl" → "yvl"; "only pz songs" → "pz" (2); "stuff like clairo" → "clairo" (3); "chill vibes" → nil.
// `plain` is set when the request is nothing but the artist ("yvl", "play pz", "only uzi"): that plays their catalog.
static NSString *artistCandidate(NSString *request, NSInteger *mode, BOOL *plain) {
    NSString *r = [[request ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    *plain = NO;
    if (!r.length || r.length > 80 || [r hasPrefix:@"switch it up"]) return nil;
    *mode = 1;
    if (matches(r, @"\\b(only|just|nothing but|all)\\b")) *mode = 2;
    NSString *like = nil;
    NSRegularExpression *likeRe = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:like|similar to|sounds? like|in the style of|vibes? of|kinda like)\\s+(.+)$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *lm = [likeRe firstMatchInString:r options:0 range:NSMakeRange(0, r.length)];
    if (lm) { like = [r substringWithRange:[lm rangeAtIndex:1]]; *mode = 3; }
    NSRegularExpression *byRe = [NSRegularExpression regularExpressionWithPattern:@"\\b(?:by|from)\\s+(.+)$" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *bm = like ? nil : [byRe firstMatchInString:r options:0 range:NSMakeRange(0, r.length)];
    NSString *c = like ?: (bm ? [r substringWithRange:[bm rangeAtIndex:1]] : r);
    c = replaced(c, @"^(?:yo|hey|ayo|aye|bro|pls|please|dj|can you|could you|u|you)[,!]?\\s+", @"");
    c = replaced(c, @"^(?:play|put on|queue|queue up|spin|run|throw on|gimme|give me|i want|i wanna hear|let me hear|start|bump|blast)\\s+", @"");
    c = replaced(c, @"^(?:me\\s+)?(?:some|sum|a few|more|only|just|nothing but|all|a|the best of|the best|top|a set of|a mix of)\\s+", @"");
    c = replaced(c, @"^(?:songs?|tracks?|music|stuff)\\s+(?:by|from)\\s+", @"");
    for (int i = 0; i < 3; i++)
        c = replaced(c, @"\\s+(?:songs?|tracks?|music|bangers|hits|vibes?|type beat|stuff|only|pls|please|rn|right now|now|set|radio|mix|for me|bro|fr|asf|lol)$", @"");
    c = [c stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .!?,\"'"]];
    if (!c.length || c.length > 40 || [c componentsSeparatedByString:@" "].count > 4) return nil;
    *plain = !like && !matches(r, @"\\b(?:chill|sad|hype|slow|fast|underground|deep cuts?|old|new|early|late|unreleased|throwback|mix(?:ed)? with|and)\\b");
    // Genres, moods and filler aren't artists.
    if (matches(c, @"^(?:something|anything|music|vibes?|chill|sad|happy|hype|underground|rap|hip ?hop|r&?b|rnb|pop|rock|jazz|lo-?fi|house|techno|edm|drill|trap|indie|country|metal|punk|soul|funk|gym|workout|study|sleep|party|throwbacks?|old ?school|old|new|new music|it up|a vibe|bangers|hits|classics|love songs|songs|my favorites|favorites|on repeat|deep cuts|hidden gems|90s|80s|2000s|2010s|late night|morning|night|focus|road trip|summer|winter|dance|latin|afrobeats?|k-?pop|phonk|emo|grunge|reggae|reggaeton|blues|classical|ambient|alt|alternative)(?:\\s.*)?$")) return nil;
    return c;
}

@interface MRGDJ ()
- (void)setSpeaking:(BOOL)speaking line:(NSString *)line;
@end

@implementation MRGDJ {
    NSMutableSet<NSString *> *_spoken;
    NSString *_origRequest;                // the listener's own last request, kept through Switch it up
    NSInteger _talkCount;                  // tracks of this set the DJ arrived at, for the talk setting
    NSArray<MRGDJTrack *> *_next;          // the set after this one, fetched as the last track starts
    BOOL _fetchingNext;
    NSUInteger _generation;                // a newer start makes older answers stale
    BOOL _introPending;
    NSString *_intro;
    NSInteger _lastIndex;                  // the last set track that played, for stepping on
    CFTimeInterval _lastStart;             // when it started
    double _lastDuration;                  // its length in seconds (0: unknown)
    BOOL _stepping;                        // a step to the next set track is on its way
    NSDictionary *_focus;                  // the artist the request is about (uri, name, genres), or nil
    NSArray<NSDictionary *> *_focusTracks; // their tracks on Spotify (resolved dictionaries)
    NSArray<NSDictionary *> *_focusRelated;
    NSInteger _focusMode;                  // 1 artist and neighbours, 2 only them, 3 like them, 4 after their catalog: similar only
    NSArray<NSDictionary *> *_focusCrew;   // a label or crew: its artists (the first is _focus); nil for one artist
    BOOL _focusPlain;                      // the request was just the artist: play their catalog
    BOOL _syncing;                         // a queue read-back is on its way
    NSInteger _rebuilds;                   // queue rebuilds for this set (at most 2, then step mode)
    NSUInteger _syncToken;                 // debounces syncQueueSoon
    CFTimeInterval _lastSync;
    NSDictionary<NSString *, NSNumber *> *_pool;  // on-topic artists (lowercased name → closeness 1-3) for this set, or nil
    NSArray<NSString *> *_poolSeeds;              // the seeds the pool came from (display names)
    NSString *_poolKey;                           // which seeds it was built for
    CFTimeInterval _poolTime;
    BOOL _poolHard;                               // off-pool picks are capped (no request, or an artist request)
    NSInteger _missStreak;                        // sync reads in a row that found set songs missing
    CFTimeInterval _setStarted;                   // when the current set's first song was verified
    NSUInteger _speakToken;                       // the latest line: an older line's "finished" doesn't unduck it
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
    _lastIndex = -1;
    _spoken = [NSMutableSet set];
    // Speech goes through MRGVoiceSpeaker, on the system's own speech session (never Spotify's; a deactivation under
    // Spotify's running audio would stop the music). The music is lowered by MRGDuckMusic.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(trackChanged:) name:MRGPlayerTrackChangedNotification object:nil];
    // Spotify's queue can change under the set (the listener edits it, a play wipes it): checked every 25 s while a set is on.
    [NSTimer scheduledTimerWithTimeInterval:25 target:self selector:@selector(syncTick) userInfo:nil repeats:YES];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(voiceResult:) name:MRGVoiceResultNotification object:nil];
    return self;
}

// An ElevenLabs line that failed is shown on the DJ sheet with ElevenLabs' own error (never spoken as Samantha).
- (void)voiceResult:(NSNotification *)n {
    if (![n.userInfo[@"failed"] boolValue]) return;
    NSString *r = n.userInfo[@"result"];
    if (![r isKindOfClass:NSString.class] || ![r containsString:@"ElevenLabs"]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_error = [[r stringByReplacingOccurrencesOfString:@"✗ " withString:@""] copy];
        if (self->_speaking) [self setSpeaking:NO line:nil];
        MRGDuckMusic(NO);
        [self changed];
    });
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
    _lastIndex = -1;
    _stepping = NO;
    _status = nil;
    // Nothing of this set's direction is remembered for the next Start.
    _origRequest = nil; _plan = nil; _lastRequest = nil;
    _focus = nil; _focusTracks = nil; _focusRelated = nil; _focusMode = 0; _focusCrew = nil; _focusPlain = NO;
    _pool = nil; _poolKey = nil;
    [MRGVoiceSpeaker.shared stop];
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

// The system prompt: who the DJ is (persona), how to curate, the JSON shape, and the listener's own instructions.
// 0.5.2: a line that still reads like invented trivia ("sent this beat over dm at 4 am", "recorded live with a local
// brass crew") is dropped; the DJ says nothing over that song rather than something false.
static NSString *factCheckedLine(NSString *line) {
    if (![line isKindOfClass:NSString.class] || !line.length) return nil;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\b(dm'?d?|dms|recorded|produced( by)?|producer|in the studio|studio session|sampl(e|ed|es|ing)|sent (him|her|them|this|the|over)|"
              @"signed|label|went viral|charted|chart|billboard|platinum|gold record|grammy|tour(ed|ing)?|freestyl(e|ed) (it|this)|"
              @"wrote (it|this)|written (in|on|after)|made (it|this) (in|on|after|at)|cooked up|first take|one take|"
              @"at \\d{1,2} ?(am|pm|a\\.m\\.|p\\.m\\.)|in (19|20)\\d\\d|back in (19|20)\\d\\d|\\d+ (million|thousand|k) (streams|plays|views))\\b"
              options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if ([re numberOfMatchesInString:line options:0 range:NSMakeRange(0, line.length)]) {
        MRGDJLog(@"lines: dropped a line that states an unverified fact: \"%@\"", line.length > 90 ? [[line substringToIndex:90] stringByAppendingString:@"…"] : line);
        return nil;
    }
    return line;
}

static NSString *systemPrompt(void) {
    // 0.5.0: about half the words of 0.4.x (Groq's free tier ran out of daily tokens), same rules.
    NSMutableString *p = [NSMutableString string];
    [p appendFormat:@"You are Mirage DJ, a radio host and serious music curator inside the listener's Spotify. How you talk: %@ (speaking style only; it never picks the music).\n", MRGDJPersonaStyle()];
    [p appendString:
        @"Rules: 1) Every constraint in the request (genre, era, mood, energy, language, underground, like artist X) applies to every track. "
        @"2) Stay in their lane (now playing, history, top artists); go deeper, not wider. A named artist means that artist and their closest neighbours. "
        @"3) No obvious hits or filler; for underground requests pick small artists and deep cuts. "
        @"4) Max 2 songs per artist, nothing just played, no duplicates, ordered to flow. "
        @"5) Only real released songs with exact Spotify titles and primary artists; never invent.\n"
        @"6) NO MADE-UP FACTS: a line may only say how the song sounds or feels, why it fits the listener or the request, or how it flows from the last one. Never claim a fact you weren't given: no stories, who produced it, where or how it was recorded, DMs, studio sessions, samples, labels, dates, places, chart numbers or collaborations. If you're not handed a fact, talk about the vibe.\n"
        @"Reply with JSON only: {\"plan\": string, \"intro\": string, \"tracks\": [{\"artist\", \"title\", \"line\", \"why\"}]}\n"];
    [p appendFormat:@"plan: 1-2 sentences on the direction. Exactly 12 tracks. line: what you say before the track, at most %ld words, about its sound, mood or why it fits (rule 6), each different. why: 1-4 lowercase words (\"deep cut\", \"same scene\"). intro: at most 20 words, rule 6 applies.", (long)personaWords()];
    NSString *style = MRGDJStyleInstructions();
    if (style) [p appendFormat:@"\n\nFor line and intro: %@", style];
    NSString *custom = MRGDJCustomPrompt();
    if (custom) [p appendFormat:@"\n\nThe listener's own instructions (keep the JSON format):\n%@", custom];
    return p;
}

static NSInteger popularityCap(NSString *request) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"underground|obscure|deep ?cuts?|unknown|lesser[- ]known|hidden gems?|niche|no hits|not mainstream|non[- ]mainstream|small(er)? artists?|rare|b-?sides?|crate|undiscovered|under the radar|unheard" options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (request.length && [re numberOfMatchesInString:request options:0 range:NSMakeRange(0, request.length)]) return 50;
    if (MRGDJPersona() == 3) return 65;   // the underground curator leans that way on its own
    return 0;
}

- (NSString *)promptWithTaste:(NSArray *)top artists:(NSArray *)artists liked:(NSArray *)liked request:(NSString *)request {
    NSDictionary *now = MRGNowPlaying();
    NSMutableArray *played = [NSMutableArray arrayWithArray:MRGRecentHistory()];
    for (MRGDJTrack *t in _set) [played addObject:@{@"title": t.title ?: @"", @"artist": t.artist ?: @""}];
    NSMutableString *p = [NSMutableString string];
    [p appendFormat:@"Now playing: %@\n\n", now ? [NSString stringWithFormat:@"%@ — %@", now[@"title"], now[@"artist"] ?: @""] : @"(nothing)"];
    [p appendFormat:@"Just played:\n%@\n\n", listOf(played, 12)];
    [p appendFormat:@"Around it in the queue:\n%@\n\n", listOf(MRGQueueAround(), 5)];
    NSString *taste = MRGDJTasteText();
    if (taste) [p appendFormat:@"%@\n", taste];
    if (top.count) [p appendFormat:@"Their top and recent tracks:\n%@\n\n", listOf(top, 10)];
    if (artists.count) [p appendFormat:@"Their top artists: %@\n\n", [artists componentsJoinedByString:@", "]];
    if (liked.count) [p appendFormat:@"Songs they liked:\n%@\n\n", listOf(liked, 8)];
    BOOL seeded = !request.length && !_focus && now[@"artist"];
    if (seeded) {
        [p appendFormat:@"Request: none. SEED: the song playing right now, \"%@\" by %@. Build the whole set out of this song: its scene, sound, era and energy, artists right next to %@. Their top artists and history above may supply at most 2 picks, and only if they fit this seed. The intro must name %@ or the song.", now[@"title"] ?: @"?", now[@"artist"], now[@"artist"], now[@"artist"]];
    } else {
        [p appendFormat:@"Request: %@", request.length ? request : (_focus ? @"(keep going with the same artist focus)" : @"(none: just play something great for them right now)")];
    }
    if (_focus) {
        NSString *name = _focus[@"name"];
        NSArray *genres = [_focus[@"genres"] isKindOfClass:NSArray.class] ? _focus[@"genres"] : nil;
        if (_focusCrew.count) [p appendFormat:@"\n\nThe request is about a label / crew: %@. Count every one of them as 'the artist' below.", [self focusNames]];
        [p appendFormat:@"\n\nThe request is about the artist %@ (as Spotify has them%@).", name, genres.count ? [NSString stringWithFormat:@"; genres: %@", [genres componentsJoinedByString:@", "]] : @""];
        if (_focusTracks.count) {
            NSMutableArray *names = [NSMutableArray array];
            for (NSDictionary *t in _focusTracks) if (names.count < 8) [names addObject:[NSString stringWithFormat:@"- %@", t[@"title"]]];
            [p appendFormat:@"\nTheir songs on Spotify include:\n%@", [names componentsJoinedByString:@"\n"]];
        }
        if (_focusRelated.count) {
            NSMutableArray *rel = [NSMutableArray array];
            for (NSDictionary *a in _focusRelated) if (rel.count < 10 && a[@"name"]) [rel addObject:a[@"name"]];
            [p appendFormat:@"\nArtists Spotify relates to them: %@", [rel componentsJoinedByString:@", "]];
        }
        if (_focusMode == 4) [p appendFormat:@"\nThey just heard everything by %@. Now play artists that sound like them (same scene, sound and era; the related artists above first), NOT a single song by %@.", [self focusNames], [self focusNames]];
        else if (_focusMode == 2) [p appendFormat:@"\nEvery track must be by %@ (they asked for only them). Per-artist limits don't apply.", name];
        else if (_focusMode == 3) [p appendFormat:@"\nThey want music LIKE %@: 2-3 by %@, the rest by artists with the same sound and scene.", name, name];
        else [p appendFormat:@"\nAt least 7 tracks must be by %@ (the per-artist limit doesn't apply to them), the rest by artists right next to them in sound and scene. Nothing outside that lane.", name];
    }
    if (_pool.count) {
        NSArray *names = [_pool keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
        if (names.count > 20) names = [names subarrayWithRange:NSMakeRange(0, 20)];
        [p appendFormat:@"\n\nSeeds: %@. Spotify's related artists of these seeds and the listener's own history (closest first): %@.", [_poolSeeds componentsJoinedByString:@", "], [names componentsJoinedByString:@", "]];
        if (_poolHard) [p appendString:@"\nPick at least 12 of the 15 tracks by these artists or the seeds themselves; picks by artists outside this list are thrown out after 3. No generic indie or playlist filler that merely shares a mood."];
        else [p appendString:@"\nWhen they fit the request, prefer these artists over generic picks."];
    }
    NSInteger cap = popularityCap(request);
    if (cap) [p appendFormat:@"\n\nThis is an underground request: picks Spotify rates above %ld/100 popularity will be thrown out, so choose genuinely lesser-known songs.", (long)cap];
    return p;
}

static NSDictionary *parseJSON(NSString *text) {
    NSRange open = [text rangeOfString:@"{"], close = [text rangeOfString:@"}" options:NSBackwardsSearch];
    if (open.location == NSNotFound || close.location == NSNotFound || close.location < open.location) return nil;
    NSString *body = [text substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
    id json = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

#pragma mark - on-topic pool

static NSString *firstArtist(NSString *a) {
    NSString *s = a ?: @"";
    for (NSString *sep in @[@", ", @" & ", @" feat", @" x "]) { NSRange r = [s rangeOfString:sep]; if (r.location != NSNotFound && r.location > 0) s = [s substringToIndex:r.location]; }
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (BOOL)inPool:(NSString *)artist {
    if (!_pool.count) return YES;
    for (NSString *one in [[artist ?: @"" lowercaseString] componentsSeparatedByString:@", "]) {
        NSString *a = [one stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (_pool[a]) return YES;
        for (NSString *k in _pool) if (MRGNamesMatch(k, a)) return YES;
    }
    return NO;
}

// Concrete seeds (the requested artist, else what's playing and the most played artists Mirage saw), their related
// artists on Spotify (scored by how many seeds share them; a seed's genre search when related-artists is empty), plus
// the listener's own history artists. Time-boxed to 6 s; cached 10 min per seed list.
- (void)poolFor:(NSString *)request generation:(NSUInteger)gen done:(void (^)(void))done {
    NSMutableArray<NSString *> *seeds = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSString *> *display = [NSMutableDictionary dictionary];
    if (_focus[@"name"]) [seeds addObject:_focus[@"name"]];
    for (NSDictionary *a in _focusCrew) if ([a[@"name"] length] && ![seeds containsObject:a[@"name"]]) [seeds addObject:a[@"name"]];
    if (!_focus) {
        NSString *now = firstArtist(MRGNowPlaying()[@"artist"]);
        if (now.length) [seeds addObject:now];
        // With something playing, the seed is that song's artist (and their neighbours). History only adds a little:
        // 0.4.2 made the three most played artists seeds too, so Clairo took over every Start.
        NSUInteger maxSeeds = now.length ? 1 : 3;
        for (NSDictionary *h in [MRGRecentHistory() subarrayWithRange:NSMakeRange(0, MIN(MRGRecentHistory().count, (NSUInteger)40))]) {
            NSString *a = firstArtist(h[@"artist"]);
            if (!a.length) continue;
            counts[a.lowercaseString] = @(counts[a.lowercaseString].integerValue + 1);
            display[a.lowercaseString] = a;
        }
        NSArray *top = [counts keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
        for (NSString *k in top) {
            if (seeds.count >= maxSeeds) break;
            BOOL have = NO;
            for (NSString *x in seeds) if ([x.lowercaseString isEqualToString:k]) have = YES;
            if (!have && display[k]) [seeds addObject:display[k]];
        }
    }
    if (seeds.count > 3) [seeds removeObjectsInRange:NSMakeRange(3, seeds.count - 3)];
    _poolHard = _focus != nil || !request.length;
    NSString *key = [[seeds componentsJoinedByString:@"|"] lowercaseString];
    if (!seeds.count) { _pool = nil; _poolSeeds = nil; done(); return; }
    if ([key isEqualToString:_poolKey] && _pool.count && CACurrentMediaTime() - _poolTime < 600) { done(); return; }
    NSMutableDictionary<NSString *, NSNumber *> *pool = [NSMutableDictionary dictionary];
    for (NSString *k in counts) if (counts[k].integerValue >= 3) pool[k] = @1;   // their own repeats, a little
    for (NSString *sd in seeds) pool[sd.lowercaseString] = @3;
    __block BOOL finished = NO;
    void (^finish)(NSString *) = ^(NSString *why) {
        if (finished) return;
        finished = YES;
        if (gen != self->_generation) return;
        // Spotify's related-artists endpoint answers 404 to the app's token (0.4.2 log), so a pool can end up as just the
        // seeds; that small a pool would throw out every good neighbour, so it's only a hint then.
        if (pool.count < 8) self->_poolHard = NO;
        self->_pool = pool.count > seeds.count ? [pool copy] : nil;
        self->_poolSeeds = [seeds copy];
        self->_poolKey = key;
        self->_poolTime = CACurrentMediaTime();
        MRGDJLog(@"picks: seeds %@ → %lu artists in the pool%@ (%@)", [seeds componentsJoinedByString:@", "], (unsigned long)pool.count, self->_poolHard ? @", strict" : @", soft", why);
        done();
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(@"time box"); });
    dispatch_group_t g = dispatch_group_create();
    for (NSString *sd in seeds) {
        dispatch_group_enter(g);
        void (^withArtist)(NSDictionary *) = ^(NSDictionary *artist) {
            if (!artist) { dispatch_group_leave(g); return; }
            MRGWebRelatedArtists(artist, ^(NSArray<NSDictionary *> *related) {
                if (related.count) {
                    for (NSDictionary *r in related) {
                        NSString *n = [r[@"name"] lowercaseString];
                        if (n.length && pool[n].integerValue < 3) pool[n] = @(MIN(pool[n].integerValue + 1, 2));
                    }
                    dispatch_group_leave(g);
                    return;
                }
                NSArray *genres = [artist[@"genres"] isKindOfClass:NSArray.class] ? artist[@"genres"] : nil;
                if (!genres.count) { dispatch_group_leave(g); return; }
                MRGWebSearch([NSString stringWithFormat:@"genre:\"%@\"", genres.firstObject], @"artist", 10, ^(NSArray<NSDictionary *> *results, NSString *error) {
                    for (NSDictionary *r in results) { NSString *n = [r[@"name"] lowercaseString]; if (n.length && !pool[n]) pool[n] = @1; }
                    dispatch_group_leave(g);
                });
            });
        };
        if (self->_focus && [sd isEqualToString:self->_focus[@"name"]]) withArtist(self->_focus);
        else MRGWebFindArtist(sd, ^(NSDictionary *artist, NSString *how) { withArtist(artist); });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{ finish(@"done"); });
}

// Asks for a set and finds its tracks; `done` gets the found tracks in order (or an error) and the intro. For an
// underground request picks above the popularity cap are dropped, and when fewer than 8 are left the model is asked
// once more for replacements.
- (void)buildSetWithRequest:(NSString *)request generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSString *intro, NSString *error))done {
    [self poolFor:request generation:gen done:^{
        if (gen != self->_generation) return;
        [self buildSetFromPoolWithRequest:request generation:gen done:done];
    }];
}

- (void)buildSetFromPoolWithRequest:(NSString *)request generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSString *intro, NSString *error))done {
    // Taste from Spotify's own player only: what is playing, what Mirage saw play, and the queue around it. The Web API's
    // user endpoints (/me/top, /me/tracks, recently-played) answer 404 to the app's token, so they aren't called.
    NSString *prompt = [self promptWithTaste:nil artists:nil liked:nil request:request];
    NSString *system = systemPrompt();
    NSInteger cap = popularityCap(request);
    MRGAIChat(system, prompt, YES, ^(NSString *text, NSString *error) {
        if (gen != self->_generation) return;
        if (error) { done(nil, nil, error); return; }
        NSDictionary *json = parseJSON(text);
        NSArray *items = [json[@"tracks"] isKindOfClass:NSArray.class] ? json[@"tracks"] : nil;
        if (!items.count) { done(nil, nil, [NSString stringWithFormat:@"%@ didn't send a playlist I could read. Try again.", MRGProviderName(MRGAIProvider())]); return; }
        NSString *intro = factCheckedLine(json[@"intro"]);
        NSString *plan = [json[@"plan"] isKindOfClass:NSString.class] ? json[@"plan"] : nil;
        if (plan.length) { self->_plan = [plan copy]; MRGDJLog(@"plan: %@", plan); }
        [self resolve:items cap:cap generation:gen done:^(NSArray<MRGDJTrack *> *found, NSArray<MRGDJTrack *> *dropped, NSString *resolveError) {
            if (gen != self->_generation) return;
            // A second request only when an underground set kept fewer than 5 (0.4.4 asked below 8: twice the tokens).
            if (found.count >= 5 || (!cap && found.count)) { done(found, intro, nil); return; }
            // Refill once: what's kept, what was too popular or not found, and ask for more in the same plan.
            NSMutableString *more = [prompt mutableCopy];
            [more appendFormat:@"\n\nYour plan: %@\nAlready picked (keep, don't repeat):\n%@\n", plan ?: @"(same request)", listOf([self dicts:found], 15)];
            if (dropped.count) [more appendFormat:@"Thrown out (too popular or not on Spotify, don't repeat):\n%@\n", listOf([self dicts:dropped], 20)];
            [more appendFormat:@"Send %lu more tracks in the same JSON format that fit the plan%@.", (unsigned long)(12 - found.count), cap ? @" and are genuinely lesser-known" : @""];
            MRGDJLog(@"set: only %lu usable picks, asking for more", (unsigned long)found.count);
            MRGAIChat(system, more, YES, ^(NSString *text2, NSString *error2) {
                if (gen != self->_generation) return;
                NSDictionary *json2 = error2 ? nil : parseJSON(text2);
                NSArray *items2 = [json2[@"tracks"] isKindOfClass:NSArray.class] ? json2[@"tracks"] : nil;
                if (!items2.count) {
                    if (found.count) done(found, intro, nil);
                    else done(nil, nil, error2 ?: resolveError ?: @"Couldn't find those songs on Spotify. Try again.");
                    return;
                }
                [self resolve:items2 cap:cap generation:gen done:^(NSArray<MRGDJTrack *> *found2, NSArray<MRGDJTrack *> *dropped2, NSString *e3) {
                    if (gen != self->_generation) return;
                    NSMutableArray *all = [found mutableCopy];
                    NSMutableSet *seen = [NSMutableSet setWithArray:urisOf(found)];
                    for (MRGDJTrack *t in found2) if (![seen containsObject:t.uri] && all.count < 15) { [seen addObject:t.uri]; [all addObject:t]; }
                    // Still too few under the cap: rather the least popular of what was dropped than nothing.
                    if (all.count < 5) {
                        NSMutableArray *rest0 = [NSMutableArray array];
                        for (MRGDJTrack *t in [dropped arrayByAddingObjectsFromArray:dropped2]) if (t.uri.length) [rest0 addObject:t];
                        NSArray *rest = rest0;
                        rest = [rest sortedArrayUsingComparator:^NSComparisonResult(MRGDJTrack *x, MRGDJTrack *y) { return x.popularity < y.popularity ? NSOrderedAscending : x.popularity > y.popularity ? NSOrderedDescending : NSOrderedSame; }];
                        for (MRGDJTrack *t in rest) if (![seen containsObject:t.uri] && all.count < 8) { [seen addObject:t.uri]; [all addObject:t]; }
                    }
                    if (all.count) done(all, intro, nil);
                    else done(nil, nil, e3 ?: resolveError ?: @"Couldn't find those songs on Spotify. Try again.");
                }];
            });
        }];
    });
}

- (NSArray *)dicts:(NSArray<MRGDJTrack *> *)tracks {
    NSMutableArray *a = [NSMutableArray array];
    for (MRGDJTrack *t in tracks) [a addObject:@{@"title": t.title ?: @"", @"artist": t.artist ?: @""}];
    return a;
}

- (void)resolve:(NSArray *)items cap:(NSInteger)cap generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSArray<MRGDJTrack *> *, NSString *))done {
    NSMutableArray *slots = [NSMutableArray array];
    for (id item in items) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *title = item[@"title"], *artist = item[@"artist"], *line = item[@"line"], *why = item[@"why"];
        if (![title isKindOfClass:NSString.class] || !title.length) continue;
        MRGDJTrack *t = [MRGDJTrack new];
        t.title = title;
        t.artist = [artist isKindOfClass:NSString.class] ? artist : @"";
        t.line = factCheckedLine(line);
        t.why = [why isKindOfClass:NSString.class] && why.length && why.length <= 32 ? why : nil;
        [slots addObject:t];
        if (slots.count >= 18) break;
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
            if ([track[@"popularity"] isKindOfClass:NSNumber.class]) t.popularity = [track[@"popularity"] integerValue];
            if (error) lastError = error;
            dispatch_group_leave(g);
        });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (gen != self->_generation) return;
        NSMutableArray *found = [NSMutableArray array], *dropped = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSMutableDictionary<NSString *, NSNumber *> *perArtist = [NSMutableDictionary dictionary];
        NSUInteger tooPopular = 0, unrated = 0, offPool = 0, offDropped = 0;
        for (MRGDJTrack *t in slots) {
            if (!t.uri) { [dropped addObject:t]; continue; }
            if ([seen containsObject:t.uri]) continue;
            NSString *ak = t.artist.lowercaseString ?: @"";
            BOOL focusArtist = self->_focusMode != 4 && [self isFocusArtist:t.artist];
            if (perArtist[ak].integerValue >= 2 && !focusArtist) continue;
            if (t.popularity < 0) unrated++;
            if (cap && t.popularity > cap) { tooPopular++; [dropped addObject:t]; continue; }
            if (self->_pool.count && self->_poolHard && !focusArtist && ![self inPool:t.artist]) {
                if (offPool >= 3) { offDropped++; [dropped addObject:t]; continue; }
                offPool++;
            }
            [seen addObject:t.uri];
            perArtist[ak] = @(perArtist[ak].integerValue + 1);
            [found addObject:t];
            if (found.count >= 15) break;
        }
        if (self->_pool.count) MRGDJLog(@"picks: %lu off-topic kept, %lu off-topic dropped (not near %@)", (unsigned long)offPool, (unsigned long)offDropped, [self->_poolSeeds componentsJoinedByString:@", "]);
        MRGDJLog(@"set: %lu picks, %lu kept%@%@%@", (unsigned long)slots.count, (unsigned long)found.count,
                 cap ? [NSString stringWithFormat:@", %lu over popularity %ld dropped", (unsigned long)tooPopular, (long)cap] : @"",
                 unrated ? [NSString stringWithFormat:@", %lu without a popularity from search", (unsigned long)unrated] : @"",
                 lastError ? [@", last error: " stringByAppendingString:lastError] : @"");
        done(found, dropped, lastError);
    });
}

// The listener's top artists, for the model to read an abbreviation in their context.
static NSString *tasteArtists(void) {
    NSDictionary *t = MRGHistoryTaste();
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (id n in [t[@"recentArtists"] isKindOfClass:NSArray.class] ? t[@"recentArtists"] : @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
    for (id n in [t[@"allTimeArtists"] isKindOfClass:NSArray.class] ? t[@"allTimeArtists"] : @[]) if ([n isKindOfClass:NSString.class]) [names addObject:n];
    NSArray *a = names.array;
    if (a.count > 14) a = [a subarrayWithRange:NSMakeRange(0, 14)];
    return a.count ? [a componentsJoinedByString:@", "] : @"(unknown)";
}

- (BOOL)isFocusArtist:(NSString *)artist {
    if (!_focus) return NO;
    if (MRGNamesMatch(artist, _focus[@"name"])) return YES;
    for (NSDictionary *a in _focusCrew) if (MRGNamesMatch(artist, a[@"name"])) return YES;
    return NO;
}

- (NSString *)focusNames {
    if (!_focusCrew.count) return _focus[@"name"] ?: @"";
    NSMutableArray *n = [NSMutableArray array];
    for (NSDictionary *a in _focusCrew) [n addObject:a[@"name"] ?: @""];
    return [n componentsJoinedByString:@", "];
}

// Resolves several artist names on Spotify at once (in order, the ones not found left out).
static void findAll(NSArray<NSString *> *names, void (^done)(NSArray<NSDictionary *> *)) {
    NSMutableArray *slots = [NSMutableArray array];
    for (NSUInteger i = 0; i < names.count; i++) [slots addObject:[NSNull null]];
    dispatch_group_t g = dispatch_group_create();
    for (NSUInteger i = 0; i < names.count; i++) {
        dispatch_group_enter(g);
        MRGWebFindArtist(names[i], ^(NSDictionary *a, NSString *how) { if (a) slots[i] = a; dispatch_group_leave(g); });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableArray *out = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (id a in slots) if ([a isKindOfClass:NSDictionary.class] && ![seen containsObject:a[@"uri"]]) { [seen addObject:a[@"uri"]]; [out addObject:a]; }
        done(out);
    });
}

// Finds what a request is about, the same way for every entry point (the sheet's vibe box, the chat, play_artist):
//  1. Spotify: artist search as typed and in capitals, fuzzy names and initials, then track and combined searches.
//  2. When that match is weak (nothing, a tiny artist, a short abbreviation, or only found through a track), the
//     model reads the text with the listener's top artists: an artist nickname, or a label / crew ("yvl" is Playboi
//     Carti's Young Vamp Life imprint, not the 13-listener artist called YVL), and its artists are found on Spotify.
//  3. A label or crew also gets an album search on label:"…" for its roster.
// Every outcome is logged as one "focus:" line with the raw text and what it resolved to. done runs on the main queue.
- (void)focusFor:(NSString *)request generation:(NSUInteger)gen done:(void (^)(void))done {
    NSInteger mode = 0;
    BOOL plain = NO;
    NSString *candidate = artistCandidate(request, &mode, &plain);
    if (!candidate) { if (request.length && ![request hasPrefix:@"Switch it up"] && request.length < 120) MRGDJLog(@"focus: [vibe] \"%@\" doesn't read as an artist, a normal set", request); done(); return; }
    [self setStatusText:@"Finding the artist…"];
    void (^use)(NSArray<NSDictionary *> *, NSString *, NSString *) = ^(NSArray<NSDictionary *> *artists, NSString *label, NSString *how) {
        if (gen != self->_generation) return;
        NSDictionary *artist = artists.firstObject;
        if (!artist) { MRGDJLog(@"focus: [vibe] \"%@\" → no artist found (%@), a normal set", candidate, how ?: @"?"); done(); return; }
        self->_focus = artist;
        self->_focusCrew = artists.count > 1 ? artists : nil;
        self->_focusMode = mode;
        self->_focusPlain = plain && mode != 3;
        if (self->_focusCrew) MRGDJLog(@"focus: [artist] \"%@\" → %@ %@: %@ (%@, mode %ld%@)", candidate, label.length ? @"label/crew" : @"artists", label ?: @"", [self focusNames], how, (long)mode, self->_focusPlain ? @", catalog" : @"");
        else MRGDJLog(@"focus: [artist] \"%@\" → %@ (%@) via %@%@ (mode %ld%@)", candidate, artist[@"name"], artist[@"uri"], how,
                      [artist[@"popularity"] isKindOfClass:NSNumber.class] ? [NSString stringWithFormat:@", popularity %@", artist[@"popularity"]] : @"", (long)mode, self->_focusPlain ? @", catalog" : @"");
        [self setStatusText:[NSString stringWithFormat:@"Digging into %@…", self->_focusCrew ? (label.length ? label : artist[@"name"]) : artist[@"name"]]];
        MRGWebArtistTracks(artist, 12, ^(NSArray<NSDictionary *> *tracks) {
            if (gen != self->_generation) return;
            self->_focusTracks = tracks;
            MRGWebRelatedArtists(artist, ^(NSArray<NSDictionary *> *related) {
                if (gen != self->_generation) return;
                self->_focusRelated = related;
                MRGDJLog(@"focus: %lu of their tracks, %lu related artists", (unsigned long)tracks.count, (unsigned long)related.count);
                done();
            });
        });
    };
    MRGWebFindArtist(candidate, ^(NSDictionary *found, NSString *how) {
        if (gen != self->_generation) return;
        NSNumber *pop = [found[@"popularity"] isKindOfClass:NSNumber.class] ? found[@"popularity"] : nil;
        NSString *letters = [[candidate componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
        BOOL weak = !found || (pop && pop.integerValue < 25) || ![how isEqualToString:@"artist search"] || letters.length <= 4;
        if (!weak) { use(@[found], nil, [NSString stringWithFormat:@"Spotify %@", how]); return; }
        MRGDJLog(@"focus: \"%@\" → Spotify's closest is %@%@, asking %@ what it means", candidate, found ? found[@"name"] : @"nothing",
                 pop ? [NSString stringWithFormat:@" (popularity %@)", pop] : @"", MRGProviderName(MRGAIProvider()));
        NSString *ask = [NSString stringWithFormat:
            @"A listener typed \"%@\" into their music app to ask for music.\nTheir top artists: %@.\nSpotify's closest artist match: %@.\n\n"
            @"What do they most likely mean? Think of artist nicknames and abbreviations (\"uzi\" = Lil Uzi Vert, \"carti\" = Playboi Carti, \"pz\" can be an artist), "
            @"record labels, imprints and crews (\"opium\" = Playboi Carti's label: Ken Carson, Destroy Lonely, Homixide Gang; \"yvl\" = Young Vamp Life, Carti's newer imprint: ApolloRed1 and its signees), "
            @"and who fits their taste. A tiny artist that merely has the same name is usually NOT what they mean.\n"
            @"Answer JSON only: {\"kind\": \"artist\" | \"label\" | \"crew\" | \"none\", \"artists\": [up to 6 exact Spotify artist names, the main one first], \"label\": string or null, \"spotify_match_is_right\": true or false}",
            candidate, tasteArtists(), found ? [NSString stringWithFormat:@"%@%@", found[@"name"], pop ? [NSString stringWithFormat:@" (popularity %@/100)", pop] : @""] : @"none"];
        MRGAIChat(@"You identify music artists, labels and crews from slang, nicknames, abbreviations and typos. Answer only JSON.", ask, YES, ^(NSString *text, NSString *error) {
            if (gen != self->_generation) return;
            NSDictionary *j = text ? parseJSON(text) : nil;
            NSString *kind = [j[@"kind"] isKindOfClass:NSString.class] ? [j[@"kind"] lowercaseString] : nil;
            NSMutableArray *names = [NSMutableArray array];
            for (id n in [j[@"artists"] isKindOfClass:NSArray.class] ? j[@"artists"] : @[]) if ([n isKindOfClass:NSString.class] && [n length] && names.count < 6) [names addObject:n];
            if (!names.count && [j[@"artist"] isKindOfClass:NSString.class]) [names addObject:j[@"artist"]];
            NSString *label = [j[@"label"] isKindOfClass:NSString.class] && [j[@"label"] length] ? j[@"label"] : nil;
            BOOL spotifyRight = [j[@"spotify_match_is_right"] respondsToSelector:@selector(boolValue)] && [j[@"spotify_match_is_right"] boolValue];
            BOOL group = [kind isEqualToString:@"label"] || [kind isEqualToString:@"crew"];
            MRGDJLog(@"focus: the model read \"%@\" as %@%@%@", candidate, error ? @"(no answer)" : kind ?: @"?", names.count ? [@": " stringByAppendingString:[names componentsJoinedByString:@", "]] : @"", error ? [@" — " stringByAppendingString:error] : @"");
            void (^withLabel)(NSArray<NSDictionary *> *, NSString *) = ^(NSArray<NSDictionary *> *resolved, NSString *how2) {
                // A label's roster from Spotify too (album search label:"…"), merged after the model's names.
                void (^merge)(NSArray<NSDictionary *> *);
                merge = ^(NSArray<NSDictionary *> *roster) {
                    if (gen != self->_generation) return;
                    NSMutableArray *all = [resolved mutableCopy];
                    NSMutableSet *seen = [NSMutableSet set];
                    for (NSDictionary *a in all) [seen addObject:a[@"uri"]];
                    for (NSDictionary *a in roster) if (![seen containsObject:a[@"uri"]] && all.count < 6) { [seen addObject:a[@"uri"]]; [all addObject:a]; }
                    if (all.count) { use(all, label ?: candidate, roster.count ? [how2 stringByAppendingString:@" + label search"] : how2); return; }
                    use(found ? @[found] : @[], nil, found ? @"Spotify's match (nothing better)" : @"nothing on Spotify");
                };
                // The label as the model named it ("Young Vamp Life"), then as typed ("yvl") when that finds nothing.
                MRGWebLabelArtists(label ?: candidate, ^(NSArray<NSDictionary *> *roster) {
                    if (roster.count || !label || [label caseInsensitiveCompare:candidate] == NSOrderedSame) { merge(roster); return; }
                    MRGWebLabelArtists(candidate, merge);
                });
            };
            if (error || !kind) {
                // No answer (a rate limit, say): Spotify's match, or a label search for a short tag with only a tiny match.
                if (!found || (pop && pop.integerValue < 10 && letters.length <= 6)) { withLabel(@[], @"label search"); return; }
                use(@[found], nil, [NSString stringWithFormat:@"Spotify %@ (the model didn't answer)", how]);
                return;
            }
            if ([kind isEqualToString:@"none"] && !names.count) {
                if (found) use(@[found], nil, [NSString stringWithFormat:@"Spotify %@", how]);
                else { MRGDJLog(@"focus: \"%@\" isn't an artist, a normal set", candidate); done(); }
                return;
            }
            if (spotifyRight && found && !group) { use(@[found], nil, [NSString stringWithFormat:@"Spotify %@, confirmed by the model", how]); return; }
            findAll(names, ^(NSArray<NSDictionary *> *resolved) {
                if (gen != self->_generation) return;
                if (group) { withLabel(resolved, @"the model"); return; }
                if (resolved.count) { use(@[resolved.firstObject], nil, @"the model's reading, found on Spotify"); return; }
                if (found) use(@[found], nil, [NSString stringWithFormat:@"Spotify %@ (the model's names weren't found)", how]);
                else withLabel(@[], @"label search");
            });
        });
    });
}

static MRGDJTrack *trackFrom(NSDictionary *d) {
    MRGDJTrack *t = [MRGDJTrack new];
    t.uri = d[@"uri"]; t.title = d[@"title"] ?: @""; t.artist = d[@"artist"] ?: @""; t.image = d[@"image"];
    if ([d[@"popularity"] isKindOfClass:NSNumber.class]) t.popularity = [d[@"popularity"] integerValue];
    return t;
}

// An artist set has to be that artist: when the model's picks have too few of their songs, their own top tracks are
// woven in (every other slot), and with no usable picks at all the set is their top tracks. After their catalog
// (mode 4) it's the other way round: their own songs are left out, the listener just heard them.
- (NSArray<MRGDJTrack *> *)ensureFocus:(NSArray<MRGDJTrack *> *)found {
    if (!_focus) return found;
    if (_focusMode == 4) {
        NSMutableArray *out = [NSMutableArray array];
        NSUInteger dropped = 0;
        for (MRGDJTrack *t in found) { if ([self isFocusArtist:t.artist]) dropped++; else [out addObject:t]; }
        if (dropped) MRGDJLog(@"focus: %lu of %@'s own songs left out of the similar-artists set", (unsigned long)dropped, _focus[@"name"]);
        return out.count ? out : found;
    }
    if (!_focusTracks.count) return found;
    NSString *name = _focus[@"name"];
    NSUInteger want = _focusMode == 2 ? 12 : _focusMode == 3 ? 2 : 6;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger have = 0;
    for (MRGDJTrack *t in found) {
        BOOL theirs = [self isFocusArtist:t.artist];
        if (_focusMode == 2 && !theirs) continue;
        if (t.uri && ![seen containsObject:t.uri]) { [seen addObject:t.uri]; [out addObject:t]; if (theirs) have++; }
    }
    NSMutableArray *extra = [NSMutableArray array];
    for (NSDictionary *d in _focusTracks) if (d[@"uri"] && ![seen containsObject:d[@"uri"]]) [extra addObject:d];
    NSUInteger added = 0, slot = 0;
    while (have < want && extra.count) {
        NSDictionary *d = extra.firstObject; [extra removeObjectAtIndex:0];
        MRGDJTrack *t = trackFrom(d);
        t.why = @"their essentials";
        NSUInteger at = MIN(out.count, slot);
        [out insertObject:t atIndex:at];
        [seen addObject:t.uri];
        slot = at + 2;
        have++; added++;
    }
    if (added) MRGDJLog(@"focus: %lu of %@'s own tracks added so the set is really theirs", (unsigned long)added, name);
    return out.count > 15 ? [out subarrayWithRange:NSMakeRange(0, 15)] : out;
}

// "play <artist>": as much of their catalog as Spotify lists (top tracks, then albums and singles, de-duplicated, up to
// kCatalogMax), or for a label / crew each artist's top tracks taken in turns. Similar artists follow when it runs low.
static const NSInteger kCatalogMax = 80;

- (void)catalogFor:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *))done {
    void (^finish)(NSArray<NSDictionary *> *, NSString *) = ^(NSArray<NSDictionary *> *dicts, NSString *why) {
        if (gen != self->_generation) return;
        NSMutableArray *set = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        for (NSDictionary *d in dicts) {
            if (![d[@"uri"] isKindOfClass:NSString.class] || [seen containsObject:d[@"uri"]]) continue;
            [seen addObject:d[@"uri"]];
            MRGDJTrack *t = trackFrom(d);
            t.why = why;
            [set addObject:t];
            if (set.count >= (NSUInteger)kCatalogMax) break;
        }
        done(set);
    };
    if (!_focusCrew.count) {
        [self setStatusText:[NSString stringWithFormat:@"Pulling everything by %@…", _focus[@"name"]]];
        MRGWebArtistCatalog(_focus, kCatalogMax, ^(NSArray<NSDictionary *> *tracks) { finish(tracks, @"their catalog"); });
        return;
    }
    [self setStatusText:[NSString stringWithFormat:@"Pulling %@…", [self focusNames]]];
    NSArray *crew = _focusCrew;
    NSMutableArray *per = [NSMutableArray array];
    for (NSUInteger i = 0; i < crew.count; i++) [per addObject:@[]];
    dispatch_group_t g = dispatch_group_create();
    for (NSUInteger i = 0; i < crew.count; i++) {
        dispatch_group_enter(g);
        MRGWebArtistTracks(crew[i], 12, ^(NSArray<NSDictionary *> *tracks) { per[i] = tracks ?: @[]; dispatch_group_leave(g); });
    }
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        NSMutableArray *mixed = [NSMutableArray array];
        for (NSUInteger round = 0; round < 12; round++)
            for (NSArray *list in per) if (round < list.count) [mixed addObject:list[round]];
        MRGDJLog(@"catalog: %lu tracks from %lu artists of %@", (unsigned long)mixed.count, (unsigned long)crew.count, self->_focus[@"name"]);
        finish(mixed, @"the crew");
    });
}

// A few lines for the start of a catalog run (an intro and one per song for the first six), at most 6 seconds late.
- (void)catalogLines:(NSArray<MRGDJTrack *> *)set generation:(NSUInteger)gen done:(void (^)(NSString *intro))done {
    __block BOOL called = NO;
    void (^once)(NSString *) = ^(NSString *intro) { if (called || gen != self->_generation) return; called = YES; done(intro); };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!called) MRGDJLog(@"catalog: lines took too long, playing without them"); once(nil); });
    NSMutableString *list = [NSMutableString string];
    for (NSUInteger i = 0; i < MIN(set.count, (NSUInteger)6); i++) [list appendFormat:@"%lu. %@ — %@\n", (unsigned long)i + 1, set[i].title, set[i].artist];
    NSString *who = _focusCrew.count ? [NSString stringWithFormat:@"the %@ crew (%@)", _focus[@"name"], [self focusNames]] : _focus[@"name"];
    NSMutableString *system = [NSMutableString stringWithFormat:@"You are Mirage DJ, the host of the listener's personal radio show. How you talk: %@", MRGDJPersonaStyle()];
    NSString *style = MRGDJStyleInstructions();
    if (style) [system appendFormat:@"\n\n%@", style];
    NSString *user = [NSString stringWithFormat:@"You're about to play everything you can find by %@ (%lu songs), then artists like them. It starts with:\n%@\n"
                      @"Answer JSON only: {\"intro\": string (opens the run, at most 20 words), \"lines\": [{\"title\": string, \"line\": string (at most %ld words, about how that song sounds or feels; no made-up facts, no stories about how it was made)}] for those songs}.",
                      who, (unsigned long)set.count, list, (long)personaWords()];
    MRGAIChat(system, user, YES, ^(NSString *text, NSString *error) {
        if (gen != self->_generation) return;
        NSDictionary *j = text ? parseJSON(text) : nil;
        for (NSDictionary *l in [j[@"lines"] isKindOfClass:NSArray.class] ? j[@"lines"] : @[]) {
            if (![l isKindOfClass:NSDictionary.class] || ![l[@"line"] isKindOfClass:NSString.class] || ![l[@"title"] isKindOfClass:NSString.class]) continue;
            for (MRGDJTrack *t in set) if (!t.line && MRGNamesMatch(t.title, l[@"title"])) { t.line = factCheckedLine(l[@"line"]); break; }
        }
        if (error) MRGDJLog(@"catalog: no lines (%@)", error);
        once(factCheckedLine(j[@"intro"]));
    });
}

- (void)startWithRequest:(NSString *)request {
    if (MRGAIProvider() == MRGProviderNone) { [self fail:@"Add your AI provider's API key in Mirage settings first."]; return; }
    NSUInteger gen = ++_generation;
    _lastRequest = [request copy];
    if (![request hasPrefix:@"Switch it up:"]) { _origRequest = [request copy]; _plan = nil; _pool = nil; _poolKey = nil; }
    MRGDJLog(@"start: %@ with %@ (%@)", request.length ? @"a request" : @"no request", MRGProviderName(MRGAIProvider()), MRGAIModel() ?: @"?");
    _state = MRGDJThinking;
    _error = nil;
    _next = nil;
    _fetchingNext = NO;
    [self setStatusText:request.length ? @"On it…" : @"Reading the room…"];
    _focus = nil; _focusTracks = nil; _focusRelated = nil; _focusMode = 0; _focusCrew = nil; _focusPlain = NO;
    // Only one thing at a time: the line being said (or fetched) for the old set stops now, not over the new one.
    [self quiet];
    NSString *songTitle = nil, *songArtist = nil;
    NSInteger kind = requestKind(request, &songTitle, &songArtist);
    if (kind == 2 || kind == 3) { [self playNamed:songTitle album:kind == 3 request:request generation:gen]; return; }
    if (kind == 1 || kind == 4) { [self findSong:songTitle artist:songArtist maybe:kind == 4 request:request generation:gen]; return; }
    [self focusThenPlay:request generation:gen];
}

// The artist / vibe path: focus, then the artist's catalog or a DJ set.
- (void)focusThenPlay:(NSString *)request generation:(NSUInteger)gen {
    [self focusFor:request generation:gen done:^{
        if (gen != self->_generation) return;
        void (^modelSet)(void) = ^{
            [self setStatusText:@"Picking the songs…"];
            [self buildSetWithRequest:request generation:gen done:^(NSArray<MRGDJTrack *> *found, NSString *intro, NSString *error) {
                if (gen != self->_generation) return;
                NSArray *set = [self ensureFocus:found ?: @[]];
                if (!set.count) { [self fail:error ?: @"Couldn't find those songs on Spotify. Try again."]; return; }
                if (error) MRGDJLog(@"set: the model failed (%@), playing the artist's own tracks", error);
                [self playSet:set intro:intro generation:gen fresh:YES];
            }];
        };
        if (!self->_focus || !self->_focusPlain) { modelSet(); return; }
        [self catalogFor:gen done:^(NSArray<MRGDJTrack *> *set) {
            if (gen != self->_generation) return;
            if (set.count < 5) { MRGDJLog(@"catalog: only %lu tracks, a DJ set around them instead", (unsigned long)set.count); modelSet(); return; }
            MRGDJLog(@"catalog: playing %lu tracks by %@, similar artists after", (unsigned long)set.count, [self focusNames]);
            [self setStatusText:@"Lining it up…"];
            [self catalogLines:set generation:gen done:^(NSString *intro) {
                if (gen != self->_generation) return;
                self->_plan = [NSString stringWithFormat:@"Everything by %@, then artists that sound like them.", self->_focusCrew.count ? [self focusNames] : self->_focus[@"name"]];
                self->_focusMode = 4;   // what comes after the catalog: similar artists only
                [self playSet:set intro:intro generation:gen fresh:YES];
            }];
        }];
    }];
}


static NSString *normTitle(NSString *s) {
    NSString *t = [s ?: @"" lowercaseString];
    t = replaced(t, @"\\s*[\\(\\[].*?[\\)\\]]", @"");
    t = replaced(t, @"\\s+-\\s+.*$", @"");
    t = [[t componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet] componentsJoinedByString:@""];
    return t;
}

// What a typed request is: 1 a song ("play orula by victor mendivil", "play the song orula"), 4 maybe a song ("play
// orula": checked against Spotify), 2 a playlist, 3 an album ("play the playlist leaked lucki", "leaked lucki playlist");
// 0 anything else (an artist or a vibe: the focus path). title/artist get the names.
static NSInteger requestKind(NSString *request, NSString **title, NSString **artist) {
    NSString *r = [request ?: @"" stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .!?\n"]];
    if (!r.length || r.length > 120 || [r hasPrefix:@"Switch it up"]) return 0;
    for (int i = 0; i < 2; i++) r = replaced(r, @"^(?:yo|hey|ayo|aye|bro|dj|pls|please|can you|could you|u|you|now)[,!]?\\s+", @"");
    r = replaced(r, @"\\s+(?:pls|please|rn|right now|now|for me|bro|fr)$", @"");
    NSString *verb = @"(?:play|put on|queue up|queue|spin|throw on|bump|blast|start|shuffle|run|gimme|give me|i want to hear|i wanna hear|let me hear)";
    if (matches(r, @"\\b(?:playlist|album|mixtape|ep)\\b")) {
        BOOL album = matches(r, @"\\b(?:album|mixtape|ep)\\b");
        NSString *t = replaced(r, [NSString stringWithFormat:@"^%@\\s+", verb], @"");
        t = replaced(t, @"\\b(?:the|my|his|her|their|that|a)\\s+(?:playlist|album|mixtape|ep)(?:\\s+(?:called|named))?\\b", @"");
        t = replaced(t, @"\\b(?:playlist|album|mixtape|ep)(?:\\s+(?:called|named))?\\b", @"");
        t = replaced(t, @"^\\s*(?:the|my)\\s+", @"");
        t = [t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \"'“”‘’"]];
        if (!t.length) return 0;
        *title = t;
        return album ? 3 : 2;
    }
    NSRegularExpression *by = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^(?:%@\\s+)?(?:the song\\s+|the track\\s+|song\\s+|track\\s+)?[\"“']?(.+?)[\"”']?\\s+by\\s+(.+)$", verb] options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [by firstMatchInString:r options:0 range:NSMakeRange(0, r.length)];
    if (m) {
        NSString *t = [r substringWithRange:[m rangeAtIndex:1]], *a = [r substringWithRange:[m rangeAtIndex:2]];
        // "play some songs by X", "play everything by X": the artist path.
        if (matches(t, @"^(?:me\\s+)?(?:some|sum|songs?|tracks?|music|stuff|something|anything|more|only|just|all|everything|the best|best|a few|vibes?|hits|bangers|deep cuts|underground|old|new|chill|sad|top|their|his|her)\\b")) return 0;
        *title = t; *artist = a;
        return 1;
    }
    NSRegularExpression *songOnly = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"^%@\\s+(the song|the track|song|track)?\\s*[\"“']?(.+?)[\"”']?$", verb] options:NSRegularExpressionCaseInsensitive error:nil];
    m = [songOnly firstMatchInString:r options:0 range:NSMakeRange(0, r.length)];
    if (!m) return 0;
    NSString *t = [r substringWithRange:[m rangeAtIndex:2]];
    BOOL said = [m rangeAtIndex:1].location != NSNotFound;
    if (!said && (matches(t, @"\\b(?:like|similar|songs?|tracks?|music|stuff|vibes?|mix|set|radio|some|sum|something|anything|only|just|more|underground|chill|sad|hype)\\b") || [t componentsSeparatedByString:@" "].count > 6)) return 0;
    *title = t;
    return said ? 1 : 4;
}

// "play the playlist leaked lucki": the listener's own playlists first (by name), then Spotify search, played as the
// context through the chat's play_context (one code path for both).
- (void)playNamed:(NSString *)name album:(BOOL)album request:(NSString *)request generation:(NSUInteger)gen {
    MRGDJLog(@"focus: [%@] \"%@\" → %@", album ? @"album" : @"playlist", name, album ? @"Spotify album search" : @"your playlists first, then Spotify search");
    [self setStatusText:album ? @"Finding the album…" : @"Finding the playlist…"];
    NSString *mine = request;
    [MRGChat.shared runTool:@"play_context" args:@{@"target": name ?: @"", @"kind": album ? @"album" : @"playlist"} done:^(id result) {
        if (self->_lastRequest != mine) return;   // a newer request took over
        NSString *err = [result isKindOfClass:NSDictionary.class] && [result[@"error"] isKindOfClass:NSString.class] ? result[@"error"] : nil;
        if (err) { MRGDJLog(@"focus: [%@] \"%@\" failed: %@", album ? @"album" : @"playlist", name, err); [self fail:err]; return; }
        self->_status = [NSString stringWithFormat:@"Playing the %@ %@", album ? @"album" : @"playlist", name];
        [self changed];
    }];
}

// The song itself (Web API track search with track: and artist: filters), playing first; the songs after it are
// picked from it by the refill, seeded by the song playing (similar songs and artists, not the artist's catalog).
- (void)findSong:(NSString *)title artist:(NSString *)artist maybe:(BOOL)maybe request:(NSString *)request generation:(NSUInteger)gen {
    [self setStatusText:@"Finding the song…"];
    NSString *want = normTitle(title);
    NSDictionary *(^pick)(NSArray *) = ^NSDictionary *(NSArray *results) {
        NSDictionary *best = nil;
        NSInteger bestScore = -1;
        for (NSDictionary *r in results) {
            if (![r isKindOfClass:NSDictionary.class] || ![r[@"uri"] isKindOfClass:NSString.class]) continue;
            BOOL exact = [normTitle(r[@"title"]) isEqualToString:want];
            if (!exact && !MRGNamesMatch(r[@"title"], title)) continue;
            BOOL byOK = !artist.length;
            for (NSString *a in [[r[@"artist"] ?: @"" description] componentsSeparatedByString:@", "]) if (artist.length && MRGNamesMatch(a, artist)) byOK = YES;
            if (!byOK) continue;
            NSInteger score = (exact ? 1000 : 0) + ([r[@"popularity"] isKindOfClass:NSNumber.class] ? [r[@"popularity"] integerValue] : 0);
            if (score > bestScore) { bestScore = score; best = r; }
        }
        return best;
    };
    void (^notSong)(NSString *) = ^(NSString *why) {
        if (gen != self->_generation) return;
        if (maybe) MRGDJLog(@"focus: \"%@\" isn't a song title on Spotify (%@), reading it as an artist or a vibe", title, why);
        else MRGDJLog(@"focus: [track] \"%@\"%@ not found on Spotify (%@), a set around it instead", title, artist.length ? [@" by " stringByAppendingString:artist] : @"", why);
        [self focusThenPlay:maybe ? request : [NSString stringWithFormat:@"songs like \"%@\"%@", title, artist.length ? [@" by " stringByAppendingString:artist] : @""] generation:gen];
    };
    void (^use)(NSDictionary *) = ^(NSDictionary *song) {
        if (gen != self->_generation) return;
        if (!maybe) { [self playSong:song request:request generation:gen]; return; }
        // "play X" alone: an artist called exactly X comes first ("play lucki"), unless the song is the far bigger name.
        MRGWebFindArtist(title, ^(NSDictionary *a, NSString *how) {
            if (gen != self->_generation) return;
            NSInteger ap = [a[@"popularity"] isKindOfClass:NSNumber.class] ? [a[@"popularity"] integerValue] : 0;
            NSInteger sp = [song[@"popularity"] isKindOfClass:NSNumber.class] ? [song[@"popularity"] integerValue] : 0;
            BOOL artistWins = a && [normTitle(a[@"name"]) isEqualToString:want] && (ap >= 20 || sp < 40);
            if (artistWins) { MRGDJLog(@"focus: \"%@\" is an artist (%@, popularity %ld) before a song of that name", title, a[@"name"], (long)ap); [self focusThenPlay:request generation:gen]; return; }
            [self playSong:song request:request generation:gen];
        });
    };
    NSString *q = artist.length ? [NSString stringWithFormat:@"track:\"%@\" artist:\"%@\"", title, artist] : [NSString stringWithFormat:@"track:\"%@\"", title];
    MRGWebSearch(q, @"track", 10, ^(NSArray<NSDictionary *> *results, NSString *error) {
        if (gen != self->_generation) return;
        NSDictionary *best = pick(results);
        if (best) { use(best); return; }
        if (!artist.length) { notSong(error ?: @"no title match"); return; }
        MRGWebResolve(title, artist, ^(NSDictionary *track, NSString *err) {
            if (gen != self->_generation) return;
            if (track[@"uri"]) use(track); else notSong(err ?: error ?: @"no match");
        });
    });
}

- (void)playSong:(NSDictionary *)song request:(NSString *)request generation:(NSUInteger)gen {
    MRGDJTrack *t = trackFrom(song);
    t.why = @"you asked for it";
    MRGDJLog(@"focus: [track] \"%@\" → %@ — %@ (%@), then songs like it", request, t.title, t.artist, t.uri);
    _plan = [NSString stringWithFormat:@"\"%@\" by %@ first, then songs that sound like it (similar artists, not their whole catalog).", t.title, t.artist];
    [self playSet:@[t] intro:nil generation:gen fresh:YES];
}

- (void)quiet {
    _speakToken++;
    [MRGVoiceSpeaker.shared stop];
    MRGDuckMusic(NO);
    if (_speaking) [self setSpeaking:NO line:nil];
}

#pragma mark - the vibe box: music or a question

static BOOL rx(NSString *s, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return s.length && re && [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}

static NSString *firstCapture(NSString *s, NSString *pattern) {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = s.length ? [re firstMatchInString:s options:0 range:NSMakeRange(0, s.length)] : nil;
    if (!m || m.numberOfRanges < 2 || [m rangeAtIndex:1].location == NSNotFound) return nil;
    return [[s substringWithRange:[m rangeAtIndex:1]] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ?!.,"]];
}

// 0: music request (a set), 1: about an artist, 2: about a song, 3: another question or chat.
// Questions get answers; anything that asks for music (play, songs, a vibe…) or reads like a vibe plays music.
static NSInteger intentOf(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (rx(t, @"^(who|whos|who's|who is|tell me about|what do you know about|info on)\\b.*") && !rx(t, @"\\b(play|queue|put on|throw on)\\b")) {
        if (rx(t, @"\\b(this|that|the) (song|track)\\b|\\bsings? this\\b|\\bmade this\\b|\\bproduced this\\b")) return 2;
        return 1;
    }
    if (rx(t, @"^(what|whats|what's|which)\\b.*\\b(this|that) (song|track)\\b|^what song is (this|that)\\b")) return 2;
    BOOL asks = rx(t, @"\\?\\s*$") || rx(t, @"^(what|whats|what's|when|where|why|how|is|are|was|were|does|did|do|can|could|should|would|will|explain|which|hey|hi|hello|yo|thanks|thank you)\\b");
    BOOL music = rx(t, @"\\b(play|put on|throw on|queue|run (it|some|sum|that)|spin|give me|gimme|songs?|tracks?|music|vibes?|playlist|bangers|mix|beats|switch it up|more like)\\b");
    if (asks && !music) return 3;
    if (asks && music && rx(t, @"\\b(this|that) (song|track|artist)\\b") && !rx(t, @"\\b(play|queue|more like|similar)\\b")) return 3;
    return 0;
}

- (void)handleInput:(NSString *)text {
    NSString *cmd = [[text ?: @"" lowercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .!?"]];
    NSDictionary *controls = @{@"skip": @"next", @"skip this": @"next", @"skip it": @"next", @"skip this song": @"next", @"next": @"next", @"next song": @"next",
                               @"pause": @"pause", @"stop": @"pause", @"resume": @"resume", @"play": @"resume", @"unpause": @"resume",
                               @"back": @"previous", @"go back": @"previous", @"previous": @"previous", @"last song": @"previous"};
    if (controls[cmd]) {
        // 0.4.2 read "skip this" as an artist called "skip this song".
        MRGDJLog(@"vibe box: \"%@\" → player %@", cmd, controls[cmd]);
        MRGPlayerControl(controls[cmd], ^(BOOL ok, NSString *error) { if (!ok) [self fail:error ?: @"Spotify's player refused."]; });
        return;
    }
    NSInteger intent = intentOf(text ?: @"");
    MRGDJLog(@"vibe box: \"%@\" → %@", text.length > 60 ? [[text substringToIndex:60] stringByAppendingString:@"…"] : text,
             @[@"music", @"artist question", @"song question", @"question"][intent]);
    if (intent == 0) { [self startWithRequest:text]; return; }
    if (MRGAIProvider() == MRGProviderNone) { [self fail:@"Add your AI provider's API key in Mirage settings first."]; return; }
    _error = nil;
    [self setStatusText:intent == 3 ? @"Thinking…" : @"Looking it up…"];
    NSDictionary *now = MRGNowPlaying();
    void (^reply)(NSString *, NSDictionary *, NSArray *) = ^(NSString *answer, NSDictionary *card, NSArray *sources) {
        self->_status = sources.count ? [@"Sources: " stringByAppendingString:[sources componentsJoinedByString:@" · "]] : nil;
        if (!answer.length) { [self fail:@"Couldn't find an answer to that."]; return; }
        self->_currentLine = [answer copy];
        [self changed];
        [self speak:answer];
        [MRGChat.shared noteQuestion:text answer:answer card:card];
    };
    NSString *persona = [NSString stringWithFormat:@"You are Mirage DJ, the listener's music host. How you talk: %@\nAnswer their question in at most 3 short sentences, spoken out loud (no lists, no markdown, no URLs). Don't start a set or suggest tapping anything.", MRGDJPersonaStyle()];
    if (intent == 3) {
        NSString *context = [NSString stringWithFormat:@"Playing now: %@. %@\n\nQuestion: %@",
                             now ? [NSString stringWithFormat:@"%@ — %@", now[@"title"], now[@"artist"] ?: @""] : @"nothing",
                             self->_plan.length ? [@"The DJ set's plan: " stringByAppendingString:self->_plan] : @"", text];
        MRGAIGrounded([persona stringByAppendingFormat:@"\n\n%@", context], ^(NSString *web, NSArray<NSDictionary *> *src, NSString *err) {
            if (web.length && src.count) {
                NSMutableArray *names = [NSMutableArray array];
                for (NSDictionary *x in src) [names addObject:x[@"title"] ?: @"web"];
                reply(web, nil, names);
                return;
            }
            MRGAIChat(persona, context, NO, ^(NSString *answer, NSString *error) {
                if (error) { [self fail:error]; return; }
                reply(answer, nil, nil);
            });
        });
        return;
    }
    void (^withInfo)(NSDictionary *) = ^(NSDictionary *info) {
        if (info[@"error"]) { [self fail:info[@"error"]]; return; }
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *x in info[@"sources"]) [names addObject:x[@"title"] ?: @"?"];
        NSString *prompt = [NSString stringWithFormat:@"Facts (the only things you may state):\n%@\nQuestion: %@\nIf the facts don't cover something, say you don't know it.", MRGInfoFacts(info), text];
        MRGAIChat(persona, prompt, NO, ^(NSString *answer, NSString *error) {
            NSString *fallback = info[@"wiki"][@"extract"] ?: info[@"web"][@"text"];
            if (error) MRGDJLog(@"vibe box: answer failed (%@), reading the summary instead", error);
            reply(answer.length ? answer : fallback, MRGInfoCard(info), names);
        });
    };
    if (intent == 2) {
        NSString *title = now[@"title"], *artist = now[@"artist"];
        NSString *named = firstCapture(text, @"(?:song|track)\\s+[\"“']?([^\"”'?]+?)[\"”']?\\s*(?:by\\s+(.+))?\\??$");
        if (named.length && !rx(named, @"^(this|that|is this|is that)$")) { title = named; artist = firstCapture(text, @"\\bby\\s+(.+?)\\??$") ?: @""; }
        if (!title.length) { [self fail:@"Nothing is playing, so I don't know which song you mean."]; return; }
        MRGTrackInfo(title, artist, withInfo);
        return;
    }
    NSString *who = firstCapture(text, @"^(?:who|whos|who's|who is|tell me about|what do you know about|info on)\\s+(?:is\\s+|are\\s+)?(.+)$");
    if (!who.length || rx(who, @"^(this|that|them|this artist|that artist|singing|this guy|this girl|he|she)$")) who = [now[@"artist"] componentsSeparatedByString:@", "].firstObject;
    if (!who.length) { [self fail:@"Who do you mean? Nothing is playing to go by."]; return; }
    MRGArtistInfo(who, withInfo);
}

- (void)switchItUp {
    NSMutableString *r = [NSMutableString stringWithString:@"Switch it up: take the set in a clearly different direction from the last one (another genre, scene, era or energy; different artists), still something this listener would love."];
    if (_plan.length) [r appendFormat:@" The last set's plan was: \"%@\" — do not repeat that direction.", _plan];
    // Only constraints like "underground" carry over; an earlier artist or vibe doesn't (it made Start replay Clairo).
    if (_origRequest.length && popularityCap(_origRequest)) [r appendFormat:@" Keep the hard constraints of their earlier request (like underground or an era): \"%@\".", _origRequest];
    NSDictionary *now = MRGNowPlaying();
    if (now[@"artist"]) [r appendFormat:@" Playing right now: \"%@\" by %@; start from there.", now[@"title"] ?: @"?", now[@"artist"]];
    [self startWithRequest:r];
}

- (void)playTracks:(NSArray<NSDictionary *> *)tracks intro:(NSString *)intro {
    NSMutableArray *set = [NSMutableArray array];
    for (NSDictionary *d in tracks) {
        if (![d isKindOfClass:NSDictionary.class] || ![d[@"uri"] isKindOfClass:NSString.class] || ![d[@"uri"] hasPrefix:@"spotify:track:"]) continue;
        MRGDJTrack *t = [MRGDJTrack new];
        t.uri = d[@"uri"];
        t.title = [d[@"title"] isKindOfClass:NSString.class] ? d[@"title"] : @"";
        t.artist = [d[@"artist"] isKindOfClass:NSString.class] ? d[@"artist"] : @"";
        t.image = [d[@"image"] isKindOfClass:NSString.class] ? d[@"image"] : nil;
        t.line = [d[@"line"] isKindOfClass:NSString.class] ? d[@"line"] : nil;
        [set addObject:t];
    }
    if (!set.count) return;
    NSUInteger gen = ++_generation;
    [self quiet];
    _error = nil;
    _next = nil;
    _fetchingNext = NO;
    _focus = nil; _focusTracks = nil; _focusRelated = nil; _focusMode = 0; _focusCrew = nil; _focusPlain = NO;
    _state = MRGDJThinking;
    MRGDJLog(@"chat: playing %lu tracks as a set", (unsigned long)set.count);
    [self playSet:set intro:intro generation:gen fresh:YES];
}

// Playback, all through Spotify's own player (no Web API):
//  1. The first track played as its own context (SPTPlayerContext contextForURI: on spotify:track:…, SPTEsperantoPlayer
//     playContext:options:origin:), exactly as a track's Play does.
//  2. Checked against the player's state until that track is actually playing (MRGWaitForPlayback).
//  3. Only then the rest is queued (SPTPlayerQueueWrapperImpl queueMultipleTracks:loggingParams:), with retries: queued
//     straight after the play command, the player answered 409 Conflict.
//  4. If the queue still refuses, "step" mode: whenever a set track ends and something else starts, the next set track
//     is played as its own context (arrivedAt:).
- (void)playSet:(NSArray<MRGDJTrack *> *)found intro:(NSString *)intro generation:(NSUInteger)gen fresh:(BOOL)fresh {
    if (fresh) {
        // A new vibe or request replaces what was lined up: Spotify's queue (the last set's queued songs and anything the
        // listener added) is emptied first, then the new set plays as its own context and the rest is queued.
        [self setStatusText:@"Clearing the queue…"];
        MRGClearQueue(^(NSUInteger removed, NSString *error) {
            if (gen != self->_generation) return;
            [self playSet:found intro:intro generation:gen fresh:NO];
        });
        return;
    }
    NSArray<NSString *> *uris = urisOf(found);
    void (^failed)(NSString *) = ^(NSString *why) {
        if (gen != self->_generation) return;
        MRGDJLog(@"set: couldn't start playback: %@", why);
        // The set stays listed, so a row can still be tried and Switch it up asks again.
        self->_set = found;
        self->_currentIndex = -1;
        self->_state = MRGDJIdle;
        [self fail:[NSString stringWithFormat:@"Couldn't start playback: %@", why]];
    };
    if (!uris.count) { failed(@"no tracks"); return; }
    self->_set = found;
    self->_lastIndex = -1;
    self->_rebuilds = 0;
    for (MRGDJTrack *t in found) { t.queueState = MRGDJQueueUnknown; t.requeues = 0; }
    self->_stepping = YES;   // until the first track is verified, nothing else steps
    [self setStatusText:@"Starting the first song…"];
    MRGPlayContextURI(uris.firstObject, nil, ^(BOOL ok, NSString *error) {
        if (gen != self->_generation) return;
        if (!ok) { self->_stepping = NO; failed(error ?: @"the player refused it"); return; }
        MRGWaitForPlayback(@[uris.firstObject], nil, 8, ^(BOOL playing, NSString *seen) {
            if (gen != self->_generation) return;
            self->_stepping = NO;
            if (!playing) { failed([NSString stringWithFormat:@"Spotify took the song but didn't play it; %@", seen]); return; }
            MRGDJLog(@"set: first track playing, %lu more to queue", (unsigned long)(uris.count - 1));
            self->_playbackMode = @"step";
            self->_state = MRGDJPlaying;
            self->_status = nil;
            self->_currentIndex = -1;
            self->_setStarted = CACurrentMediaTime();
            self->_missStreak = 0;
            [self->_spoken removeAllObjects];
            self->_talkCount = 0;
            self->_intro = intro;
            self->_introPending = intro.length > 0;
            [self changed];
            NSDictionary *now = MRGNowPlaying();
            if (now) [self arrivedAt:now];
            if (uris.count < 2) return;
            NSArray *rest = [found subarrayWithRange:NSMakeRange(1, found.count - 1)];
            [self mark:rest state:MRGDJQueuePending];
            MRGQueueTracks([uris subarrayWithRange:NSMakeRange(1, uris.count - 1)], ^(BOOL queued, NSString *queueError) {
                if (gen != self->_generation) return;
                self->_playbackMode = queued ? @"queue" : @"step";
                MRGDJLog(@"set: %@", queued ? @"rest of the set sent to the queue, checking it" : [NSString stringWithFormat:@"queue refused (%@), stepping track by track", queueError ?: @"?"]);
                if (!queued) [self mark:rest state:MRGDJQueueMissing];
                [self syncQueueSoon:2.0 reason:@"after queueing"];
            });
        });
    });
}

- (void)playFromIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_set.count) return;
    if (index == _currentIndex || _stepping || _state == MRGDJThinking) return;
    MRGDJTrack *row = _set[index];
    NSString *target = row.uri;
    if (![target hasPrefix:@"spotify:track:"]) { [self fail:@"That song isn't ready yet (no Spotify match). Try another row."]; return; }
    NSUInteger gen = _generation;
    _error = nil;
    _stepping = YES;
    [self setStatusText:@"Skipping to it…"];
    MRGDJLog(@"row: jump to %ld (%@, was %@)", (long)index, target, @[@"unknown", @"pending", @"in queue", @"missing", @"played"][MIN(MAX(row.queueState, 0), 4)]);
    // The row plays by its URI straight away; nothing is queued until the player has settled on it (0.4.2 cleared and
    // re-queued at once, which is where Spotify's queue wrapper asserted).
    MRGPlayContextURI(target, nil, ^(BOOL ok, NSString *error) {
        if (gen != self->_generation) return;
        if (!ok) { self->_stepping = NO; [self fail:[NSString stringWithFormat:@"Couldn't jump to that song: %@", error ?: @"Spotify refused it (Spotify Free can't pick songs on demand)."]]; return; }
        MRGWaitForPlayback(@[target], nil, 6, ^(BOOL playing, NSString *seen) {
            if (gen != self->_generation) return;
            self->_stepping = NO;
            self->_status = nil;
            if (!playing) { [self fail:[NSString stringWithFormat:@"Spotify didn't jump to that song (%@). On Spotify Free it can't pick songs on demand.", seen]]; return; }
            if (self->_state == MRGDJIdle) self->_state = MRGDJPlaying;
            self->_playbackMode = @"step";
            self->_setStarted = CACurrentMediaTime();
            self->_missStreak = 0;
            self->_rebuilds = 0;
            [self changed];
            if (index + 1 >= (NSInteger)self->_set.count) return;
            NSArray *rest = [self->_set subarrayWithRange:NSMakeRange(index + 1, self->_set.count - index - 1)];
            [self mark:rest state:MRGDJQueuePending];
            // What was queued before the jump is still in Spotify's queue: cleared first; if that fails, the rest is
            // not queued again (it would play twice) and Mirage steps through it instead.
            MRGClearQueue(^(NSUInteger removed, NSString *clearError) {
                if (gen != self->_generation) return;
                if (clearError) {
                    MRGDJLog(@"row: queue not cleared (%@), stepping through the rest", clearError);
                    [self mark:rest state:MRGDJQueueMissing];
                    return;
                }
                MRGQueueTracks(urisOf(rest), ^(BOOL queued, NSString *queueError) {
                    if (gen != self->_generation) return;
                    self->_playbackMode = queued ? @"queue" : @"step";
                    if (!queued) [self mark:rest state:MRGDJQueueMissing];
                    [self syncQueueSoon:2.5 reason:@"after a jump"];
                });
            });
        });
    });
}

// Something outside the set started right after a set track. When that track had (nearly) run out, the set goes on with
// its next track played as a context; when it was cut short, the listener chose something else and the DJ steps back.
- (BOOL)stepOnFrom:(NSDictionary *)now {
    if (_stepping || _lastIndex < 0 || !_set.count) return NO;
    CFTimeInterval played = CACurrentMediaTime() - _lastStart;
    BOOL ranOut = _lastDuration > 0 ? played >= _lastDuration - 20 : played >= 90;
    if (!ranOut) {
        MRGDJLog(@"step: %@ started %.0fs into a set track, the listener took over", now[@"title"] ?: @"something", played);
        _lastIndex = -1;
        return NO;
    }
    NSInteger next = _lastIndex + 1;
    if (next >= (NSInteger)_set.count) return NO;
    NSString *uri = _set[next].uri;
    NSUInteger gen = _generation;
    _stepping = YES;
    MRGDJLog(@"step: set track %ld ended, playing %ld (%@)", (long)_lastIndex, (long)next, uri);
    MRGPlayContextURI(uri, nil, ^(BOOL ok, NSString *error) {
        if (gen != self->_generation) return;
        if (!ok) { self->_stepping = NO; MRGDJLog(@"step: refused (%@)", error ?: @"?"); return; }
        MRGWaitForPlayback(@[uri], nil, 6, ^(BOOL playing, NSString *seen) {
            if (gen != self->_generation) return;
            self->_stepping = NO;
            if (!playing) MRGDJLog(@"step: didn't play (%@)", seen);
        });
    });
    return YES;
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
    _currentIndex = index;
    if (index >= 0) {
        _lastIndex = index;
        _lastStart = CACurrentMediaTime();
        _lastDuration = [now[@"duration"] doubleValue];
    }
    if (index < 0 && [self stepOnFrom:now]) { [self changed]; return; }
    if (index < 0) {
        // Past the set (Spotify's autoplay took over): the next set, fetched as the last track started, goes on.
        if (_set.count && _spoken.count && _next.count && _lastIndex == (NSInteger)_set.count - 1) {
            NSArray *next = _next;
            _next = nil;
            [self playSet:next intro:nil generation:_generation fresh:NO];
        }
        [self changed];
        return;
    }
    MRGDJTrack *t = _set[index];
    if (![_spoken containsObject:uri]) {
        [_spoken addObject:uri];
        NSInteger nth = _talkCount++;
        MRGDJTalk talk = MRGDJTalkEffective();
        BOOL talks = talk == MRGDJTalkEvery || nth == 0 || (talk == MRGDJTalkFew && nth % 3 == 0);
        NSString *line = talks ? t.line : nil;
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
    // Keeps going: the next set is picked a few songs before the end and queued behind this one two songs before the end,
    // so the queue never runs dry (after an artist's catalog: artists like them).
    if (index >= (NSInteger)_set.count - 4 && !_fetchingNext && !_next) [self fetchNext];
    if (index >= (NSInteger)_set.count - 2 && _next.count) [self appendNext];
    [self syncQueueSoon:3.0 reason:@"track changed"];
    [self changed];
}

#pragma mark - queue sync

// Spotify can take a queue command and still not apply it, and a play can wipe the queue, so the set sheet never trusts
// a command: after every queueing, every track change and every 25 s, Spotify's real queue is read back
// (MRGFetchQueue) and compared with what's left of the set. Missing songs are put back (the queue's set songs cleared
// and re-sent in set order, anything the listener queued kept after them), at most twice per set; after that, step
// mode: Mirage plays each missing song itself when its turn comes. A different order in Spotify (the listener dragged
// things around) is followed by the set.
- (void)mark:(NSArray<MRGDJTrack *> *)tracks state:(MRGDJQueueState)state {
    for (MRGDJTrack *t in tracks) t.queueState = state;
    [self changed];
}

- (void)syncTick {
    if (_state == MRGDJPlaying && !_stepping && CACurrentMediaTime() - _lastSync > 20) [self syncQueue:@"timer"];
}

- (void)syncQueueSoon:(double)delay reason:(NSString *)reason {
    NSUInteger token = ++_syncToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token == self->_syncToken) [self syncQueue:reason];
    });
}

static NSInteger queuePosition(MRGDJTrack *t, NSArray<NSDictionary *> *queued) {
    for (NSInteger i = 0; i < (NSInteger)queued.count; i++) if ([queued[i][@"uri"] isEqualToString:t.uri]) return i;
    NSString *ti = plain(t.title), *ar = plain(t.artist);
    if (!ti.length) return NSNotFound;
    for (NSInteger i = 0; i < (NSInteger)queued.count; i++)
        if ([plain(queued[i][@"title"]) isEqualToString:ti] && (!ar.length || [plain(queued[i][@"artist"]) isEqualToString:ar])) return i;
    return NSNotFound;
}

- (void)syncQueue:(NSString *)reason {
    // Never while a set or a jump is starting, never two at once, and not in the first seconds of a set.
    if (_state != MRGDJPlaying || !_set.count || _syncing || _stepping) return;
    if (CACurrentMediaTime() - _setStarted < 3) { [self syncQueueSoon:3 reason:reason]; return; }
    NSInteger here = MAX(_currentIndex, _lastIndex);
    if (here < 0) return;   // the player is somewhere else; nothing to line up
    _syncing = YES;
    _lastSync = CACurrentMediaTime();
    NSUInteger gen = _generation;
    MRGFetchQueue(^(NSArray<NSDictionary *> *queued, NSArray<NSDictionary *> *upNext, NSString *error) {
        self->_syncing = NO;
        if (gen != self->_generation || self->_state != MRGDJPlaying || self->_stepping) return;
        if (error) { MRGDJLog(@"sync: couldn't read Spotify's queue (%@) [%@]", error, reason); return; }
        // The player's state lists only so many songs ahead: when every listed one is queued, the songs past them
        // aren't visible and count as unknown, not missing.
        BOOL allQueued = upNext.count && queued.count == upNext.count;
        NSInteger from = MAX(self->_currentIndex, self->_lastIndex) + 1;
        NSArray<MRGDJTrack *> *set = self->_set;
        for (NSInteger i = 0; i < from && i < (NSInteger)set.count; i++) if (i != self->_currentIndex) set[i].queueState = MRGDJQueuePlayed;
        if (from >= (NSInteger)set.count) { [self changed]; return; }
        NSArray<MRGDJTrack *> *upcoming = [set subarrayWithRange:NSMakeRange(from, set.count - from)];
        NSMutableArray *missing = [NSMutableArray array];
        NSMutableArray *positions = [NSMutableArray array];
        NSMutableSet *ours = [NSMutableSet set];
        NSUInteger checkedCount = 0;
        for (MRGDJTrack *t in upcoming) {
            NSInteger pos = queuePosition(t, queued);
            if (pos == NSNotFound && allQueued && checkedCount >= queued.count) { if (t.queueState != MRGDJQueueQueued) t.queueState = MRGDJQueuePending; continue; }
            checkedCount++;
            if (pos == NSNotFound) { [missing addObject:t]; t.queueState = MRGDJQueueMissing; }
            else { [positions addObject:@(pos)]; [ours addObject:@(pos)]; t.queueState = MRGDJQueueQueued; }
        }
        NSMutableArray *foreign = [NSMutableArray array];
        for (NSInteger i = 0; i < (NSInteger)queued.count; i++) if (![ours containsObject:@(i)]) [foreign addObject:queued[i][@"uri"]];
        NSDictionary *after = upNext.firstObject;
        MRGDJLog(@"sync: [%@] %lu left in the set, %lu in Spotify's queue, %lu missing, %lu other queued; next up: %@ (%@)", reason,
                 (unsigned long)upcoming.count, (unsigned long)(upcoming.count - missing.count), (unsigned long)missing.count, (unsigned long)foreign.count,
                 after[@"title"] ?: @"nothing", after[@"provider"] ?: @"-");
        if (!missing.count) {
            self->_missStreak = 0;
            self->_playbackMode = @"queue";
            // Same songs, other order: the listener reordered Spotify's queue, so the set follows it.
            BOOL sorted = YES;
            for (NSUInteger i = 1; i < positions.count; i++) if ([positions[i] integerValue] < [positions[i - 1] integerValue]) sorted = NO;
            if (!sorted) {
                NSArray *ordered = [upcoming sortedArrayUsingComparator:^NSComparisonResult(MRGDJTrack *a, MRGDJTrack *b) {
                    NSInteger pa = queuePosition(a, queued), pb = queuePosition(b, queued);
                    return pa < pb ? NSOrderedAscending : pa > pb ? NSOrderedDescending : NSOrderedSame;
                }];
                self->_set = [[set subarrayWithRange:NSMakeRange(0, from)] arrayByAddingObjectsFromArray:ordered];
                MRGDJLog(@"sync: Spotify's queue has another order, the set follows it");
            }
            [self changed];
            return;
        }
        if (missing.count == upcoming.count) MRGDJLog(@"sync: none of the set is in Spotify's queue (wiped or never applied)");
        // Two reads in a row must agree before anything is changed (the state can lag a queue command).
        if (++self->_missStreak < 2) { [self changed]; [self syncQueueSoon:4 reason:@"confirming"]; return; }
        if (self->_rebuilds >= 2) {
            if (![self->_playbackMode isEqualToString:@"step"]) MRGDJLog(@"sync: the queue keeps dropping songs, step mode: Mirage plays the missing ones itself");
            self->_playbackMode = @"step";
            [self changed];
            return;
        }
        self->_rebuilds++;
        NSMutableArray *send = [urisOf(upcoming) mutableCopy];
        [send addObjectsFromArray:foreign];
        MRGDJLog(@"sync: rebuilding the queue (%ld/2): %lu set songs in order%@", (long)self->_rebuilds, (unsigned long)upcoming.count,
                 foreign.count ? [NSString stringWithFormat:@", then %lu the listener queued", (unsigned long)foreign.count] : @"");
        for (MRGDJTrack *t in missing) t.requeues++;
        [self mark:upcoming state:MRGDJQueuePending];
        MRGClearQueue(^(NSUInteger removed, NSString *clearError) {
            if (gen != self->_generation || self->_stepping) return;
            if (clearError) {
                // Re-sending without a clear would put songs in twice: step mode instead.
                MRGDJLog(@"sync: queue not cleared (%@), step mode for the missing songs", clearError);
                self->_playbackMode = @"step";
                for (MRGDJTrack *t in upcoming) t.queueState = [missing containsObject:t] ? MRGDJQueueMissing : MRGDJQueueQueued;
                self->_rebuilds = 2;
                [self changed];
                return;
            }
            self->_missStreak = 0;
            MRGQueueTracks(send, ^(BOOL ok, NSString *queueError) {
                if (gen != self->_generation) return;
                if (!ok) {
                    MRGDJLog(@"sync: re-queue refused (%@), step mode", queueError ?: @"?");
                    self->_playbackMode = @"step";
                    [self mark:upcoming state:MRGDJQueueMissing];
                    return;
                }
                [self syncQueueSoon:2.5 reason:@"after rebuild"];
            });
        });
        [self changed];
    });
}

- (void)appendNext {
    NSArray<MRGDJTrack *> *next = _next;
    _next = nil;
    NSMutableSet *have = [NSMutableSet setWithArray:urisOf(_set)];
    NSMutableArray *add = [NSMutableArray array];
    for (MRGDJTrack *t in next) if (t.uri && ![have containsObject:t.uri]) { [have addObject:t.uri]; [add addObject:t]; }
    if (!add.count) return;
    _set = [_set arrayByAddingObjectsFromArray:add];
    NSUInteger gen = _generation;
    MRGDJLog(@"refill: %lu more songs after the set", (unsigned long)add.count);
    [self mark:add state:MRGDJQueuePending];
    _rebuilds = 0;
    MRGQueueTracks(urisOf(add), ^(BOOL queued, NSString *error) {
        if (gen != self->_generation) return;
        if (!queued) { self->_playbackMode = @"step"; [self mark:add state:MRGDJQueueMissing]; MRGDJLog(@"refill: queue refused (%@), stepping", error ?: @"?"); }
        [self syncQueueSoon:2.0 reason:@"after the refill"];
    });
    [self changed];
}

- (void)fetchNext {
    _fetchingNext = YES;
    MRGDJLog(@"refill: picking the next set%@", _focusMode == 4 ? [NSString stringWithFormat:@" (artists like %@)", [self focusNames]] : @"");
    NSUInteger gen = _generation;
    [self buildSetWithRequest:nil generation:gen done:^(NSArray<MRGDJTrack *> *found, NSString *intro, NSString *error) {
        if (gen != self->_generation) return;
        self->_fetchingNext = NO;
        NSArray *set = [self ensureFocus:found ?: @[]];
        if (set.count) self->_next = set;
        // A one-song set (a requested song) is already past the point where arrivedAt appends: queue it right away.
        if (set.count && self->_state == MRGDJPlaying && self->_currentIndex >= (NSInteger)self->_set.count - 2) [self appendNext];
    }];
}

#pragma mark - playing a context (playlist, album, artist, Liked Songs)

- (void)playContext:(NSString *)uri shuffle:(NSNumber *)shuffle done:(void (^)(BOOL ok, NSString *error))done {
    // The DJ set steps aside (nothing of it steps in later) and the queue is emptied, then Spotify plays the context.
    NSUInteger gen = ++_generation;
    _state = MRGDJIdle;
    _set = @[]; _next = nil; _fetchingNext = NO; _currentIndex = -1; _lastIndex = -1; _stepping = NO; _status = nil; _error = nil;
    _focus = nil; _focusTracks = nil; _focusRelated = nil; _focusMode = 0; _focusCrew = nil; _focusPlain = NO;
    [self quiet];
    [self changed];
    MRGDJLog(@"context: playing %@%@", uri, shuffle ? ([shuffle boolValue] ? @" shuffled" : @" in order") : @"");
    MRGClearQueue(^(NSUInteger removed, NSString *clearError) {
        if (gen != self->_generation) return;
        MRGPlayContext(uri, nil, shuffle, ^(BOOL ok, NSString *error) {
            if (gen != self->_generation) return;
            if (!ok) { done(NO, error ?: @"Spotify's player refused it."); return; }
            MRGWaitForPlayback(@[], uri, 8, ^(BOOL playing, NSString *seen) {
                MRGDJLog(@"context: %@", playing ? @"playing" : [@"sent, not confirmed: " stringByAppendingString:seen ?: @"?"]);
                done(YES, playing ? nil : seen);
            });
        });
    });
}

#pragma mark - speaking

- (void)setSpeaking:(BOOL)speaking line:(NSString *)line {
    if (speaking == _speaking && !speaking) return;
    _speaking = speaking;
    [NSNotificationCenter.defaultCenter postNotificationName:MRGDJSpeakingNotification object:self
        userInfo:@{@"speaking": @(speaking), @"line": line ?: _currentLine ?: @""}];
}

- (void)speak:(NSString *)line {
    [self setSpeaking:YES line:line];
    if (MRGVoiceGetEngine() == MRGVoiceEngineOff) {
        // No voice: the caption stays up for about as long as reading it takes.
        NSUInteger words = [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet].count;
        NSUInteger gen = _generation;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(3.5, words * 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (gen == self->_generation && [self->_currentLine isEqualToString:line]) [self setSpeaking:NO line:line];
        });
        return;
    }
    if (MRGDJDucks()) MRGDuckMusic(YES);
    NSUInteger tok = ++_speakToken;
    [MRGVoiceSpeaker.shared speak:line engine:-1 voice:nil started:nil finished:^{ if (tok == self->_speakToken) [self finishedSpeaking]; }];
}

- (void)finishedSpeaking {
    // Back up after a short tail, so the last word is not stepped on.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!MRGVoiceSpeaker.shared.isSpeaking) { MRGDuckMusic(NO); [self setSpeaking:NO line:nil]; }
    });
}

@end
