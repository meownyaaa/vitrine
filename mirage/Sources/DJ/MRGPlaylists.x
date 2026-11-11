#import "MRGPlaylists.h"
#import "MRGDJLog.h"
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kRootSvc = @"spotify.playlist_esperanto.proto.RootlistModificationService";
static NSString *const kListSvc = @"spotify.playlist_esperanto.proto.PlaylistService";

static __weak id sTransport;
static NSString *const kEmpty = @"Spotify answered with an empty message (the change may not have been made).";
static NSMutableOrderedSet<NSString *> *sSeen;          // "service/method" Spotify used
static NSMutableSet *sInFlight;                         // keeps the call handles alive until they answer

static void remember(id transport, NSString *service, NSString *method) {
    if (!sTransport) sTransport = transport;
    if (![service isKindOfClass:NSString.class] || ![service hasPrefix:@"spotify.playlist"]) return;
    NSString *pair = [NSString stringWithFormat:@"%@/%@", service, method];
    @synchronized (sSeen) {
        if ([sSeen containsObject:pair]) return;
        [sSeen addObject:pair];
    }
    MRGDJLog(@"playlists: Spotify called %@ %@", [service componentsSeparatedByString:@"."].lastObject, method);
}

%group MRGEsperanto
%hook SPTEsperantoTransportBridgeImpl
- (id)callSingle:(id)service method:(id)method payload:(id)payload onResponse:(id)response {
    remember(self, service, method);
    return %orig;
}
- (id)callStream:(id)service method:(id)method payload:(id)payload onResponse:(id)response {
    remember(self, service, method);
    return %orig;
}
%end
%end

%ctor {
    sSeen = [NSMutableOrderedSet orderedSet];
    sInFlight = [NSMutableSet set];
    Class c = NSClassFromString(@"SPTEsperantoTransportBridgeImpl");
    if (c && [c instancesRespondToSelector:@selector(callSingle:method:payload:onResponse:)]) %init(MRGEsperanto);
}

NSArray<NSString *> *MRGPlaylistSeenMethods(void) { @synchronized (sSeen) { return sSeen.array; } }
BOOL MRGPlaylistsAvailable(void) { return sTransport != nil; }

#pragma mark - protobuf

static void putVarint(NSMutableData *d, uint64_t v) {
    uint8_t b[10]; int n = 0;
    do { b[n] = v & 0x7F; v >>= 7; if (v) b[n] |= 0x80; n++; } while (v && n < 10);
    [d appendBytes:b length:n];
}
static void putKey(NSMutableData *d, int field, int wire) { putVarint(d, ((uint64_t)field << 3) | wire); }
static void putBytes(NSMutableData *d, int field, NSData *v) { putKey(d, field, 2); putVarint(d, v.length); [d appendData:v]; }
static void putString(NSMutableData *d, int field, NSString *s) { if (s.length) putBytes(d, field, [s dataUsingEncoding:NSUTF8StringEncoding]); }
static void putUInt(NSMutableData *d, int field, uint64_t v) { if (v) { putKey(d, field, 0); putVarint(d, v); } }

// Reads the top-level fields of a message: field number → array of NSNumber (varints) or NSData (length-delimited).
static NSDictionary<NSNumber *, NSArray *> *readFields(NSData *data) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    const uint8_t *p = data.bytes, *end = p + data.length;
    while (p < end) {
        uint64_t key = 0; int shift = 0;
        while (p < end) { uint8_t b = *p++; key |= (uint64_t)(b & 0x7F) << shift; shift += 7; if (!(b & 0x80)) break; if (shift > 63) return out; }
        int field = (int)(key >> 3), wire = key & 7;
        id value = nil;
        if (wire == 0) {
            uint64_t v = 0; shift = 0;
            while (p < end) { uint8_t b = *p++; v |= (uint64_t)(b & 0x7F) << shift; shift += 7; if (!(b & 0x80)) break; if (shift > 63) return out; }
            value = @(v);
        } else if (wire == 2) {
            uint64_t len = 0; shift = 0;
            while (p < end) { uint8_t b = *p++; len |= (uint64_t)(b & 0x7F) << shift; shift += 7; if (!(b & 0x80)) break; if (shift > 63) return out; }
            if (len > (uint64_t)(end - p)) return out;
            value = [NSData dataWithBytes:p length:len];
            p += len;
        } else if (wire == 1) { if (end - p < 8) return out; p += 8; continue; }
        else if (wire == 5) { if (end - p < 4) return out; p += 4; continue; }
        else return out;
        NSMutableArray *a = out[@(field)] ?: (out[@(field)] = [NSMutableArray array]);
        [a addObject:value];
    }
    return out;
}
static NSString *str(id v) { return [v isKindOfClass:NSData.class] ? [[NSString alloc] initWithData:v encoding:NSUTF8StringEncoding] : nil; }

// ModificationRequest (spotify.playlist.cosmos.proto): 1 operation, 2 before, 3 after, 4 name, 5 playlist,
// 7 uris, 8 rows, 12 create_item_kind.
static NSData *modification(NSString *op, NSString *before, NSString *after, NSString *name, BOOL playlist,
                            NSArray<NSString *> *uris, NSArray<NSString *> *rows, int createKind) {
    NSMutableData *m = [NSMutableData data];
    putString(m, 1, op);
    putString(m, 2, before);
    putString(m, 3, after);
    putString(m, 4, name);
    putUInt(m, 5, playlist ? 1 : 0);
    for (NSString *u in uris) putString(m, 7, u);
    for (NSString *r in rows) putString(m, 8, r);
    putUInt(m, 12, createKind);
    return m;
}

// The status in field 1 of every esperanto response here: (status_code, reason). Code 0 means OK.
static NSString *statusError(NSDictionary *f) {
    NSData *st = [f[@1] firstObject];
    if (![st isKindOfClass:NSData.class]) return nil;
    NSDictionary *s = readFields(st);
    long code = [[s[@1] firstObject] longValue];
    NSString *reason = str([s[@2] firstObject]);
    if (!code && !reason.length) return nil;
    if (!code) return nil;
    return [NSString stringWithFormat:@"Spotify answered %ld%@", code, reason.length ? [@": " stringByAppendingString:reason] : @""];
}

#pragma mark - calling

static NSString *preferredMethod(NSString *service, NSArray<NSString *> *wanted) {
    NSArray *seen = MRGPlaylistSeenMethods();
    for (NSString *w in wanted) if ([seen containsObject:[NSString stringWithFormat:@"%@/%@", service, w]]) return w;
    return wanted.firstObject;
}

static void call(NSString *service, NSString *method, NSData *payload, void (^done)(NSData *response, NSString *error)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        id t = sTransport;
        if (!t || ![t respondsToSelector:@selector(callSingle:method:payload:onResponse:)]) {
            done(nil, @"Spotify's playlist engine isn't reachable yet (no Esperanto transport seen). Open your Library once and try again.");
            return;
        }
        __block BOOL answered = NO;
        __block id handle = nil;
        void (^onResponse)(NSData *) = ^(NSData *data) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (answered) return;
                answered = YES;
                if (handle) [sInFlight removeObject:handle];
                done([data isKindOfClass:NSData.class] ? data : [NSData data], nil);
            });
        };
        MRGDJLog(@"playlists: calling %@ %@ (%lu bytes)", [service componentsSeparatedByString:@"."].lastObject, method, (unsigned long)payload.length);
        @try {
            handle = ((id (*)(id, SEL, id, id, id, id))objc_msgSend)(t, @selector(callSingle:method:payload:onResponse:), service, method, payload, onResponse);
            if (handle) [sInFlight addObject:handle];
        } @catch (NSException *e) {
            answered = YES;
            done(nil, [NSString stringWithFormat:@"Spotify's playlist engine threw %@: %@", e.name, e.reason]);
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (answered) return;
            answered = YES;
            if (handle) [sInFlight removeObject:handle];
            done(nil, [NSString stringWithFormat:@"Spotify didn't answer %@ in 15 s.", method]);
        });
    });
}

static void finish(NSString *what, MRGPlaylistDone done, BOOL ok, NSString *uri, NSString *error) {
    MRGDJLog(@"playlists: %@ %@%@", what, ok ? @"done" : @"failed", ok ? (uri.length ? [@" → " stringByAppendingString:uri] : @"") : [@": " stringByAppendingString:error ?: @"?"]);
    done(ok, uri, error);
}

#pragma mark - made by Mirage

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
NSArray<NSDictionary *> *MRGPlaylistsMade(void) { return [D() arrayForKey:@"mirage.playlists.made"] ?: @[]; }
static void rememberMade(NSString *name, NSString *uri) {
    NSMutableArray *a = [MRGPlaylistsMade() mutableCopy];
    [a insertObject:@{@"name": name ?: @"", @"uri": uri, @"created": @(NSDate.date.timeIntervalSince1970)} atIndex:0];
    [D() setObject:[a subarrayWithRange:NSMakeRange(0, MIN(a.count, (NSUInteger)100))] forKey:@"mirage.playlists.made"];
}
static void forgetMade(NSString *uri) {
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *d in MRGPlaylistsMade()) if (![d[@"uri"] isEqualToString:uri]) [a addObject:d];
    [D() setObject:a forKey:@"mirage.playlists.made"];
}

NSString *MRGPlaylistURIFrom(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"(?:spotify:playlist:|open\\.spotify\\.com/(?:[a-z-]+/)?playlist/)([A-Za-z0-9]{22})" options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return m ? [@"spotify:playlist:" stringByAppendingString:[text substringWithRange:[m rangeAtIndex:1]]] : nil;
}

static NSArray<NSString *> *trackURIs(NSArray *uris) {
    NSMutableArray *a = [NSMutableArray array];
    for (id u in uris) if ([u isKindOfClass:NSString.class] && ([u hasPrefix:@"spotify:track:"] || [u hasPrefix:@"spotify:episode:"]) && ![a containsObject:u]) [a addObject:u];
    return a;
}

#pragma mark - operations

// RootlistModificationRequest: 1 folder_uri, 2 request. Response: 1 status, 2 ModificationResponse (1 success, 2 uri).
static void rootlistModify(NSData *modReq, void (^done)(BOOL ok, NSString *uri, NSString *error)) {
    NSMutableData *req = [NSMutableData data];
    putBytes(req, 2, modReq);
    call(kRootSvc, preferredMethod(kRootSvc, @[@"Modify"]), req, ^(NSData *resp, NSString *error) {
        if (error) { done(NO, nil, error); return; }
        NSDictionary *f = readFields(resp);
        NSString *err = statusError(f);
        NSDictionary *mr = [[f[@2] firstObject] isKindOfClass:NSData.class] ? readFields([f[@2] firstObject]) : @{};
        BOOL success = [[mr[@1] firstObject] boolValue];
        NSString *uri = str([mr[@2] firstObject]);
        if (err) { done(NO, uri, err); return; }
        if (!resp.length) { done(NO, nil, kEmpty); return; }
        done(success || uri.length, uri, success || uri.length ? nil : @"Spotify said it didn't make the change.");
    });
}

// PlaylistModificationRequest: 1 uri, 2 request. Response: 1 status, 2 added_row_ids.
static void playlistModify(NSString *playlist, NSData *modReq, void (^done)(BOOL ok, NSString *error)) {
    NSMutableData *req = [NSMutableData data];
    putString(req, 1, playlist);
    putBytes(req, 2, modReq);
    call(kListSvc, preferredMethod(kListSvc, @[@"Modify"]), req, ^(NSData *resp, NSString *error) {
        if (error) { done(NO, error); return; }
        NSString *err = statusError(readFields(resp));
        done(err == nil, err);
    });
}

void MRGPlaylistCreate(NSString *name, NSArray<NSString *> *uris, MRGPlaylistDone done) {
    NSString *title = name.length ? [name substringToIndex:MIN(name.length, (NSUInteger)100)] : @"Mirage DJ";
    NSArray *tracks = trackURIs(uris);
    MRGDJLog(@"playlists: create \"%@\" with %lu tracks", title, (unsigned long)tracks.count);
    void (^fill)(NSString *) = ^(NSString *uri) {
        rememberMade(title, uri);
        if (!tracks.count) { finish(@"create", done, YES, uri, nil); return; }
        MRGPlaylistAdd(uri, tracks, ^(BOOL ok, NSString *u, NSString *error) {
            if (ok) finish(@"create", done, YES, uri, nil);
            else finish(@"create", done, NO, uri, [NSString stringWithFormat:@"The playlist was made but its songs weren't added: %@", error]);
        });
    };
    rootlistModify(modification(@"create", @"start", nil, title, YES, nil, nil, 1), ^(BOOL ok, NSString *uri, NSString *error) {
        if (ok && uri.length) { fill(uri); return; }
        MRGDJLog(@"playlists: create at the top refused (%@), trying without a position", error ?: @"no uri");
        rootlistModify(modification(@"create", nil, nil, title, YES, nil, nil, 1), ^(BOOL ok2, NSString *uri2, NSString *error2) {
            if (ok2 && uri2.length) fill(uri2);
            else finish(@"create", done, NO, nil, error2 ?: error ?: @"Spotify didn't return the new playlist.");
        });
    });
}

void MRGPlaylistAdd(NSString *playlist, NSArray<NSString *> *uris, MRGPlaylistDone done) {
    NSArray *tracks = trackURIs(uris);
    if (!playlist.length || !tracks.count) { finish(@"add", done, NO, playlist, @"No playlist or no tracks."); return; }
    MRGDJLog(@"playlists: add %lu tracks to %@", (unsigned long)tracks.count, playlist);
    playlistModify(playlist, modification(@"add", nil, @"end", nil, NO, tracks, nil, 0), ^(BOOL ok, NSString *error) {
        finish(@"add", done, ok, playlist, error);
    });
}

void MRGPlaylistRemove(NSString *playlist, NSArray<NSString *> *uris, MRGPlaylistDone done) {
    NSArray *tracks = trackURIs(uris);
    if (!playlist.length || !tracks.count) { finish(@"remove", done, NO, playlist, @"No playlist or no tracks."); return; }
    MRGDJLog(@"playlists: remove %lu tracks from %@", (unsigned long)tracks.count, playlist);
    // The rows of those tracks first (PlaylistFindRequest: 1 playlist_uri, 2 item_uris → items: 1 uri, 2 row_ids).
    NSMutableData *find = [NSMutableData data];
    putString(find, 1, playlist);
    for (NSString *u in tracks) putString(find, 2, u);
    call(kListSvc, preferredMethod(kListSvc, @[@"Find"]), find, ^(NSData *resp, NSString *error) {
        NSMutableArray *rows = [NSMutableArray array];
        NSDictionary *f = resp ? readFields(resp) : @{};
        for (NSData *item in f[@2]) {
            if (![item isKindOfClass:NSData.class]) continue;
            for (id r in readFields(item)[@2]) { NSString *s = str(r); if (s.length) [rows addObject:s]; }
        }
        MRGDJLog(@"playlists: find %@ (%lu rows)", error ?: statusError(f) ?: @"answered", (unsigned long)rows.count);
        if (!error && !statusError(f) && resp.length && !rows.count) { finish(@"remove", done, NO, playlist, @"Those songs aren't in that playlist."); return; }
        playlistModify(playlist, modification(@"remove", nil, nil, nil, NO, tracks, rows, 0), ^(BOOL ok, NSString *err) {
            finish(@"remove", done, ok, playlist, err);
        });
    });
}

void MRGPlaylistDelete(NSString *playlist, MRGPlaylistDone done) {
    if (!playlist.length) { finish(@"delete", done, NO, nil, @"No playlist."); return; }
    MRGDJLog(@"playlists: remove %@ from the library", playlist);
    rootlistModify(modification(@"remove", nil, nil, nil, NO, @[playlist], nil, 0), ^(BOOL ok, NSString *uri, NSString *error) {
        // Removing returns no uri; an empty answer without an error status is taken as accepted, and logged as such.
        BOOL accepted = ok || [error isEqualToString:kEmpty];
        if (!ok && accepted) MRGDJLog(@"playlists: delete answered empty, taken as accepted (check your Library)");
        if (accepted) forgetMade(playlist);
        finish(@"delete", done, accepted, playlist, accepted ? nil : error);
    });
}
