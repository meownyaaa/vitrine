#import "MRGHistory.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"
#import <compression.h>
#import <UIKit/UIKit.h>

NSString *const MRGHistoryChangedNotification = @"MirageHistoryChanged";

static dispatch_queue_t Q(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("mirage.history", DISPATCH_QUEUE_SERIAL); });
    return q;
}

// The index (only touched on Q):
//   artists: key → {name, first, firstTrack, firstURI, last, plays, ms, src}
//   tracks:  key → {title, artist, uri, first, last, plays, ms}
//   years:   "2023" → {plays, ms, artists: {key: ms}, tracks: {key: ms}}
//   recent:  [{title, artist, uri, at, ms}] newest last, max 500
//   meta:    {liveSince, importedPlays, livePlays, files: [names], from, to}
static NSMutableDictionary *sIndex;
static BOOL sDirty;

static NSURL *fileURL(void) {
    NSURL *lib = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [lib URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:@"history.plist"];
}

static NSMutableDictionary *mutableDeep(id obj) {
    return [NSPropertyListSerialization propertyListWithData:[NSPropertyListSerialization dataWithPropertyList:obj format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]
                                                     options:NSPropertyListMutableContainersAndLeaves format:nil error:nil];
}

static NSMutableDictionary *idx(void) {
    if (sIndex) return sIndex;
    NSData *d = [NSData dataWithContentsOfURL:fileURL()];
    id plist = d ? [NSPropertyListSerialization propertyListWithData:d options:NSPropertyListMutableContainersAndLeaves format:nil error:nil] : nil;
    sIndex = [plist isKindOfClass:NSMutableDictionary.class] ? plist : nil;
    if (!sIndex) sIndex = mutableDeep(@{@"artists": @{}, @"tracks": @{}, @"years": @{}, @"recent": @[], @"meta": @{@"files": @[]}});
    for (NSString *k in @[@"artists", @"tracks", @"years"]) if (![sIndex[k] isKindOfClass:NSMutableDictionary.class]) sIndex[k] = [NSMutableDictionary dictionary];
    if (![sIndex[@"recent"] isKindOfClass:NSMutableArray.class]) sIndex[@"recent"] = [NSMutableArray array];
    if (![sIndex[@"meta"] isKindOfClass:NSMutableDictionary.class]) sIndex[@"meta"] = [NSMutableDictionary dictionary];
    if (![sIndex[@"meta"][@"files"] isKindOfClass:NSMutableArray.class]) sIndex[@"meta"][@"files"] = [NSMutableArray array];
    return sIndex;
}

static void saveNow(void) {
    if (!sDirty || !sIndex) return;
    sDirty = NO;
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:sIndex format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    [d writeToURL:fileURL() options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:MRGHistoryChangedNotification object:nil]; });
}

static void saveSoon(void) {
    if (sDirty) return;
    sDirty = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), Q(), ^{ saveNow(); });
}

static NSString *norm(NSString *s) {
    NSString *l = [[s ?: @"" lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < l.length; i++) { unichar c = [l characterAtIndex:i]; if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) [out appendFormat:@"%C", c]; }
    return out;
}

static NSString *yearOf(double ts) {
    static NSCalendar *cal;
    if (!cal) cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    return [NSString stringWithFormat:@"%ld", (long)[cal component:NSCalendarUnitYear fromDate:[NSDate dateWithTimeIntervalSince1970:ts]]];
}

// Adds one listen (on Q). Under 30 s it only adds time, not a play.
static void addPlay(double ts, NSString *title, NSString *artist, NSString *uri, double ms, NSString *src) {
    if (!title.length || !artist.length || ts <= 0) return;
    NSMutableDictionary *I = idx();
    BOOL counts = ms >= 30000;
    NSString *ak = norm(artist);
    NSString *tk = uri.length ? uri : [NSString stringWithFormat:@"%@|%@", norm(title), ak];
    if (!ak.length) return;
    NSMutableDictionary *a = I[@"artists"][ak];
    if (!a) { a = [@{@"name": artist, @"first": @(ts), @"firstTrack": title, @"firstURI": uri ?: @"", @"last": @(ts), @"plays": @0, @"ms": @0, @"src": src} mutableCopy]; I[@"artists"][ak] = a; }
    if (counts && ts < [a[@"first"] doubleValue]) { a[@"first"] = @(ts); a[@"firstTrack"] = title; a[@"firstURI"] = uri ?: @""; a[@"src"] = src; }
    if (ts > [a[@"last"] doubleValue]) a[@"last"] = @(ts);
    a[@"ms"] = @([a[@"ms"] doubleValue] + ms);
    if (counts) a[@"plays"] = @([a[@"plays"] integerValue] + 1);
    NSMutableDictionary *t = I[@"tracks"][tk];
    if (!t) { t = [@{@"title": title, @"artist": artist, @"uri": uri ?: @"", @"first": @(ts), @"last": @(ts), @"plays": @0, @"ms": @0} mutableCopy]; I[@"tracks"][tk] = t; }
    if (ts < [t[@"first"] doubleValue]) t[@"first"] = @(ts);
    if (ts > [t[@"last"] doubleValue]) t[@"last"] = @(ts);
    t[@"ms"] = @([t[@"ms"] doubleValue] + ms);
    if (counts) t[@"plays"] = @([t[@"plays"] integerValue] + 1);
    NSString *y = yearOf(ts);
    NSMutableDictionary *yr = I[@"years"][y];
    if (!yr) { yr = [@{@"plays": @0, @"ms": @0, @"artists": [NSMutableDictionary dictionary], @"tracks": [NSMutableDictionary dictionary]} mutableCopy]; I[@"years"][y] = yr; }
    yr[@"ms"] = @([yr[@"ms"] doubleValue] + ms);
    if (counts) yr[@"plays"] = @([yr[@"plays"] integerValue] + 1);
    yr[@"artists"][ak] = @([yr[@"artists"][ak] doubleValue] + ms);
    yr[@"tracks"][tk] = @([yr[@"tracks"][tk] doubleValue] + ms);
    NSMutableDictionary *meta = I[@"meta"];
    if (!meta[@"from"] || ts < [meta[@"from"] doubleValue]) meta[@"from"] = @(ts);
    if (!meta[@"to"] || ts > [meta[@"to"] doubleValue]) meta[@"to"] = @(ts);
    if (counts) {
        NSString *k = [src isEqualToString:@"live"] ? @"livePlays" : @"importedPlays";
        meta[k] = @([meta[k] integerValue] + 1);
    }
    if (counts && [src isEqualToString:@"live"]) {
        NSMutableArray *recent = I[@"recent"];
        [recent addObject:@{@"title": title, @"artist": artist, @"uri": uri ?: @"", @"at": @(ts), @"ms": @(ms)}];
        if (recent.count > 500) [recent removeObjectsInRange:NSMakeRange(0, recent.count - 500)];
    }
}

#pragma mark - live

static NSDictionary *sCurrent;      // the track playing: title, artist, uri, duration
static double sCurrentStart;        // its wall-clock start (seconds since 1970)

static void closeCurrent(double now) {
    if (!sCurrent) return;
    double played = now - sCurrentStart;
    double duration = [sCurrent[@"duration"] doubleValue];
    if (duration > 0) played = MIN(played, duration);
    if (played > 3 * 3600) played = 0;   // the app slept: not a listen
    NSDictionary *c = sCurrent;
    double start = sCurrentStart;
    sCurrent = nil;
    if (played <= 0) return;
    dispatch_async(Q(), ^{
        NSMutableDictionary *meta = idx()[@"meta"];
        if (!meta[@"liveSince"]) meta[@"liveSince"] = @(start);
        addPlay(start, c[@"title"], c[@"artist"], c[@"uri"], played * 1000, @"live");
        saveSoon();
    });
}

void MRGHistoryStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(Q(), ^{
            NSMutableDictionary *meta = idx()[@"meta"];
            if (!meta[@"liveSince"]) { meta[@"liveSince"] = @(NSDate.date.timeIntervalSince1970); sDirty = YES; saveNow(); }
        });
        [NSNotificationCenter.defaultCenter addObserverForName:MRGPlayerTrackChangedNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            double now = NSDate.date.timeIntervalSince1970;
            closeCurrent(now);
            NSDictionary *u = n.userInfo;
            if ([u[@"ad"] boolValue] || ![u[@"title"] length] || ![u[@"uri"] hasPrefix:@"spotify:track:"]) return;
            sCurrent = @{@"title": u[@"title"], @"artist": u[@"artist"] ?: @"", @"uri": u[@"uri"], @"duration": u[@"duration"] ?: @0};
            sCurrentStart = now;
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillTerminateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            closeCurrent(NSDate.date.timeIntervalSince1970);
            dispatch_sync(Q(), ^{ saveNow(); });
        }];
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            dispatch_async(Q(), ^{ saveNow(); });
        }];
    });
}

#pragma mark - import

static double parseTS(NSString *s) {
    if (![s isKindOfClass:NSString.class] || s.length < 10) return 0;
    static NSISO8601DateFormatter *iso;
    static NSDateFormatter *plain;
    if (!iso) {
        iso = [NSISO8601DateFormatter new];
        plain = [NSDateFormatter new];
        plain.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        plain.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        plain.dateFormat = @"yyyy-MM-dd HH:mm";
    }
    NSDate *d = [iso dateFromString:s] ?: [plain dateFromString:s];
    return d.timeIntervalSince1970;
}

// One JSON file's plays (on Q). Returns plays added; *skipped counts plays after live recording began.
static NSUInteger importJSON(NSData *data, NSUInteger *skipped, NSString **error) {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:NSArray.class]) { if (error) *error = @"That file isn't a Spotify streaming history (expected a JSON list)."; return 0; }
    double liveSince = [idx()[@"meta"][@"liveSince"] doubleValue];
    NSUInteger added = 0;
    for (NSDictionary *e in json) {
        if (![e isKindOfClass:NSDictionary.class]) continue;
        NSString *title, *artist, *uri = nil; double ts, ms;
        if (e[@"ts"]) {   // Extended streaming history
            title = e[@"master_metadata_track_name"]; artist = e[@"master_metadata_album_artist_name"];
            uri = [e[@"spotify_track_uri"] isKindOfClass:NSString.class] ? e[@"spotify_track_uri"] : nil;
            ts = parseTS(e[@"ts"]); ms = [e[@"ms_played"] doubleValue];
            // ts is when the stream ended; the start is about ms_played earlier.
            ts -= ms / 1000.0;
        } else {          // Account data StreamingHistory_music_*.json
            title = e[@"trackName"]; artist = e[@"artistName"];
            ts = parseTS(e[@"endTime"]); ms = [e[@"msPlayed"] doubleValue];
            ts -= ms / 1000.0;
        }
        if (![title isKindOfClass:NSString.class] || ![artist isKindOfClass:NSString.class] || ts <= 0) continue;   // podcasts, audiobooks
        if (liveSince > 0 && ts >= liveSince) { if (skipped && ms >= 30000) (*skipped)++; continue; }
        addPlay(ts, title, artist, uri, ms, @"import");
        if (ms >= 30000) added++;
    }
    return added;
}

static BOOL wanted(NSString *name) {
    NSString *base = name.lastPathComponent;
    if (![base.pathExtension.lowercaseString isEqualToString:@"json"] || [base hasPrefix:@"._"]) return NO;
    return [base rangeOfString:@"Streaming_History_Audio" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [base rangeOfString:@"StreamingHistory_music" options:NSCaseInsensitiveSearch].location != NSNotFound
        || [base rangeOfString:@"StreamingHistory" options:NSCaseInsensitiveSearch].location == 0
        || [base rangeOfString:@"endsong" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static uint32_t rd32(const uint8_t *p) { return p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24); }
static uint16_t rd16(const uint8_t *p) { return p[0] | (p[1] << 8); }

// The streaming-history JSON files inside a ZIP (stored or deflated, from the central directory), name → data.
static NSDictionary<NSString *, NSData *> *unzipHistory(NSData *zip, NSString **error) {
    const uint8_t *b = zip.bytes; NSUInteger n = zip.length;
    if (n < 22) { *error = @"That ZIP is empty or damaged."; return nil; }
    NSInteger eocd = -1;
    for (NSInteger i = (NSInteger)n - 22; i >= 0 && i >= (NSInteger)n - 22 - 65535; i--) if (rd32(b + i) == 0x06054b50) { eocd = i; break; }
    if (eocd < 0) { *error = @"That ZIP is damaged (no central directory)."; return nil; }
    NSUInteger count = rd16(b + eocd + 10), cd = rd32(b + eocd + 16);
    if (cd == 0xFFFFFFFF) { *error = @"That ZIP uses ZIP64, which Mirage can't open; unzip it in Files and pick the JSON files."; return nil; }
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSUInteger p = cd;
    for (NSUInteger k = 0; k < count && p + 46 <= n; k++) {
        if (rd32(b + p) != 0x02014b50) break;
        uint16_t method = rd16(b + p + 10);
        uint32_t csize = rd32(b + p + 20), usize = rd32(b + p + 24);
        uint16_t nlen = rd16(b + p + 28), xlen = rd16(b + p + 30), clen = rd16(b + p + 32);
        uint32_t local = rd32(b + p + 42);
        if (p + 46 + nlen > n) break;
        NSString *name = [[NSString alloc] initWithBytes:b + p + 46 length:nlen encoding:NSUTF8StringEncoding];
        p += 46 + nlen + xlen + clen;
        if (!wanted(name) || local + 30 > n || rd32(b + local) != 0x04034b50) continue;
        NSUInteger dataAt = local + 30 + rd16(b + local + 26) + rd16(b + local + 28);
        if (dataAt + csize > n || usize > 400 * 1024 * 1024) continue;
        NSData *file = nil;
        if (method == 0) file = [NSData dataWithBytes:b + dataAt length:csize];
        else if (method == 8) {
            NSMutableData *buf = [NSMutableData dataWithLength:usize + 1];
            size_t got = compression_decode_buffer(buf.mutableBytes, usize + 1, b + dataAt, csize, NULL, COMPRESSION_ZLIB);
            if (got == usize) { buf.length = usize; file = buf; }
        }
        if (file) out[name.lastPathComponent] = file;
        else MRGDJLog(@"history: couldn't unpack %@ (method %u)", name, method);
    }
    if (!out.count) *error = @"No streaming history files in that ZIP (looking for Streaming_History_Audio_*.json).";
    return out;
}

void MRGHistoryImport(NSURL *url, void (^done)(NSUInteger, NSUInteger, NSString *)) {
    dispatch_async(Q(), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSData *data = [NSData dataWithContentsOfURL:url options:NSDataReadingMappedIfSafe error:nil];
        if (scoped) [url stopAccessingSecurityScopedResource];
        NSString *error = nil;
        NSDictionary<NSString *, NSData *> *files = nil;
        if (!data) error = @"Couldn't read that file.";
        else if (data.length > 4 && rd32(data.bytes) == 0x04034b50) files = unzipHistory(data, &error);
        else files = @{url.lastPathComponent ?: @"history.json": data};
        NSUInteger plays = 0, used = 0, skipped = 0;
        NSMutableArray *names = idx()[@"meta"][@"files"];
        for (NSString *name in [files.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            NSString *sig = [NSString stringWithFormat:@"%@ (%lu)", name, (unsigned long)files[name].length];
            if ([names containsObject:sig]) { MRGDJLog(@"history: %@ was imported before, skipped", name); continue; }
            NSString *e = nil;
            NSUInteger added = importJSON(files[name], &skipped, &e);
            if (e && files.count == 1) { error = e; break; }
            if (e) { MRGDJLog(@"history: %@: %@", name, e); continue; }
            [names addObject:sig];
            plays += added; used++;
        }
        if (used) { sDirty = YES; saveNow(); }
        MRGDJLog(@"history: import added %lu plays from %lu files%@", (unsigned long)plays, (unsigned long)used,
                 skipped ? [NSString stringWithFormat:@" (%lu after live recording began were skipped)", (unsigned long)skipped] : @"");
        if (!error && !used && files.count) error = @"Those files were already imported.";
        dispatch_async(dispatch_get_main_queue(), ^{ done(plays, used, used ? nil : error); });
    });
}

void MRGHistoryClear(BOOL imported, BOOL live) {
    dispatch_async(Q(), ^{
        if (imported && live) {
            sIndex = nil;
            [NSFileManager.defaultManager removeItemAtURL:fileURL() error:nil];
            idx()[@"meta"][@"liveSince"] = @(NSDate.date.timeIntervalSince1970);
            sDirty = YES; saveNow();
            return;
        }
        // Rebuilding from parts isn't possible from the aggregate; imported-only clear keeps live "recent" and re-adds it.
        NSArray *recent = [idx()[@"recent"] copy];
        NSNumber *liveSince = idx()[@"meta"][@"liveSince"];
        sIndex = nil;
        [NSFileManager.defaultManager removeItemAtURL:fileURL() error:nil];
        idx()[@"meta"][@"liveSince"] = liveSince ?: @(NSDate.date.timeIntervalSince1970);
        if (imported) for (NSDictionary *r in recent) addPlay([r[@"at"] doubleValue], r[@"title"], r[@"artist"], r[@"uri"], [r[@"ms"] doubleValue], @"live");
        sDirty = YES; saveNow();
    });
}

#pragma mark - queries

static id onQ(id (^block)(void)) {
    __block id r = nil;
    dispatch_sync(Q(), ^{ r = block(); });
    return r;
}

static NSDate *date(id v) { return v ? [NSDate dateWithTimeIntervalSince1970:[v doubleValue]] : nil; }

NSDictionary *MRGHistorySummary(void) {
    return onQ(^id {
        NSDictionary *m = idx()[@"meta"];
        NSUInteger plays = [m[@"importedPlays"] integerValue] + [m[@"livePlays"] integerValue];
        double ms = 0;
        for (NSDictionary *y in [idx()[@"years"] allValues]) ms += [y[@"ms"] doubleValue];
        NSMutableDictionary *d = [@{@"plays": @(plays), @"minutes": @((NSInteger)(ms / 60000)), @"importedPlays": m[@"importedPlays"] ?: @0,
                                    @"livePlays": m[@"livePlays"] ?: @0, @"importedFiles": [m[@"files"] copy] ?: @[]} mutableCopy];
        if (m[@"from"]) d[@"from"] = date(m[@"from"]);
        if (m[@"to"]) d[@"to"] = date(m[@"to"]);
        if (m[@"liveSince"]) d[@"liveSince"] = date(m[@"liveSince"]);
        return d;
    });
}

static NSDictionary *artistOut(NSDictionary *a) {
    return @{@"artist": a[@"name"] ?: @"", @"first": date(a[@"first"]), @"firstTrack": a[@"firstTrack"] ?: @"", @"firstURI": a[@"firstURI"] ?: @"",
             @"plays": a[@"plays"] ?: @0, @"minutes": @((NSInteger)([a[@"ms"] doubleValue] / 60000)), @"last": date(a[@"last"]), @"source": a[@"src"] ?: @""};
}

NSDictionary *MRGHistoryArtist(NSString *name) {
    NSString *k = norm(name);
    if (!k.length) return nil;
    return onQ(^id {
        NSDictionary *artists = idx()[@"artists"];
        NSDictionary *a = artists[k];
        if (!a) {
            // "the weeknd" vs "weeknd", "beyonce" vs "beyoncé": the closest containing key with the most time.
            double best = -1;
            for (NSString *key in artists) {
                if (!([key containsString:k] || (key.length >= 4 && [k containsString:key]))) continue;
                double ms = [artists[key][@"ms"] doubleValue];
                if (ms > best) { best = ms; a = artists[key]; }
            }
        }
        return a ? artistOut(a) : nil;
    });
}

NSDictionary *MRGHistoryTrack(NSString *title, NSString *artist) {
    NSString *t = norm(title), *a = norm(artist);
    if (!t.length) return nil;
    return onQ(^id {
        NSDictionary *best = nil;
        for (NSDictionary *tr in [idx()[@"tracks"] allValues]) {
            NSString *tt = norm(tr[@"title"]);
            if (!([tt isEqualToString:t] || ([tt hasPrefix:t] && t.length >= 4))) continue;
            if (a.length && ![norm(tr[@"artist"]) containsString:a] && ![a containsString:norm(tr[@"artist"])]) continue;
            if (!best || [tr[@"ms"] doubleValue] > [best[@"ms"] doubleValue]) best = tr;
        }
        if (!best) return nil;
        return @{@"title": best[@"title"], @"artist": best[@"artist"], @"uri": best[@"uri"] ?: @"", @"first": date(best[@"first"]), @"last": date(best[@"last"]),
                 @"plays": best[@"plays"] ?: @0, @"minutes": @((NSInteger)([best[@"ms"] doubleValue] / 60000))};
    });
}

static NSArray *topOf(NSString *kind, NSString *year, NSUInteger limit) {
    return onQ(^id {
        NSDictionary *all = idx()[kind];
        NSDictionary<NSString *, NSNumber *> *ms = nil;
        if (year.length) ms = idx()[@"years"][year][kind];
        else { NSMutableDictionary *m = [NSMutableDictionary dictionary]; for (NSString *k in all) m[k] = all[k][@"ms"]; ms = m; }
        NSArray *keys = [ms keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *x, NSNumber *y) { return [y compare:x]; }];
        NSMutableArray *out = [NSMutableArray array];
        for (NSString *k in keys) {
            NSDictionary *e = all[k];
            if (!e) continue;
            NSMutableDictionary *d = [@{@"minutes": @((NSInteger)([ms[k] doubleValue] / 60000))} mutableCopy];
            if ([kind isEqualToString:@"artists"]) d[@"name"] = e[@"name"] ?: @"";
            else { d[@"name"] = e[@"title"] ?: @""; d[@"artist"] = e[@"artist"] ?: @""; d[@"uri"] = e[@"uri"] ?: @""; }
            if (!year.length) d[@"plays"] = e[@"plays"] ?: @0;
            [out addObject:d];
            if (out.count >= limit) break;
        }
        return out;
    });
}

NSArray<NSDictionary *> *MRGHistoryTopArtists(NSString *year, NSUInteger limit) { return topOf(@"artists", year, limit); }
NSArray<NSDictionary *> *MRGHistoryTopTracks(NSString *year, NSUInteger limit) { return topOf(@"tracks", year, limit); }

NSArray<NSDictionary *> *MRGHistoryRecent(NSUInteger limit) {
    return onQ(^id {
        NSArray *r = idx()[@"recent"];
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *e in r.reverseObjectEnumerator) {
            [out addObject:@{@"title": e[@"title"] ?: @"", @"artist": e[@"artist"] ?: @"", @"uri": e[@"uri"] ?: @"", @"at": date(e[@"at"]), @"ms": e[@"ms"] ?: @0}];
            if (out.count >= limit) break;
        }
        return out;
    });
}

NSArray<NSDictionary *> *MRGHistoryYears(void) {
    return onQ(^id {
        NSMutableArray *out = [NSMutableArray array];
        NSDictionary *years = idx()[@"years"];
        for (NSString *y in [years.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [out addObject:@{@"year": y, @"plays": years[y][@"plays"] ?: @0, @"minutes": @((NSInteger)([years[y][@"ms"] doubleValue] / 60000))}];
        return out;
    });
}

// What the DJ reads as the listener's taste (on Q, from the index): on repeat (the last 28 days of Mirage's own
// recording, tracks played at least twice), the artists of those weeks, all-time top artists, and throwbacks (tracks
// with real time in them that haven't been played for 4 months; mostly from an imported Spotify history).
NSDictionary *MRGHistoryTaste(void) {
    return onQ(^id {
        double now = NSDate.date.timeIntervalSince1970, since = now - 28 * 86400;
        NSMutableDictionary<NSString *, NSMutableDictionary *> *tracks = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *artists = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *artistNames = [NSMutableDictionary dictionary];
        for (NSDictionary *e in idx()[@"recent"]) {
            if (![e isKindOfClass:NSDictionary.class] || [e[@"at"] doubleValue] < since) continue;
            NSString *title = [e[@"title"] isKindOfClass:NSString.class] ? e[@"title"] : nil, *artist = [e[@"artist"] isKindOfClass:NSString.class] ? e[@"artist"] : @"";
            if (!title.length) continue;
            NSString *k = [NSString stringWithFormat:@"%@|%@", norm(title), norm(artist)];
            NSMutableDictionary *t = tracks[k] ?: (tracks[k] = [@{@"title": title, @"artist": artist, @"uri": e[@"uri"] ?: @"", @"plays": @0} mutableCopy]);
            t[@"plays"] = @([t[@"plays"] integerValue] + 1);
            NSString *ak = norm(artist);
            if (ak.length) { artists[ak] = @(artists[ak].integerValue + 1); artistNames[ak] = artist; }
        }
        NSArray *byPlays = [tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"plays"] compare:a[@"plays"]]; }];
        NSMutableArray *onRepeat = [NSMutableArray array];
        for (NSDictionary *t in byPlays) { if ([t[@"plays"] integerValue] < 2) break; [onRepeat addObject:t]; if (onRepeat.count >= 12) break; }
        NSMutableArray *recentArtists = [NSMutableArray array];
        for (NSString *k in [artists keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }]) {
            [recentArtists addObject:artistNames[k]];
            if (recentArtists.count >= 10) break;
        }
        NSDictionary *all = idx()[@"artists"];
        NSArray *topKeys = [all keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"ms"] ?: @0 compare:a[@"ms"] ?: @0]; }];
        NSMutableArray *allTime = [NSMutableArray array];
        for (NSString *k in topKeys) { NSString *n = all[k][@"name"]; if ([n isKindOfClass:NSString.class] && n.length) [allTime addObject:n]; if (allTime.count >= 12) break; }
        NSMutableArray *oldies = [NSMutableArray array];
        for (NSDictionary *t in [idx()[@"tracks"] allValues]) {
            if (![t isKindOfClass:NSDictionary.class]) continue;
            if ([t[@"plays"] integerValue] >= 4 && [t[@"last"] doubleValue] < now - 120 * 86400) [oldies addObject:t];
        }
        [oldies sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [b[@"plays"] compare:a[@"plays"]]; }];
        NSMutableArray *throwbacks = [NSMutableArray array];
        for (NSDictionary *t in oldies) {
            [throwbacks addObject:@{@"title": t[@"title"] ?: @"", @"artist": t[@"artist"] ?: @"", @"uri": t[@"uri"] ?: @"", @"plays": t[@"plays"] ?: @0, @"year": yearOf([t[@"last"] doubleValue])}];
            if (throwbacks.count >= 12) break;
        }
        return @{@"onRepeat": onRepeat, @"recentArtists": recentArtists, @"allTimeArtists": allTime, @"throwbacks": throwbacks};
    });
}
