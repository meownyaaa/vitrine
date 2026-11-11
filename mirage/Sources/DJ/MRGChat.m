#import "MRGChat.h"
#import "MRGAI.h"
#import "MRGDJ.h"
#import "MRGHistory.h"
#import "MRGPlaylists.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGDJLog.h"

NSString *const MRGChatChangedNotification = @"MirageChatChanged";

@implementation MRGChatItem
+ (instancetype)kind:(NSString *)k text:(NSString *)t card:(NSDictionary *)c {
    MRGChatItem *i = [self new]; i.kind = k; i.text = t; i.card = c; return i;
}
@end

static NSString *json(id obj) {
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj ?: @{} options:0 error:nil];
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

// A tool result for the transcript, at most ~2500 characters (long lists cut to their first entries).
static NSString *capped(id result) {
    NSString *j = json(result);
    if (j.length <= 2500 || ![result isKindOfClass:NSDictionary.class]) return j.length <= 2500 ? j : [[j substringToIndex:2500] stringByAppendingString:@"…(cut)"];
    NSMutableDictionary *r = [result mutableCopy];
    for (NSString *k in [r allKeys]) {
        id v = r[k];
        if ([v isKindOfClass:NSArray.class] && [v count] > 6) { r[k] = [v subarrayWithRange:NSMakeRange(0, 6)]; r[[k stringByAppendingString:@"_total"]] = @([v count]); }
    }
    j = json(r);
    return j.length <= 2500 ? j : [[j substringToIndex:2500] stringByAppendingString:@"…(cut)"];
}

static NSString *isoDay(NSDate *d) {
    if (!d) return @"";
    static NSDateFormatter *f;
    if (!f) { f = [NSDateFormatter new]; f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; f.dateFormat = @"yyyy-MM-dd"; }
    return [f stringFromDate:d];
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] && [v length] ? v : nil; }
static NSArray<NSString *> *strings(id v) {
    NSMutableArray *a = [NSMutableArray array];
    for (id x in [v isKindOfClass:NSArray.class] ? v : (str(v) ? @[v] : @[])) if (str(x)) [a addObject:x];
    return a;
}

#pragma mark - tools

static NSDictionary *tool(NSString *name, NSString *desc, NSDictionary *props, NSArray *required) {
    return @{@"name": name, @"description": desc,
             @"parameters": @{@"type": @"object", @"properties": props ?: @{}, @"required": required ?: @[]}};
}
static NSDictionary *S(NSString *d) { return @{@"type": @"string", @"description": d}; }
static NSDictionary *I(NSString *d) { return @{@"type": @"integer", @"description": d}; }
static NSDictionary *A(NSString *d) { return @{@"type": @"array", @"items": @{@"type": @"string"}, @"description": d}; }

static NSArray<NSDictionary *> *tools(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        list = @[
            tool(@"search", @"Search Spotify's catalog. Returns tracks (uri, title, artist, album, popularity 0-100), artists, albums or playlists. Use it to find exact track URIs before playing, queueing or adding them. Artist search understands nicknames, abbreviations and typos.",
                 @{@"query": S(@"what to search for, e.g. 'Archangel Burial', 'artist:Burial' or just an artist's name"), @"type": @{@"type": @"string", @"enum": @[@"track", @"artist", @"album", @"playlist"]}, @"limit": I(@"1-10, default 5")}, @[@"query"]),
            tool(@"play_artist", @"Play an artist (or a label / crew like 'yvl' or 'opium'): their whole catalog as deep as Spotify lists it, then similar artists, with the queue replaced (modes 'mix' and 'only'); or a set of music that sounds like them ('like'). Use this whenever they ask for an artist by name, nickname or abbreviation (e.g. 'play some yvl', 'run pz', 'stuff like clairo').",
                 @{@"artist": S(@"the artist as the listener wrote it or its full name"), @"mode": @{@"type": @"string", @"enum": @[@"mix", @"only", @"like"]}}, @[@"artist"]),
            tool(@"dj_segment", @"Start a Spotify-DJ-style segment from their own history: 'throwbacks' (songs they loved and haven't played in a while), 'on_repeat' (what they've been playing lately and songs close to it), 'discover' (new-to-them songs in their lane), or 'favorites'.",
                 @{@"kind": @{@"type": @"string", @"enum": @[@"throwbacks", @"on_repeat", @"discover", @"favorites"]}}, @[@"kind"]),
            tool(@"switch_it_up", @"Change the DJ set's direction (a new set in a clearly different direction, like Spotify DJ's switch button).", @{}, @[]),
            tool(@"player_control", @"Control playback: skip to the next song, go back, pause or resume.", @{@"action": @{@"type": @"string", @"enum": @[@"next", @"previous", @"pause", @"resume"]}}, @[@"action"]),
            tool(@"like_track", @"Like a track (save it to Liked Songs) or unlike it. Without a uri it's the song playing now.", @{@"uri": S(@"spotify:track: URI, optional"), @"unlike": @{@"type": @"boolean", @"description": @"true to remove it from Liked Songs"}}, @[]),
            tool(@"taste_profile", @"What the listener is into, from the history on this phone: on repeat lately, top artists lately and all time, throwbacks.", @{}, @[]),
            tool(@"play_context", @"Play a whole playlist, album, artist or the listener's Liked Songs in Spotify right now (it replaces the queue). target: a spotify: URI or open.spotify.com link (from search or list_playlists), 'liked' for their Liked Songs, or a playlist or album name (their own playlists are found by name, then Spotify search). Use this whenever they ask to play a playlist, an album or their likes; never tell them to tap it themselves.",
                 @{@"target": S(@"URI, link, 'liked', or a name"), @"kind": @{@"type": @"string", @"enum": @[@"playlist", @"album", @"artist", @"liked"]}, @"shuffle": @{@"type": @"boolean", @"description": @"true to shuffle, false for in order; omit to keep their setting"}}, @[@"target"]),
            tool(@"play_tracks", @"Play these tracks now in Spotify, as a DJ set (the first plays, the rest are queued).", @{@"uris": A(@"spotify:track: URIs, in order"), @"intro": S(@"optional short line the DJ says before the first one")}, @[@"uris"]),
            tool(@"queue_tracks", @"Add tracks to the end of Spotify's queue without interrupting what's playing.", @{@"uris": A(@"spotify:track: URIs")}, @[@"uris"]),
            tool(@"start_dj_set", @"Start a full Mirage DJ set from a request (the DJ picks about 15 songs, plays them and talks between them).", @{@"request": S(@"the vibe, genre, era or constraints, in the listener's words")}, @[@"request"]),
            tool(@"now_playing", @"What is playing right now, and the current DJ set if one is on.", @{}, @[]),
            tool(@"first_played", @"When the listener first played an artist, with which track, and how much they've played them since. From the listening history on this phone (Mirage's recording plus any imported Spotify data).", @{@"artist": S(@"artist name")}, @[@"artist"]),
            tool(@"track_stats", @"How often and since when the listener has played a track, from the history on this phone.", @{@"title": S(@"track title"), @"artist": S(@"artist name, optional")}, @[@"title"]),
            tool(@"top_listening", @"The listener's most played artists or tracks by minutes, all time or for one year, from the history on this phone.", @{@"kind": @{@"type": @"string", @"enum": @[@"artists", @"tracks"]}, @"year": S(@"e.g. '2023'; omit for all time"), @"limit": I(@"1-20, default 10")}, @[@"kind"]),
            tool(@"history_overview", @"What the listening history on this phone covers (dates, plays, minutes per year, recorded vs imported) and the latest plays.", @{@"recent": I(@"how many latest plays to include, 0-20")}, @[]),
            tool(@"create_playlist", @"Create a new playlist in the listener's library, optionally with tracks.", @{@"name": S(@"playlist name"), @"uris": A(@"spotify:track: URIs to add, optional")}, @[@"name"]),
            tool(@"add_to_playlist", @"Add tracks to a playlist. The playlist can be a spotify:playlist: URI or link, the name of one Mirage made, or 'current' for the playlist playing now. Without uris it adds the song playing now.", @{@"playlist": S(@"URI, link, name or 'current'"), @"uris": A(@"spotify:track: URIs (optional: the song playing now)")}, @[@"playlist"]),
            tool(@"remove_from_playlist", @"Remove tracks from a playlist (URI, link, name of one Mirage made, or 'current').", @{@"playlist": S(@"URI, link, name or 'current'"), @"uris": A(@"spotify:track: URIs")}, @[@"playlist", @"uris"]),
            tool(@"delete_playlist", @"Ask to delete (remove from the library) a playlist. This does NOT delete it: it shows the listener a Delete button to confirm. Tell them to tap it.", @{@"playlist": S(@"URI, link, name of one Mirage made, or 'current'")}, @[@"playlist"]),
            tool(@"list_playlists", @"The playlists in the listener's library (name, uri, whether they own it), plus ones Mirage made and the one playing now.", @{@"filter": S(@"optional: only names containing this")}, @[]),
        ];
    });
    return list;
}

#pragma mark - chat

@implementation MRGChat {
    NSMutableArray<MRGChatItem *> *_items;
    NSMutableArray<NSDictionary *> *_transcript;   // provider-neutral messages (MRGAIChatTools)
    NSMutableArray<NSString *> *_notes;            // things that happened outside a turn, told with the next message
    NSMutableDictionary<NSString *, NSDictionary *> *_known;   // uri → track dict, from searches and history
    NSUInteger _turn;
    NSDictionary *_lastToolResult;
    BOOL _nudged;
}

+ (instancetype)shared {
    static MRGChat *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [MRGChat new]; });
    return c;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _items = [NSMutableArray array];
    _transcript = [NSMutableArray array];
    _notes = [NSMutableArray array];
    _known = [NSMutableDictionary dictionary];
    return self;
}

- (NSArray<MRGChatItem *> *)items { return [_items copy]; }
- (void)changed { [NSNotificationCenter.defaultCenter postNotificationName:MRGChatChangedNotification object:self]; }
- (void)add:(MRGChatItem *)i { [_items addObject:i]; [self changed]; }
- (void)setBusy:(BOOL)b text:(NSString *)t { _busy = b; _busyText = [t copy]; [self changed]; }

- (void)reset {
    _turn++;
    [_items removeAllObjects];
    [_transcript removeAllObjects];
    [_notes removeAllObjects];
    [self setBusy:NO text:nil];
}

- (NSString *)systemPrompt {
    NSDictionary *h = MRGHistorySummary();
    NSString *coverage = [h[@"plays"] integerValue]
        ? [NSString stringWithFormat:@"%@ plays from %@ to %@ (%@ imported from Spotify data, %@ recorded by Mirage since %@)", h[@"plays"], isoDay(h[@"from"]), isoDay(h[@"to"]), h[@"importedPlays"], h[@"livePlays"], isoDay(h[@"liveSince"])]
        : [NSString stringWithFormat:@"nothing yet (Mirage records from %@ on; no Spotify data imported)", isoDay(h[@"liveSince"]) ?: @"now"];
    NSDictionary *now = MRGNowPlaying();
    NSMutableString *p = [NSMutableString stringWithFormat:
        @"You are Mirage DJ, the listener's personal DJ inside their Spotify app — like Spotify's own DJ, but you can also chat. How you talk: %@\n"
        @"Today is %@. Playing now: %@.\n\n"
        @"Understanding them:\n"
        @"- They write casually: slang, abbreviations, typos, no punctuation (\"sum\" = some, \"ts\" = this, \"rn\" = right now, \"fr\", \"lowkey\", \"bangers\", \"slaps\", \"run it\", \"throw on\"). Work out what they mean and act; don't ask unless it's truly ambiguous.\n"
        @"- Short names are usually artists (\"yvl\", \"pz\", \"uzi\", \"carti\"): if they ask to play one, call play_artist with it as written (it resolves nicknames and abbreviations on Spotify). For a specific song, search type track, then play_tracks.\n"
        @"- \"make/create a playlist (named X)\" → create_playlist right away with that name (add songs only if they asked). \"add this\" → add_to_playlist without uris (the song playing now). \"skip\", \"pause\", \"go back\" → player_control. \"like this\"/\"save this\" → like_track.\n"
        @"- \"play my liked songs\"/\"my likes\" → play_context target 'liked'. \"play <playlist or album>\" → play_context with its name (their own playlists are found by name) or a URI from search; \"shuffle\" → shuffle true.\n"
        @"- An artist (\"play yvl\", \"run uzi\") → play_artist: it plays their whole catalog, then similar artists. Any new set, artist or playlist replaces the queue.\n"
        @"- \"throwbacks\", \"old stuff i used to play\" → dj_segment throwbacks; \"what i've been playing\" → on_repeat; \"something new\" → discover; \"switch it up\" → switch_it_up; a vibe, genre or mood → start_dj_set with their words.\n\n"
        @"Rules:\n"
        @"- You can play anything: tracks, artists, playlists, albums, Liked Songs. NEVER tell the listener to tap, open or play something in Spotify themselves; do it with a tool, and if it fails say what failed.\n"
        @"- Use the function-calling tools to act. NEVER write a tool call, a function name, JSON or a spotify: URI in your reply text; the listener only sees your words and the cards.\n"
        @"- For any fact about their listening (first plays, counts, top artists, dates) call a tool; never invent numbers or dates. The listening history on this phone covers: %@. If it doesn't cover what they ask, say so and tell them they can import their Spotify data in Settings → Mirage → AI DJ → Listening history.\n"
        @"- Before playing, queueing or adding specific songs, get real URIs with search.\n"
        @"- delete_playlist only shows a Delete button; it's deleted only if they tap it. Never claim it is deleted.\n"
        @"- If a tool fails, say what failed in plain words (use its error), don't pretend it worked. If a tool says your arguments were invalid, call it again correctly.\n"
        @"- Keep replies short (1–2 sentences), like a DJ talking, not an assistant. Cards already show details. No markdown tables, no lists of URIs.",
        MRGDJPersonaStyle(), isoDay(NSDate.date), now ? [NSString stringWithFormat:@"%@ — %@", now[@"title"], now[@"artist"] ?: @""] : @"nothing", coverage];
    NSString *taste = MRGDJTasteText();
    if (taste) [p appendFormat:@"\n\nTheir taste (from the history on this phone; use it to pick and to talk about their music):\n%@", taste];
    NSString *style = MRGDJStyleInstructions();
    if (style) [p appendFormat:@"\n\n%@", style];
    NSString *custom = MRGDJCustomPrompt();
    if (custom) [p appendFormat:@"\n\nThe listener's own instructions for you:\n%@", custom];
    return p;
}

- (void)send:(NSString *)raw {
    NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || _busy) return;
    if (MRGAIProvider() == MRGProviderNone) { [self add:[MRGChatItem kind:@"error" text:@"Add your AI provider's API key in Settings → Mirage → AI DJ first." card:nil]]; return; }
    [self add:[MRGChatItem kind:@"user" text:text card:nil]];
    MRGDJNoteUserMessage(text);
    NSString *content = text;
    if (_notes.count) { content = [NSString stringWithFormat:@"(Since your last reply: %@)\n\n%@", [_notes componentsJoinedByString:@" "], text]; [_notes removeAllObjects]; }
    [_transcript addObject:@{@"role": @"user", @"content": content}];
    [self trim];
    MRGDJLog(@"chat: message with %@ (%@)%@", MRGProviderName(MRGAIProvider()), MRGAIModel() ?: @"?", MRGProviderHasTools(MRGAIProvider()) ? @"" : @", no tools on this provider");
    [self setBusy:YES text:@"Thinking…"];
    _nudged = NO;
    _lastToolResult = nil;
    [self step:0 turn:++_turn];
}

// Keeps the last ~24 messages, cut at a user message so no tool answer loses its call (every round resends them, and
// free tiers count tokens per minute: Groq's 429 "Requested … Please try again in …" came from long chats).
- (void)trim {
    if (_transcript.count <= 24) return;
    NSUInteger cut = _transcript.count - 24;
    while (cut < _transcript.count && ![_transcript[cut][@"role"] isEqualToString:@"user"]) cut++;
    if (cut < _transcript.count) [_transcript removeObjectsInRange:NSMakeRange(0, cut)];
}

- (void)step:(NSUInteger)round turn:(NSUInteger)turn {
    NSArray *t = MRGProviderHasTools(MRGAIProvider()) ? tools() : @[];
    MRGAIChatTools([self systemPrompt], _transcript, t, ^(NSDictionary *assistant, NSString *error) {
        if (turn != self->_turn) return;
        if (error) {
            MRGDJLog(@"chat: error: %@", error);
            if (round > 0 && self->_lastToolResult) {
                // The actions already ran: say so rather than only showing the error.
                [self add:[MRGChatItem kind:@"note" text:@"(The DJ's reply didn't come through, but the steps above ran.)" card:nil]];
            }
            // The user message stays, so "try again" works; an unanswered tool call would break the next turn.
            [self add:[MRGChatItem kind:@"error" text:error card:nil]];
            [self setBusy:NO text:nil];
            return;
        }
        NSArray *calls = [assistant[@"tool_calls"] isKindOfClass:NSArray.class] ? assistant[@"tool_calls"] : @[];
        NSString *said = [str(assistant[@"content"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!said.length && !calls.count && round == 0 && !self->_nudged) {
            // An empty answer: ask once more, plainly.
            self->_nudged = YES;
            MRGDJLog(@"chat: empty answer, asking again");
            [self->_transcript addObject:@{@"role": @"assistant", @"content": @"…"}];
            [self->_transcript addObject:@{@"role": @"user", @"content": @"(Your last answer was empty. Act on my message with the tools, then reply in a sentence.)"}];
            [self step:round + 1 turn:turn];
            return;
        }
        NSMutableDictionary *stored = [assistant mutableCopy];
        stored[@"content"] = said ?: @"";
        [self->_transcript addObject:stored];
        if (said.length) [self add:[MRGChatItem kind:@"dj" text:said card:nil]];
        if (!calls.count || round >= 8) {
            if (calls.count) {
                for (NSDictionary *c in calls) [self->_transcript addObject:@{@"role": @"tool", @"tool_call_id": c[@"id"] ?: @"", @"name": c[@"name"] ?: @"", @"content": json(@{@"error": @"too many steps"})}];
            }
            if (!said.length && round > 0) {
                // Tools ran but the model said nothing: a plain closing line from the last result.
                NSString *err = str(self->_lastToolResult[@"error"]);
                [self add:[MRGChatItem kind:err ? @"error" : @"dj" text:err ? [@"That didn't work: " stringByAppendingString:err] : @"Done." card:nil]];
            }
            [self setBusy:NO text:nil];
            return;
        }
        [self runCalls:calls index:0 turn:turn done:^{
            if (turn != self->_turn) return;
            [self setBusy:YES text:@"Thinking…"];
            [self step:round + 1 turn:turn];
        }];
    });
}

- (void)runCalls:(NSArray *)calls index:(NSUInteger)i turn:(NSUInteger)turn done:(void (^)(void))done {
    if (i >= calls.count) { done(); return; }
    NSDictionary *c = calls[i];
    NSString *name = str(c[@"name"]) ?: @"";
    NSDictionary *args = [c[@"arguments"] isKindOfClass:NSDictionary.class] ? c[@"arguments"] : @{};
    MRGDJLog(@"chat: tool %@%@%@", name, [c[@"from_text"] boolValue] ? @" (written as text)" : @"", str(c[@"bad_arguments"]) ? @" (invalid arguments)" : @"");
    [self setBusy:YES text:[self busyFor:name]];
    void (^answer)(id) = ^(id result) {
        if (turn != self->_turn) return;
        self->_lastToolResult = [result isKindOfClass:NSDictionary.class] ? result : nil;
        if (str(result[@"error"])) MRGDJLog(@"chat: tool %@ failed: %@", name, result[@"error"]);
        [self->_transcript addObject:@{@"role": @"tool", @"tool_call_id": str(c[@"id"]) ?: @"", @"name": name, @"content": capped(result)}];
        [self runCalls:calls index:i + 1 turn:turn done:done];
    };
    if (str(c[@"bad_arguments"])) {
        NSString *raw = c[@"bad_arguments"];
        answer(@{@"error": [NSString stringWithFormat:@"Your arguments for %@ weren't valid JSON (%@). Call it again with valid JSON arguments.", name, raw.length > 120 ? [raw substringToIndex:120] : raw]});
        return;
    }
    @try { [self run:name args:args answer:answer]; }
    @catch (NSException *e) { answer(@{@"error": [NSString stringWithFormat:@"%@: %@", e.name, e.reason]}); }
}

- (NSString *)busyFor:(NSString *)tool {
    NSDictionary *m = @{@"search": @"Searching Spotify…", @"play_tracks": @"Starting playback…", @"queue_tracks": @"Queueing…",
                        @"start_dj_set": @"Starting a set…", @"first_played": @"Checking your history…", @"track_stats": @"Checking your history…",
                        @"top_listening": @"Checking your history…", @"history_overview": @"Checking your history…",
                        @"create_playlist": @"Creating the playlist…", @"add_to_playlist": @"Adding songs…", @"remove_from_playlist": @"Removing songs…",
                        @"play_artist": @"Finding the artist…", @"play_context": @"Starting it…", @"list_playlists": @"Reading your playlists…", @"dj_segment": @"Starting a set…", @"switch_it_up": @"Switching it up…",
                        @"player_control": @"On it…", @"like_track": @"Saving…", @"taste_profile": @"Checking your history…"};
    return m[tool] ?: @"Working…";
}

- (void)remember:(NSArray<NSDictionary *> *)tracks {
    for (NSDictionary *t in tracks) if (str(t[@"uri"])) self->_known[t[@"uri"]] = t;
}

- (NSArray<NSDictionary *> *)tracksFor:(NSArray<NSString *> *)uris {
    NSMutableArray *a = [NSMutableArray array];
    for (NSString *u in uris) {
        if (![u hasPrefix:@"spotify:track:"]) continue;
        [a addObject:_known[u] ?: @{@"uri": u, @"title": @"", @"artist": @""}];
    }
    return a;
}

// A playlist from what the model passed: a URI or link, "current", or the name of one Mirage made.
- (NSDictionary *)playlistFrom:(NSString *)ref {
    NSString *uri = MRGPlaylistURIFrom(ref);
    if (uri) {
        for (NSDictionary *m in MRGPlaylistsMade()) if ([m[@"uri"] isEqualToString:uri]) return m;
        return @{@"uri": uri, @"name": @"that playlist"};
    }
    NSString *ctx = MRGPlayerContextURI();
    if ([ref.lowercaseString containsString:@"current"] || [ref.lowercaseString containsString:@"this playlist"] || [ref.lowercaseString containsString:@"playing"]) {
        if ([ctx hasPrefix:@"spotify:playlist:"]) return @{@"uri": ctx, @"name": @"the playlist playing now"};
        return nil;
    }
    NSString *want = ref.lowercaseString;
    for (NSDictionary *m in MRGPlaylistsMade()) if ([[m[@"name"] lowercaseString] isEqualToString:want]) return m;
    for (NSDictionary *m in MRGPlaylistsMade()) if (want.length >= 3 && [[m[@"name"] lowercaseString] containsString:want]) return m;
    return nil;
}

// The same, also looking through the listener's library by name (exact, then contained, then close).
- (void)findPlaylist:(NSString *)ref done:(void (^)(NSDictionary *playlist))done {
    NSDictionary *quick = [self playlistFrom:ref];
    if (quick || !ref.length || [ref.lowercaseString containsString:@"current"]) { done(quick); return; }
    MRGPlaylistLibrary(^(NSArray<NSDictionary *> *lib, NSString *error) {
        NSString *want = ref.lowercaseString;
        for (NSDictionary *m in lib) if ([[m[@"name"] lowercaseString] isEqualToString:want]) { done(m); return; }
        for (NSDictionary *m in lib) if (want.length >= 3 && [[m[@"name"] lowercaseString] containsString:want]) { done(m); return; }
        for (NSDictionary *m in lib) if (MRGNamesMatch(m[@"name"], ref)) { done(m); return; }
        done(nil);
    });
}

static NSDictionary *notFound(NSString *ref) {
    return @{@"error": [NSString stringWithFormat:@"Couldn't find a playlist called \"%@\" in their library or among the ones Mirage made. Try search type playlist, or list_playlists.", ref ?: @""]};
}

// spotify:(playlist|album|artist|show|collection…) from a URI or an open.spotify.com link, or nil.
static NSString *contextURIFrom(NSString *text) {
    NSString *t = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([t hasPrefix:@"spotify:"] && ![t hasPrefix:@"spotify:track:"]) return t;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"open\\.spotify\\.com/(?:intl-[a-z]+/)?(playlist|album|artist|show)/([A-Za-z0-9]+)" options:0 error:nil];
    NSTextCheckingResult *m = t.length ? [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)] : nil;
    if (m) return [NSString stringWithFormat:@"spotify:%@:%@", [t substringWithRange:[m rangeAtIndex:1]], [t substringWithRange:[m rangeAtIndex:2]]];
    return nil;
}

static BOOL meansLiked(NSString *t) {
    NSString *l = t.lowercaseString;
    return [l isEqualToString:@"liked"] || [l containsString:@"liked songs"] || [l containsString:@"my likes"] || [l isEqualToString:@"likes"] ||
           [l containsString:@"saved songs"] || [l containsString:@"liked music"] || [l containsString:@"collection"] || [l isEqualToString:@"liked tracks"];
}

// Plays the context and answers the tool (Liked Songs: the user collection URI, then spotify:collection:tracks).
- (void)playContextURIs:(NSArray<NSString *> *)uris name:(NSString *)pname shuffle:(NSNumber *)shuffle answer:(void (^)(id))answer {
    NSString *uri = uris.firstObject;
    [MRGDJ.shared playContext:uri shuffle:shuffle done:^(BOOL ok, NSString *error) {
        if (!ok && uris.count > 1) { [self playContextURIs:[uris subarrayWithRange:NSMakeRange(1, uris.count - 1)] name:pname shuffle:shuffle answer:answer]; return; }
        if (ok) [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"playlist", @"name": pname ?: @"Playing", @"uri": uri,
                                                                     @"detail": shuffle ? ([shuffle boolValue] ? @"Playing · shuffled" : @"Playing · in order") : @"Playing"}]];
        answer(ok ? @{@"ok": @YES, @"playing": pname ?: uri, @"uri": uri, @"note": error ? [@"Sent to Spotify; not confirmed yet: " stringByAppendingString:error] : @"Playing now; the queue was replaced."}
                  : @{@"error": error ?: @"Spotify's player refused it."});
    }];
}

- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(id))answer {
    if ([name isEqualToString:@"search"]) {
        NSString *type = str(args[@"type"]) ?: @"track";
        NSInteger limit = [args[@"limit"] respondsToSelector:@selector(integerValue)] ? [args[@"limit"] integerValue] : 5;
        NSString *q = str(args[@"query"]) ?: @"";
        MRGWebSearch(q, type, MAX(1, MIN(10, limit ?: 5)), ^(NSArray<NSDictionary *> *results, NSString *error) {
            if (error) { answer(@{@"error": error}); return; }
            if ([type isEqualToString:@"track"]) [self remember:results];
            if (results.count) { answer(@{@"results": results}); return; }
            // Nothing as typed: an artist by nickname, abbreviation or typo, or the query without field filters.
            NSString *bare = [[q stringByReplacingOccurrencesOfString:@"artist:" withString:@""] stringByReplacingOccurrencesOfString:@"track:" withString:@""];
            bare = [bare stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            MRGWebFindArtist(bare, ^(NSDictionary *artist, NSString *how) {
                if ([type isEqualToString:@"artist"]) { answer(artist ? @{@"results": @[artist], @"note": [NSString stringWithFormat:@"matched by %@", how]} : @{@"results": @[], @"note": @"No artist found; if it's an abbreviation, search its full name."}); return; }
                if (artist) {
                    MRGWebArtistTracks(artist, MAX(1, MIN(10, limit ?: 5)), ^(NSArray<NSDictionary *> *tracks) {
                        [self remember:tracks];
                        answer(@{@"results": tracks, @"note": [NSString stringWithFormat:@"No exact match; these are tracks by %@.", artist[@"name"]]});
                    });
                    return;
                }
                if (![bare isEqualToString:q]) {
                    MRGWebSearch(bare, type, 5, ^(NSArray<NSDictionary *> *r2, NSString *e2) {
                        if ([type isEqualToString:@"track"]) [self remember:r2];
                        answer(@{@"results": r2 ?: @[]});
                    });
                    return;
                }
                answer(@{@"results": @[]});
            });
        });
        return;
    }
    if ([name isEqualToString:@"play_context"]) {
        NSString *target = str(args[@"target"]) ?: str(args[@"uri"]) ?: str(args[@"playlist"]) ?: str(args[@"name"]) ?: @"";
        NSString *kind = str(args[@"kind"]);
        NSNumber *shuffle = [args[@"shuffle"] respondsToSelector:@selector(boolValue)] ? @([args[@"shuffle"] boolValue]) : nil;
        if ([kind isEqualToString:@"liked"] || meansLiked(target)) {
            NSString *user = MRGSpotifyUsername();
            NSMutableArray *uris = [NSMutableArray array];
            if (user.length) [uris addObject:[NSString stringWithFormat:@"spotify:user:%@:collection", user]];
            [uris addObject:@"spotify:collection:tracks"];
            MRGDJLog(@"chat: play Liked Songs (%@)", user.length ? @"user collection first" : @"username unknown, spotify:collection:tracks");
            [self playContextURIs:uris name:@"Liked Songs" shuffle:shuffle answer:answer];
            return;
        }
        NSString *uri = contextURIFrom(target);
        if (uri) { [self playContextURIs:@[uri] name:nil shuffle:shuffle answer:answer]; return; }
        if (!target.length) { answer(@{@"error": @"Say which playlist, album or artist (or 'liked')."}); return; }
        void (^bySearch)(void) = ^{
            NSString *type = [kind isEqualToString:@"album"] ? @"album" : [kind isEqualToString:@"artist"] ? @"artist" : @"playlist";
            MRGWebSearch(target, type, 5, ^(NSArray<NSDictionary *> *results, NSString *error) {
                NSDictionary *best = nil;
                for (NSDictionary *r in results) if ([[r[@"name"] lowercaseString] isEqualToString:target.lowercaseString]) { best = r; break; }
                for (NSDictionary *r in results) if (!best && MRGNamesMatch(r[@"name"], target)) best = r;
                best = best ?: results.firstObject;
                if (!str(best[@"uri"])) { answer(@{@"error": error ?: [NSString stringWithFormat:@"No %@ called \"%@\" found.", type, target]}); return; }
                MRGDJLog(@"chat: play_context found a %@ by search", type);
                [self playContextURIs:@[best[@"uri"]] name:best[@"name"] shuffle:shuffle answer:answer];
            });
        };
        if ([kind isEqualToString:@"album"] || [kind isEqualToString:@"artist"]) { bySearch(); return; }
        [self findPlaylist:target done:^(NSDictionary *pl) {
            if (pl[@"uri"]) { MRGDJLog(@"chat: play_context found the playlist in the library"); [self playContextURIs:@[pl[@"uri"]] name:pl[@"name"] shuffle:shuffle answer:answer]; return; }
            bySearch();
        }];
        return;
    }
    if ([name isEqualToString:@"play_tracks"]) {
        NSArray *tracks = [self tracksFor:strings(args[@"uris"])];
        if (!tracks.count) { answer(@{@"error": @"No spotify:track: URIs given; search first."}); return; }
        [MRGDJ.shared playTracks:tracks intro:str(args[@"intro"])];
        [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"tracks", @"title": @"Playing", @"tracks": tracks}]];
        answer(@{@"ok": @YES, @"playing": @(tracks.count), @"note": @"Playback started through Spotify's own player; on Spotify Free it may shuffle."});
        return;
    }
    if ([name isEqualToString:@"queue_tracks"]) {
        NSArray *tracks = [self tracksFor:strings(args[@"uris"])];
        if (!tracks.count) { answer(@{@"error": @"No spotify:track: URIs given; search first."}); return; }
        NSMutableArray *queueURIs = [NSMutableArray array];
        for (NSDictionary *t in tracks) if ([t isKindOfClass:NSDictionary.class] && str(t[@"uri"])) [queueURIs addObject:t[@"uri"]];
        MRGQueueTracks(queueURIs, ^(BOOL ok, NSString *error) {
            if (ok) [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"tracks", @"title": @"Added to your queue", @"tracks": tracks}]];
            answer(ok ? @{@"ok": @YES, @"queued": @(tracks.count)} : @{@"error": error ?: @"Spotify refused the queue."});
        });
        return;
    }
    if ([name isEqualToString:@"start_dj_set"]) {
        [MRGDJ.shared startWithRequest:str(args[@"request"])];
        [self add:[MRGChatItem kind:@"note" text:@"Starting a DJ set… it shows up in the DJ sheet and on Now Playing." card:nil]];
        answer(@{@"ok": @YES, @"note": @"The set is being picked and will start in a few seconds."});
        return;
    }
    if ([name isEqualToString:@"play_artist"]) {
        NSString *artist = str(args[@"artist"]);
        if (!artist) { answer(@{@"error": @"No artist given."}); return; }
        NSString *mode = str(args[@"mode"]) ?: @"mix";
        NSString *request = [mode isEqualToString:@"only"] ? [NSString stringWithFormat:@"only %@", artist]
                          : [mode isEqualToString:@"like"] ? [NSString stringWithFormat:@"music like %@", artist] : [NSString stringWithFormat:@"play %@", artist];
        [MRGDJ.shared startWithRequest:request];
        [self add:[MRGChatItem kind:@"note" text:[NSString stringWithFormat:@"Lining up %@… it shows up in the DJ sheet and on Now Playing.", artist] card:nil]];
        answer(@{@"ok": @YES, @"note": [mode isEqualToString:@"like"] ? @"The DJ is finding the artist and building a set of music like them; it starts in a few seconds, replacing the queue."
                                                                        : @"The DJ is finding the artist (or label / crew) on Spotify and will play their whole catalog, then similar artists, replacing the queue; it starts in a few seconds."});
        return;
    }
    if ([name isEqualToString:@"dj_segment"]) {
        NSString *kind = str(args[@"kind"]) ?: @"favorites";
        NSDictionary *requests = @{
            @"throwbacks": @"Throwback set: songs this listener loved and hasn't played in a while (start from the Throwbacks list, then the same artists and era). Lines can say it's a throwback.",
            @"on_repeat": @"On repeat set: what they've been playing most lately (the On repeat list) and songs right next to it.",
            @"discover": @"Discover set: songs new to them that sit right in their lane (same scenes as their top artists), no songs from their history.",
            @"favorites": @"Favorites set: their top artists and best-loved songs, mixed like a radio show."};
        [MRGDJ.shared startWithRequest:requests[kind] ?: requests[@"favorites"]];
        [self add:[MRGChatItem kind:@"note" text:@"Starting the set… it shows up in the DJ sheet and on Now Playing." card:nil]];
        answer(@{@"ok": @YES, @"segment": kind});
        return;
    }
    if ([name isEqualToString:@"switch_it_up"]) {
        [MRGDJ.shared switchItUp];
        answer(@{@"ok": @YES, @"note": @"A new set in a different direction is being picked."});
        return;
    }
    if ([name isEqualToString:@"player_control"]) {
        NSString *action = str(args[@"action"]) ?: @"next";
        MRGPlayerControl(action, ^(BOOL ok, NSString *error) { answer(ok ? @{@"ok": @YES, @"action": action} : @{@"error": error ?: @"Spotify's player refused."}); });
        return;
    }
    if ([name isEqualToString:@"like_track"]) {
        NSString *uri = str(args[@"uri"]) ?: str(MRGNowPlaying()[@"uri"]);
        if (![uri hasPrefix:@"spotify:track:"]) { answer(@{@"error": @"Nothing is playing and no track was given."}); return; }
        BOOL unlike = [args[@"unlike"] respondsToSelector:@selector(boolValue)] && [args[@"unlike"] boolValue];
        MRGLikeTrack(uri, !unlike, ^(BOOL ok, NSString *error) { answer(ok ? @{@"ok": @YES, @"liked": @(!unlike)} : @{@"error": error ?: @"Spotify's library refused."}); });
        return;
    }
    if ([name isEqualToString:@"taste_profile"]) {
        NSDictionary *t = MRGHistoryTaste();
        answer(t.count ? t : @{@"note": @"No history yet."});
        return;
    }
    if ([name isEqualToString:@"now_playing"]) {
        NSMutableDictionary *r = [NSMutableDictionary dictionary];
        NSDictionary *now = MRGNowPlaying();
        if (now) r[@"now_playing"] = @{@"title": now[@"title"] ?: @"", @"artist": now[@"artist"] ?: @"", @"uri": now[@"uri"] ?: @""};
        if (MRGPlayerContextURI()) r[@"playing_from"] = MRGPlayerContextURI();
        MRGDJ *dj = MRGDJ.shared;
        if (dj.set.count) {
            NSMutableArray *set = [NSMutableArray array];
            for (MRGDJTrack *t in dj.set) [set addObject:[NSString stringWithFormat:@"%@ — %@", t.title, t.artist]];
            r[@"dj_set"] = set;
            if (dj.plan) r[@"dj_plan"] = dj.plan;
        }
        if (now) [self remember:@[now]];
        answer(r.count ? r : @{@"now_playing": [NSNull null]});
        return;
    }
    if ([name isEqualToString:@"first_played"]) {
        NSString *artist = str(args[@"artist"]) ?: @"";
        NSDictionary *h = MRGHistoryArtist(artist);
        if (!h) {
            NSDictionary *s = MRGHistorySummary();
            answer(@{@"found": @NO, @"history_covers": [NSString stringWithFormat:@"%@ to %@", isoDay(s[@"from"]) ?: @"-", isoDay(s[@"to"]) ?: @"-"],
                     @"imported": @([s[@"importedPlays"] integerValue] > 0)});
            return;
        }
        NSMutableDictionary *card = [@{@"type": @"first_played", @"artist": h[@"artist"], @"date": h[@"first"], @"firstTrack": h[@"firstTrack"],
                                       @"firstURI": h[@"firstURI"], @"plays": h[@"plays"], @"minutes": h[@"minutes"], @"source": h[@"source"]} mutableCopy];
        MRGWebSearch(h[@"artist"], @"artist", 3, ^(NSArray<NSDictionary *> *results, NSString *error) {
            NSDictionary *best = nil;
            for (NSDictionary *r in results) if ([[r[@"name"] lowercaseString] isEqualToString:[h[@"artist"] lowercaseString]]) { best = r; break; }
            best = best ?: results.firstObject;
            if (str(best[@"image"])) card[@"image"] = best[@"image"];
            if (str(best[@"uri"])) card[@"artistURI"] = best[@"uri"];
            [self add:[MRGChatItem kind:@"card" text:nil card:card]];
            answer(@{@"found": @YES, @"artist": h[@"artist"], @"first_played": isoDay(h[@"first"]), @"first_track": h[@"firstTrack"],
                     @"plays_since": h[@"plays"], @"minutes": h[@"minutes"], @"last_played": isoDay(h[@"last"]),
                     @"source": [h[@"source"] isEqualToString:@"live"] ? @"Mirage's own recording" : @"imported Spotify data", @"card_shown": @YES});
        });
        return;
    }
    if ([name isEqualToString:@"track_stats"]) {
        NSDictionary *h = MRGHistoryTrack(str(args[@"title"]) ?: @"", str(args[@"artist"]));
        if (!h) { answer(@{@"found": @NO}); return; }
        answer(@{@"found": @YES, @"title": h[@"title"], @"artist": h[@"artist"], @"first_played": isoDay(h[@"first"]), @"last_played": isoDay(h[@"last"]), @"plays": h[@"plays"], @"minutes": h[@"minutes"]});
        return;
    }
    if ([name isEqualToString:@"top_listening"]) {
        BOOL artists = ![str(args[@"kind"]) isEqualToString:@"tracks"];
        NSString *year = str(args[@"year"]);
        NSInteger limit = [args[@"limit"] respondsToSelector:@selector(integerValue)] ? [args[@"limit"] integerValue] : 10;
        limit = MAX(1, MIN(20, limit ?: 10));
        NSArray *top = artists ? MRGHistoryTopArtists(year, limit) : MRGHistoryTopTracks(year, limit);
        if (!top.count) { answer(@{@"found": @NO, @"note": @"No plays in the history for that."}); return; }
        NSMutableArray *rows = [NSMutableArray array];
        for (NSDictionary *t in top) [rows addObject:@{@"title": artists ? t[@"name"] : [NSString stringWithFormat:@"%@ — %@", t[@"name"], t[@"artist"]], @"detail": [NSString stringWithFormat:@"%@ min", t[@"minutes"]]}];
        [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"list", @"title": [NSString stringWithFormat:@"Top %@%@", artists ? @"artists" : @"tracks", year ? [@" of " stringByAppendingString:year] : @""], @"rows": rows}]];
        answer(@{@"top": top, @"card_shown": @YES});
        return;
    }
    if ([name isEqualToString:@"history_overview"]) {
        NSDictionary *s = MRGHistorySummary();
        NSInteger n = [args[@"recent"] respondsToSelector:@selector(integerValue)] ? MIN(20, MAX(0, [args[@"recent"] integerValue])) : 5;
        NSMutableArray *recent = [NSMutableArray array];
        for (NSDictionary *r in MRGHistoryRecent(n)) [recent addObject:@{@"title": r[@"title"], @"artist": r[@"artist"], @"at": isoDay(r[@"at"])}];
        answer(@{@"plays": s[@"plays"], @"minutes": s[@"minutes"], @"from": isoDay(s[@"from"]), @"to": isoDay(s[@"to"]),
                 @"recorded_by_mirage_since": isoDay(s[@"liveSince"]), @"recorded_plays": s[@"livePlays"], @"imported_plays": s[@"importedPlays"],
                 @"years": MRGHistoryYears(), @"recent": recent});
        return;
    }
    if ([name isEqualToString:@"create_playlist"]) {
        NSString *pname = str(args[@"name"]) ?: @"Mirage DJ";
        NSArray *uris = strings(args[@"uris"]);
        MRGPlaylistCreate(pname, uris, ^(BOOL ok, NSString *uri, NSString *error) {
            if (uri) [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"playlist", @"name": pname, @"uri": uri,
                                @"detail": ok ? [NSString stringWithFormat:@"Created · %lu songs", (unsigned long)uris.count] : (error ?: @"")}]];
            answer(ok ? @{@"ok": @YES, @"uri": uri ?: @"", @"added": @(uris.count)} : @{@"error": error ?: @"Spotify refused.", @"uri": uri ?: @""});
        });
        return;
    }
    if ([name isEqualToString:@"add_to_playlist"] || [name isEqualToString:@"remove_from_playlist"]) {
        BOOL add = [name hasPrefix:@"add"];
        [self findPlaylist:str(args[@"playlist"]) ?: @"" done:^(NSDictionary *pl) {
        if (!pl) { answer(notFound(str(args[@"playlist"]))); return; }
        NSArray *uris = strings(args[@"uris"]);
        if (!uris.count && add && str(MRGNowPlaying()[@"uri"])) { uris = @[MRGNowPlaying()[@"uri"]]; [self remember:@[MRGNowPlaying()]]; }
        MRGPlaylistDone done = ^(BOOL ok, NSString *uri, NSString *error) {
            if (ok) [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"playlist", @"name": pl[@"name"] ?: @"Playlist", @"uri": pl[@"uri"],
                               @"detail": [NSString stringWithFormat:@"%@ %lu song%@", add ? @"Added" : @"Removed", (unsigned long)uris.count, uris.count == 1 ? @"" : @"s"]}]];
            answer(ok ? @{@"ok": @YES} : @{@"error": error ?: @"Spotify refused."});
        };
        if (add) MRGPlaylistAdd(pl[@"uri"], uris, done); else MRGPlaylistRemove(pl[@"uri"], uris, done);
        }];
        return;
    }
    if ([name isEqualToString:@"delete_playlist"]) {
        [self findPlaylist:str(args[@"playlist"]) ?: @"" done:^(NSDictionary *pl) {
            if (!pl) { answer(notFound(str(args[@"playlist"]))); return; }
            [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"confirm_delete", @"name": pl[@"name"] ?: @"this playlist", @"uri": pl[@"uri"], @"state": @"pending"}]];
            MRGDJLog(@"chat: delete of %@ waiting for the listener's tap", pl[@"uri"]);
            answer(@{@"status": @"waiting_for_confirmation", @"note": @"A Delete button is shown. Nothing is deleted unless the listener taps it."});
        }];
        return;
    }
    if ([name isEqualToString:@"list_playlists"]) {
        NSString *filter = str(args[@"filter"]).lowercaseString;
        MRGPlaylistLibrary(^(NSArray<NSDictionary *> *lib, NSString *error) {
            NSMutableArray *out = [NSMutableArray array];
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *m in lib) {
                if (filter.length && ![[m[@"name"] lowercaseString] containsString:filter]) continue;
                [seen addObject:m[@"uri"]];
                [out addObject:@{@"name": m[@"name"] ?: @"", @"uri": m[@"uri"], @"mine": m[@"mine"] ?: @YES}];
                if (out.count >= 40) break;
            }
            for (NSDictionary *m in MRGPlaylistsMade()) if (![seen containsObject:m[@"uri"] ?: @""] && (!filter.length || [[m[@"name"] lowercaseString] containsString:filter])) [out addObject:@{@"name": m[@"name"] ?: @"", @"uri": m[@"uri"] ?: @"", @"made_by": @"Mirage"}];
            NSString *ctx = MRGPlayerContextURI();
            if ([ctx hasPrefix:@"spotify:playlist:"]) [out addObject:@{@"name": @"(playing now)", @"uri": ctx}];
            NSMutableDictionary *r = [@{@"playlists": out} mutableCopy];
            if (!lib.count) r[@"note"] = [NSString stringWithFormat:@"Their library couldn't be read (%@); search type playlist finds public ones by name.", error ?: @"?"];
            answer(r);
        });
        return;
    }
    answer(@{@"error": [NSString stringWithFormat:@"Unknown tool %@", name]});
}

#pragma mark - card actions

- (void)replace:(MRGChatItem *)item state:(NSString *)state detail:(NSString *)detail {
    NSMutableDictionary *c = [item.card mutableCopy];
    c[@"state"] = state;
    if (detail) c[@"detail"] = detail;
    item.card = c;
    [self changed];
}

- (void)confirmDelete:(MRGChatItem *)item {
    if (![item.card[@"state"] isEqualToString:@"pending"]) return;
    NSString *uri = item.card[@"uri"], *pname = item.card[@"name"];
    [self replace:item state:@"working" detail:nil];
    MRGDJLog(@"chat: the listener confirmed deleting %@", uri);
    MRGPlaylistDelete(uri, ^(BOOL ok, NSString *u, NSString *error) {
        [self replace:item state:ok ? @"deleted" : @"failed" detail:ok ? @"Removed from your library." : error];
        [self->_notes addObject:ok ? [NSString stringWithFormat:@"the listener tapped Delete and \"%@\" was removed from their library.", pname]
                                   : [NSString stringWithFormat:@"the listener tapped Delete on \"%@\" but it failed: %@", pname, error ?: @"?"]];
    });
}

- (void)cancelDelete:(MRGChatItem *)item {
    if (![item.card[@"state"] isEqualToString:@"pending"]) return;
    [self replace:item state:@"cancelled" detail:@"Kept."];
    [_notes addObject:[NSString stringWithFormat:@"the listener cancelled deleting \"%@\".", item.card[@"name"]]];
}

- (void)playTrack:(NSDictionary *)track {
    NSString *uri = str(track[@"uri"]);
    if (![uri hasPrefix:@"spotify:track:"]) return;
    MRGDJLog(@"chat: play from a card");
    MRGPlayContextURI(uri, nil, ^(BOOL ok, NSString *error) {
        if (!ok) [self add:[MRGChatItem kind:@"error" text:[NSString stringWithFormat:@"Couldn't play it: %@", error ?: @"Spotify refused (on Free it can't pick songs on demand)."] card:nil]];
    });
}

@end
