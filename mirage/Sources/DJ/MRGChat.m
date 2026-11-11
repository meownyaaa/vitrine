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
            tool(@"search", @"Search Spotify's catalog. Returns tracks (uri, title, artist, album, popularity 0-100), artists, albums or playlists. Use it to find exact track URIs before playing, queueing or adding them.",
                 @{@"query": S(@"what to search for, e.g. 'artist:Burial' or 'Archangel Burial'"), @"type": @{@"type": @"string", @"enum": @[@"track", @"artist", @"album", @"playlist"]}, @"limit": I(@"1-10, default 5")}, @[@"query"]),
            tool(@"play_tracks", @"Play these tracks now in Spotify, as a DJ set (the first plays, the rest are queued).", @{@"uris": A(@"spotify:track: URIs, in order"), @"intro": S(@"optional short line the DJ says before the first one")}, @[@"uris"]),
            tool(@"queue_tracks", @"Add tracks to the end of Spotify's queue without interrupting what's playing.", @{@"uris": A(@"spotify:track: URIs")}, @[@"uris"]),
            tool(@"start_dj_set", @"Start a full Mirage DJ set from a request (the DJ picks about 15 songs, plays them and talks between them).", @{@"request": S(@"the vibe, genre, era or constraints, in the listener's words")}, @[@"request"]),
            tool(@"now_playing", @"What is playing right now, and the current DJ set if one is on.", @{}, @[]),
            tool(@"first_played", @"When the listener first played an artist, with which track, and how much they've played them since. From the listening history on this phone (Mirage's recording plus any imported Spotify data).", @{@"artist": S(@"artist name")}, @[@"artist"]),
            tool(@"track_stats", @"How often and since when the listener has played a track, from the history on this phone.", @{@"title": S(@"track title"), @"artist": S(@"artist name, optional")}, @[@"title"]),
            tool(@"top_listening", @"The listener's most played artists or tracks by minutes, all time or for one year, from the history on this phone.", @{@"kind": @{@"type": @"string", @"enum": @[@"artists", @"tracks"]}, @"year": S(@"e.g. '2023'; omit for all time"), @"limit": I(@"1-20, default 10")}, @[@"kind"]),
            tool(@"history_overview", @"What the listening history on this phone covers (dates, plays, minutes per year, recorded vs imported) and the latest plays.", @{@"recent": I(@"how many latest plays to include, 0-20")}, @[]),
            tool(@"create_playlist", @"Create a new playlist in the listener's library, optionally with tracks.", @{@"name": S(@"playlist name"), @"uris": A(@"spotify:track: URIs to add, optional")}, @[@"name"]),
            tool(@"add_to_playlist", @"Add tracks to a playlist. The playlist can be a spotify:playlist: URI or link, the name of one Mirage made, or 'current' for the playlist playing now.", @{@"playlist": S(@"URI, link, name or 'current'"), @"uris": A(@"spotify:track: URIs")}, @[@"playlist", @"uris"]),
            tool(@"remove_from_playlist", @"Remove tracks from a playlist (URI, link, name of one Mirage made, or 'current').", @{@"playlist": S(@"URI, link, name or 'current'"), @"uris": A(@"spotify:track: URIs")}, @[@"playlist", @"uris"]),
            tool(@"delete_playlist", @"Ask to delete (remove from the library) a playlist. This does NOT delete it: it shows the listener a Delete button to confirm. Tell them to tap it.", @{@"playlist": S(@"URI, link, name of one Mirage made, or 'current'")}, @[@"playlist"]),
            tool(@"list_playlists", @"Playlists Mirage can act on: ones it created, and the one playing now. (It can't read the listener's whole library.)", @{}, @[]),
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
    NSMutableString *p = [NSMutableString stringWithFormat:
        @"You are Mirage DJ, chatting with the listener inside their Spotify app. How you talk: %@\n"
        @"Today is %@.\n\n"
        @"You can act with tools: search Spotify, play or queue tracks, start a DJ set, answer questions about their listening, and create playlists, add or remove songs, or ask to delete a playlist.\n"
        @"Rules:\n"
        @"- For any fact about their listening (first plays, counts, top artists, dates) call a tool; never guess or invent numbers or dates. "
        @"The listening history on this phone covers: %@. If it doesn't cover what they ask (for example plays before Mirage was installed), say so plainly and tell them they can import their Spotify data in Settings → Mirage → AI DJ → Listening history.\n"
        @"- Before playing, queueing or adding songs, get real URIs with search. Pick real songs that fit; for underground requests prefer low popularity.\n"
        @"- delete_playlist only shows a Delete button; the playlist is deleted only if they tap it. Never claim it is deleted.\n"
        @"- If a tool fails, say what failed in plain words, don't pretend it worked. You can't read their whole library; you can act on playlists Mirage made, the one playing, or one they name by link.\n"
        @"- Keep replies short (1–3 sentences): cards in the chat already show the details (images, dates, tracks). No markdown tables.",
        MRGDJPersonaStyle(), isoDay(NSDate.date), coverage];
    NSString *custom = MRGDJCustomPrompt();
    if (custom) [p appendFormat:@"\n\nThe listener's own instructions for you:\n%@", custom];
    return p;
}

- (void)send:(NSString *)raw {
    NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length || _busy) return;
    if (MRGAIProvider() == MRGProviderNone) { [self add:[MRGChatItem kind:@"error" text:@"Add your AI provider's API key in Settings → Mirage → AI DJ first." card:nil]]; return; }
    [self add:[MRGChatItem kind:@"user" text:text card:nil]];
    NSString *content = text;
    if (_notes.count) { content = [NSString stringWithFormat:@"(Since your last reply: %@)\n\n%@", [_notes componentsJoinedByString:@" "], text]; [_notes removeAllObjects]; }
    [_transcript addObject:@{@"role": @"user", @"content": content}];
    [self trim];
    MRGDJLog(@"chat: message with %@ (%@)%@", MRGProviderName(MRGAIProvider()), MRGAIModel() ?: @"?", MRGProviderHasTools(MRGAIProvider()) ? @"" : @", no tools on this provider");
    [self setBusy:YES text:@"Thinking…"];
    [self step:0 turn:++_turn];
}

// Keeps the last ~40 messages, cut at a user message so no tool answer loses its call.
- (void)trim {
    if (_transcript.count <= 40) return;
    NSUInteger cut = _transcript.count - 40;
    while (cut < _transcript.count && ![_transcript[cut][@"role"] isEqualToString:@"user"]) cut++;
    if (cut < _transcript.count) [_transcript removeObjectsInRange:NSMakeRange(0, cut)];
}

- (void)step:(NSUInteger)round turn:(NSUInteger)turn {
    NSArray *t = MRGProviderHasTools(MRGAIProvider()) ? tools() : @[];
    MRGAIChatTools([self systemPrompt], _transcript, t, ^(NSDictionary *assistant, NSString *error) {
        if (turn != self->_turn) return;
        if (error) {
            MRGDJLog(@"chat: error: %@", error);
            // The user message stays, so "try again" works; an unanswered tool call would break the next turn.
            [self add:[MRGChatItem kind:@"error" text:error card:nil]];
            [self setBusy:NO text:nil];
            return;
        }
        NSArray *calls = [assistant[@"tool_calls"] isKindOfClass:NSArray.class] ? assistant[@"tool_calls"] : @[];
        [self->_transcript addObject:assistant];
        NSString *said = str(assistant[@"content"]);
        if (said) [self add:[MRGChatItem kind:@"dj" text:[said stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] card:nil]];
        if (!calls.count || round >= 6) {
            if (calls.count) {
                // Out of rounds: answer the calls so the transcript stays valid, and stop.
                for (NSDictionary *c in calls) [self->_transcript addObject:@{@"role": @"tool", @"tool_call_id": c[@"id"] ?: @"", @"name": c[@"name"] ?: @"", @"content": json(@{@"error": @"too many steps"})}];
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
    MRGDJLog(@"chat: tool %@", name);
    [self setBusy:YES text:[self busyFor:name]];
    void (^answer)(id) = ^(id result) {
        if (turn != self->_turn) return;
        [self->_transcript addObject:@{@"role": @"tool", @"tool_call_id": str(c[@"id"]) ?: @"", @"name": name, @"content": json(result)}];
        [self runCalls:calls index:i + 1 turn:turn done:done];
    };
    @try { [self run:name args:args answer:answer]; }
    @catch (NSException *e) { answer(@{@"error": [NSString stringWithFormat:@"%@: %@", e.name, e.reason]}); }
}

- (NSString *)busyFor:(NSString *)tool {
    NSDictionary *m = @{@"search": @"Searching Spotify…", @"play_tracks": @"Starting playback…", @"queue_tracks": @"Queueing…",
                        @"start_dj_set": @"Starting a set…", @"first_played": @"Checking your history…", @"track_stats": @"Checking your history…",
                        @"top_listening": @"Checking your history…", @"history_overview": @"Checking your history…",
                        @"create_playlist": @"Creating the playlist…", @"add_to_playlist": @"Adding songs…", @"remove_from_playlist": @"Removing songs…"};
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

static NSDictionary *notFound(NSString *ref) {
    return @{@"error": [NSString stringWithFormat:@"Couldn't find a playlist called \"%@\". Mirage can only act on playlists it made, the one playing now, or one given by its Spotify link (Share → Copy link).", ref ?: @""]};
}

- (void)run:(NSString *)name args:(NSDictionary *)args answer:(void (^)(id))answer {
    if ([name isEqualToString:@"search"]) {
        NSString *type = str(args[@"type"]) ?: @"track";
        NSInteger limit = [args[@"limit"] respondsToSelector:@selector(integerValue)] ? [args[@"limit"] integerValue] : 5;
        MRGWebSearch(str(args[@"query"]), type, MAX(1, MIN(10, limit ?: 5)), ^(NSArray<NSDictionary *> *results, NSString *error) {
            if (error) { answer(@{@"error": error}); return; }
            if ([type isEqualToString:@"track"]) [self remember:results];
            answer(@{@"results": results ?: @[]});
        });
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
        MRGQueueTracks([tracks valueForKey:@"uri"], ^(BOOL ok, NSString *error) {
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
        NSDictionary *pl = [self playlistFrom:str(args[@"playlist"]) ?: @""];
        if (!pl) { answer(notFound(str(args[@"playlist"]))); return; }
        NSArray *uris = strings(args[@"uris"]);
        MRGPlaylistDone done = ^(BOOL ok, NSString *uri, NSString *error) {
            if (ok) [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"playlist", @"name": pl[@"name"] ?: @"Playlist", @"uri": pl[@"uri"],
                               @"detail": [NSString stringWithFormat:@"%@ %lu song%@", add ? @"Added" : @"Removed", (unsigned long)uris.count, uris.count == 1 ? @"" : @"s"]}]];
            answer(ok ? @{@"ok": @YES} : @{@"error": error ?: @"Spotify refused."});
        };
        if (add) MRGPlaylistAdd(pl[@"uri"], uris, done); else MRGPlaylistRemove(pl[@"uri"], uris, done);
        return;
    }
    if ([name isEqualToString:@"delete_playlist"]) {
        NSDictionary *pl = [self playlistFrom:str(args[@"playlist"]) ?: @""];
        if (!pl) { answer(notFound(str(args[@"playlist"]))); return; }
        [self add:[MRGChatItem kind:@"card" text:nil card:@{@"type": @"confirm_delete", @"name": pl[@"name"] ?: @"this playlist", @"uri": pl[@"uri"], @"state": @"pending"}]];
        MRGDJLog(@"chat: delete of %@ waiting for the listener's tap", pl[@"uri"]);
        answer(@{@"status": @"waiting_for_confirmation", @"note": @"A Delete button is shown. Nothing is deleted unless the listener taps it."});
        return;
    }
    if ([name isEqualToString:@"list_playlists"]) {
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *m in MRGPlaylistsMade()) [out addObject:@{@"name": m[@"name"] ?: @"", @"uri": m[@"uri"] ?: @"", @"made_by": @"Mirage"}];
        NSString *ctx = MRGPlayerContextURI();
        if ([ctx hasPrefix:@"spotify:playlist:"]) [out addObject:@{@"name": @"(playing now)", @"uri": ctx}];
        answer(@{@"playlists": out, @"note": @"Only playlists Mirage made and the one playing now are known; for others ask for the playlist's link."});
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
