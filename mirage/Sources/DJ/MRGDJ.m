#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGPrefs.h"
#import "MRGDJLog.h"
#import "MRGVoice.h"
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
            @[@"Underground curator", @"Knows the deep cuts; drops a fact.",
              @"an underground music curator and crate digger: knowledgeable, understated, drops one real, specific detail (the label, the scene, the year, a sample, who produced it) only when you are sure it is true. Never hype, never generic.", @(MRGDJTalkFew), @24],
            @[@"Storyteller", @"Short stories behind the songs.",
              @"a storyteller: tells a short, true story or piece of context behind the song or artist (how it was made, what it meant, where it came from), only facts you are sure of, vivid but brief.", @(MRGDJTalkFew), @40],
            @[@"Minimal", @"Barely talks: names and nothing else.",
              @"a minimal host: almost silent, just the song and artist or a two-word mood, nothing more.", @(MRGDJTalkSwitches), @8],
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
    _lastIndex = -1;
    _stepping = NO;
    _status = nil;
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
static NSString *systemPrompt(void) {
    NSMutableString *p = [NSMutableString string];
    [p appendString:@"You are Mirage DJ, the host of a personal radio show inside the listener's Spotify, and a serious music curator.\n"];
    [p appendFormat:@"How you talk: %@\n\n", MRGDJPersonaStyle()];
    [p appendString:
        @"How you curate:\n"
        @"1. Read the request first. Every constraint in it (genre, scene, era or year, mood, energy, tempo, language, 'underground', 'obscure', 'deep cuts', 'no hits', 'like artist X') is a hard rule for every single track, not a suggestion.\n"
        @"2. Anchor on what they actually listen to (now playing, just played, the queue): stay in their lane unless the request says otherwise, and go deeper rather than wider.\n"
        @"3. Avoid the obvious: no artist's biggest hits, no songs everyone already knows, no playlist filler. When they ask for underground, obscure or deep cuts, pick small artists, early releases, B-sides and album tracks with real cult status, never chart songs or famous names.\n"
        @"4. At most 2 songs per artist, nothing from 'just played' or 'already picked', no duplicates. Order the set so it flows (an energy arc, smooth transitions).\n"
        @"5. Only real, released songs you are certain exist on Spotify, with the exact official title and primary artist as Spotify lists them. Never invent songs, artists, remixes or versions. If you are unsure a deep cut exists, choose another one you are sure of.\n\n"
        @"Return ONLY a JSON object, no prose:\n"
        @"{\"plan\": string, \"intro\": string, \"tracks\": [{\"artist\": string, \"title\": string, \"line\": string, \"why\": string}]}\n"];
    [p appendFormat:
        @"'plan' comes first: one or two sentences on the direction of this set (genres, era, mood, energy arc) and how it honors the request. "
        @"Then exactly 15 tracks that follow the plan. 'line' is what you say right before that track starts, in your persona: at most %ld words, "
        @"mentions the song or the artist naturally, every line different. 'why' is 1 to 4 lowercase words on why it's in the set (like \"deep cut\", "
        @"\"you loved this\", \"same scene\", \"throwback\"). 'intro' opens the set in at most 20 words.", (long)personaWords()];
    NSString *custom = MRGDJCustomPrompt();
    if (custom) [p appendFormat:@"\n\nThe listener's own instructions for you (follow them, but always keep the JSON format):\n%@", custom];
    return p;
}

// Requests for music off the beaten path: picks with a Spotify popularity above the cap are dropped.
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
    [p appendFormat:@"Just played:\n%@\n\n", listOf(played, 25)];
    [p appendFormat:@"Around it in the queue:\n%@\n\n", listOf(MRGQueueAround(), 10)];
    if (top.count) [p appendFormat:@"Their top and recent tracks:\n%@\n\n", listOf(top, 20)];
    if (artists.count) [p appendFormat:@"Their top artists: %@\n\n", [artists componentsJoinedByString:@", "]];
    if (liked.count) [p appendFormat:@"Songs they liked:\n%@\n\n", listOf(liked, 15)];
    [p appendFormat:@"Request: %@", request.length ? request : @"(none: just play something great for them right now)"];
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

// Asks for a set and finds its tracks; `done` gets the found tracks in order (or an error) and the intro. For an
// underground request picks above the popularity cap are dropped, and when fewer than 8 are left the model is asked
// once more for replacements.
- (void)buildSetWithRequest:(NSString *)request generation:(NSUInteger)gen done:(void (^)(NSArray<MRGDJTrack *> *, NSString *intro, NSString *error))done {
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
        NSString *intro = [json[@"intro"] isKindOfClass:NSString.class] ? json[@"intro"] : nil;
        NSString *plan = [json[@"plan"] isKindOfClass:NSString.class] ? json[@"plan"] : nil;
        if (plan.length) { self->_plan = [plan copy]; MRGDJLog(@"plan: %@", plan); }
        [self resolve:items cap:cap generation:gen done:^(NSArray<MRGDJTrack *> *found, NSArray<MRGDJTrack *> *dropped, NSString *resolveError) {
            if (gen != self->_generation) return;
            if (found.count >= 8 || (!cap && found.count)) { done(found, intro, nil); return; }
            // Refill once: what's kept, what was too popular or not found, and ask for more in the same plan.
            NSMutableString *more = [prompt mutableCopy];
            [more appendFormat:@"\n\nYour plan: %@\nAlready picked (keep, don't repeat):\n%@\n", plan ?: @"(same request)", listOf([self dicts:found], 15)];
            if (dropped.count) [more appendFormat:@"Thrown out (too popular or not on Spotify, don't repeat):\n%@\n", listOf([self dicts:dropped], 20)];
            [more appendFormat:@"Send %lu more tracks in the same JSON format that fit the plan%@.", (unsigned long)(15 - found.count), cap ? @" and are genuinely lesser-known" : @""];
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
        t.line = [line isKindOfClass:NSString.class] ? line : nil;
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
        NSUInteger tooPopular = 0, unrated = 0;
        for (MRGDJTrack *t in slots) {
            if (!t.uri) { [dropped addObject:t]; continue; }
            if ([seen containsObject:t.uri]) continue;
            NSString *ak = t.artist.lowercaseString ?: @"";
            if (perArtist[ak].integerValue >= 2) continue;
            if (t.popularity < 0) unrated++;
            if (cap && t.popularity > cap) { tooPopular++; [dropped addObject:t]; continue; }
            [seen addObject:t.uri];
            perArtist[ak] = @(perArtist[ak].integerValue + 1);
            [found addObject:t];
            if (found.count >= 15) break;
        }
        MRGDJLog(@"set: %lu picks, %lu kept%@%@%@", (unsigned long)slots.count, (unsigned long)found.count,
                 cap ? [NSString stringWithFormat:@", %lu over popularity %ld dropped", (unsigned long)tooPopular, (long)cap] : @"",
                 unrated ? [NSString stringWithFormat:@", %lu without a popularity from search", (unsigned long)unrated] : @"",
                 lastError ? [@", last error: " stringByAppendingString:lastError] : @"");
        done(found, dropped, lastError);
    });
}

- (void)startWithRequest:(NSString *)request {
    if (MRGAIProvider() == MRGProviderNone) { [self fail:@"Add your AI provider's API key in Mirage settings first."]; return; }
    NSUInteger gen = ++_generation;
    _lastRequest = [request copy];
    if (![request hasPrefix:@"Switch it up:"]) _origRequest = [request copy];
    MRGDJLog(@"start: %@ with %@ (%@)", request.length ? @"a request" : @"no request", MRGProviderName(MRGAIProvider()), MRGAIModel() ?: @"?");
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

- (void)switchItUp {
    NSMutableString *r = [NSMutableString stringWithString:@"Switch it up: take the set in a clearly different direction from the last one (another genre, scene, era or energy; different artists), still something this listener would love."];
    if (_plan.length) [r appendFormat:@" The last set's plan was: \"%@\" — do not repeat that direction.", _plan];
    if (_origRequest.length) [r appendFormat:@" Keep the hard constraints of their earlier request (like underground or an era): \"%@\".", _origRequest];
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
    _error = nil;
    _next = nil;
    _fetchingNext = NO;
    _state = MRGDJThinking;
    MRGDJLog(@"chat: playing %lu tracks as a set", (unsigned long)set.count);
    [self playSet:set intro:intro generation:gen];
}

// Playback, all through Spotify's own player (no Web API):
//  1. The first track played as its own context (SPTPlayerContext contextForURI: on spotify:track:…, SPTEsperantoPlayer
//     playContext:options:origin:), exactly as a track's Play does.
//  2. Checked against the player's state until that track is actually playing (MRGWaitForPlayback).
//  3. Only then the rest is queued (SPTPlayerQueueWrapperImpl queueMultipleTracks:loggingParams:), with retries: queued
//     straight after the play command, the player answered 409 Conflict.
//  4. If the queue still refuses, "step" mode: whenever a set track ends and something else starts, the next set track
//     is played as its own context (arrivedAt:).
- (void)playSet:(NSArray<MRGDJTrack *> *)found intro:(NSString *)intro generation:(NSUInteger)gen {
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
            [self->_spoken removeAllObjects];
            self->_talkCount = 0;
            self->_intro = intro;
            self->_introPending = intro.length > 0;
            [self changed];
            NSDictionary *now = MRGNowPlaying();
            if (now) [self arrivedAt:now];
            if (uris.count < 2) return;
            MRGQueueTracks([uris subarrayWithRange:NSMakeRange(1, uris.count - 1)], ^(BOOL queued, NSString *queueError) {
                if (gen != self->_generation) return;
                self->_playbackMode = queued ? @"queue" : @"step";
                MRGDJLog(@"set: %@", queued ? @"rest of the set queued" : [NSString stringWithFormat:@"queue refused (%@), stepping track by track", queueError ?: @"?"]);
            });
        });
    });
}

- (void)playFromIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)_set.count) return;
    if (index == _currentIndex) return;
    NSArray<NSString *> *uris = urisOf([_set subarrayWithRange:NSMakeRange(index, _set.count - index)]);
    NSString *target = uris.firstObject;
    NSUInteger gen = _generation;
    _error = nil;
    _stepping = YES;
    [self setStatusText:@"Skipping to it…"];
    MRGDJLog(@"row: jump to %ld", (long)index);
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
            [self changed];
            if (uris.count < 2) return;
            MRGQueueTracks([uris subarrayWithRange:NSMakeRange(1, uris.count - 1)], ^(BOOL queued, NSString *queueError) {
                if (gen == self->_generation) self->_playbackMode = queued ? @"queue" : @"step";
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
            [self playSet:next intro:nil generation:_generation];
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
    [MRGVoiceSpeaker.shared speak:line engine:-1 voice:nil started:nil finished:^{ [self finishedSpeaking]; }];
}

- (void)finishedSpeaking {
    // Back up after a short tail, so the last word is not stepped on.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!MRGVoiceSpeaker.shared.isSpeaking) { MRGDuckMusic(NO); [self setSpeaking:NO line:nil]; }
    });
}

@end
