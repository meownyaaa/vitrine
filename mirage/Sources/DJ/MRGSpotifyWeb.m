#import "MRGSpotifyWeb.h"
#import "MRGPlayer.h"
#import "MRGDJLog.h"

static NSString *const kAPI = @"https://api.spotify.com/v1";

static void call(NSString *method, NSString *path, id body, void (^done)(id json, NSInteger status, NSString *error)) {
    NSString *auth = MRGSpotifyHeaders()[@"authorization"];
    if (!auth) {
        MRGDJLog(@"web %@ %@: no Spotify token captured yet", method, [path componentsSeparatedByString:@"?"].firstObject);
        done(nil, 0, @"Spotify hasn't signed a request yet. Browse a page in Spotify and try again.");
        return;
    }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kAPI stringByAppendingString:path]]];
    r.HTTPMethod = method;
    r.timeoutInterval = 20;
    [r setValue:auth forHTTPHeaderField:@"Authorization"];
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    if (body) {
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *message = nil;
        // Spotify's own error text, when it sent one ({"error": {"status", "message"}}).
        NSString *apiMessage = nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            id e = json[@"error"];
            if ([e isKindOfClass:NSDictionary.class] && [e[@"message"] isKindOfClass:NSString.class]) apiMessage = e[@"message"];
            else if ([e isKindOfClass:NSString.class]) apiMessage = json[@"error_description"] ?: e;
        }
        if (error) message = error.localizedDescription;
        else if (status == 429) message = @"Spotify is rate-limiting for a moment. Try again shortly.";
        else if (status < 200 || status >= 300)
            message = apiMessage.length ? [NSString stringWithFormat:@"Spotify's Web API: %@ (HTTP %ld)", apiMessage, (long)status]
                                        : [NSString stringWithFormat:@"Spotify's Web API answered HTTP %ld.", (long)status];
        // The path without its query (search terms stay out of the log).
        NSString *shown = [path componentsSeparatedByString:@"?"].firstObject;
        if (message || ![method isEqualToString:@"GET"] || [shown isEqualToString:@"/me"])
            MRGDJLog(@"web %@ %@ -> %ld%@", method, shown, (long)status, message ? [@" " stringByAppendingString:message] : @"");
        dispatch_async(dispatch_get_main_queue(), ^{ done(json, status, message); });
    }] resume];
}

static NSString *enc(NSString *s) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#"];
    return [s stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSDictionary *nameOf(NSDictionary *track) {
    if (![track isKindOfClass:NSDictionary.class] || ![track[@"name"] isKindOfClass:NSString.class]) return nil;
    NSArray *artists = track[@"artists"];
    NSString *artist = ([artists isKindOfClass:NSArray.class] && [artists.firstObject isKindOfClass:NSDictionary.class] && [artists.firstObject[@"name"] isKindOfClass:NSString.class]) ? artists.firstObject[@"name"] : @"";
    return @{@"title": track[@"name"], @"artist": [artist isKindOfClass:NSString.class] ? artist : @""};
}

static NSString *norm(NSString *s) {
    if (![s isKindOfClass:NSString.class]) return @"";
    NSString *l = [[s lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
    l = [l stringByReplacingOccurrencesOfString:@"&" withString:@"and"];
    l = [l stringByReplacingOccurrencesOfString:@"$" withString:@"s"];
    l = [l stringByReplacingOccurrencesOfString:@"’" withString:@"'"];
    if ([l hasPrefix:@"the "]) l = [l substringFromIndex:4];
    // "Song (feat. X) - Remastered 2011" matches "Song".
    for (NSString *cut in @[@" (", @" - ", @" ["]) {
        NSRange r = [l rangeOfString:cut];
        if (r.location != NSNotFound && r.location > 0) l = [l substringToIndex:r.location];
    }
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < l.length; i++) {
        unichar c = [l characterAtIndex:i];
        if ([keep characterIsMember:c]) [out appendFormat:@"%C", c];
    }
    return out;
}

NSString *MRGImageURL(NSString *image) {
    if (![image isKindOfClass:NSString.class] || !image.length) return nil;
    if ([image hasPrefix:@"https://"]) return image;
    if ([image hasPrefix:@"spotify:image:"]) return [@"https://i.scdn.co/image/" stringByAppendingString:[image substringFromIndex:14]];
    return nil;
}

// The album cover closest to 300px wide (Spotify sends 640, 300 and 64).
static NSString *coverOf(NSDictionary *track) {
    NSDictionary *album = [track isKindOfClass:NSDictionary.class] ? track[@"album"] : nil;
    NSArray *images = [album isKindOfClass:NSDictionary.class] ? album[@"images"] : nil;
    if (![images isKindOfClass:NSArray.class]) return nil;
    NSString *best = nil;
    double bestScore = DBL_MAX;
    for (NSDictionary *im in images) {
        if (![im isKindOfClass:NSDictionary.class] || ![im[@"url"] isKindOfClass:NSString.class]) continue;
        double w = [im[@"width"] respondsToSelector:@selector(doubleValue)] ? [im[@"width"] doubleValue] : 300;
        double score = fabs(w - 300);
        if (score < bestScore) { bestScore = score; best = im[@"url"]; }
    }
    return best;
}

// json[group][@"items"] when both are what they should be, else nil.
static NSArray *itemsIn(id json, NSString *group) {
    id g = [json isKindOfClass:NSDictionary.class] ? json[group] : nil;
    id items = [g isKindOfClass:NSDictionary.class] ? g[@"items"] : nil;
    return [items isKindOfClass:NSArray.class] ? items : nil;
}

static NSDictionary *resolved(NSDictionary *track) {
    if (!track) return nil;
    NSMutableDictionary *d = [@{@"uri": track[@"uri"]} mutableCopy];
    NSDictionary *names = nameOf(track);
    if (names) [d addEntriesFromDictionary:names];   // Spotify's own title and artist, not the model's spelling
    NSString *cover = coverOf(track);
    if (cover) d[@"image"] = cover;
    if ([track[@"popularity"] isKindOfClass:NSNumber.class]) d[@"popularity"] = track[@"popularity"];
    NSDictionary *album = track[@"album"];
    if ([album isKindOfClass:NSDictionary.class] && [album[@"name"] isKindOfClass:NSString.class]) d[@"album"] = album[@"name"];
    if ([album isKindOfClass:NSDictionary.class] && [album[@"release_date"] isKindOfClass:NSString.class]) d[@"released"] = album[@"release_date"];
    return d;
}

// Edit distance (Levenshtein) of two short strings, capped: small typos and spelling variants still match.
NSInteger MRGEditDistance(NSString *a, NSString *b) {
    NSUInteger n = a.length, m = b.length;
    if (!n) return m;
    if (!m) return n;
    if (n > 64 || m > 64) return [a isEqualToString:b] ? 0 : 99;
    NSInteger prev[65], cur[65];
    for (NSUInteger j = 0; j <= m; j++) prev[j] = j;
    for (NSUInteger i = 1; i <= n; i++) {
        cur[0] = i;
        unichar ca = [a characterAtIndex:i - 1];
        for (NSUInteger j = 1; j <= m; j++) {
            NSInteger cost = ca == [b characterAtIndex:j - 1] ? 0 : 1;
            cur[j] = MIN(MIN(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
        }
        memcpy(prev, cur, sizeof(NSInteger) * (m + 1));
    }
    return prev[m];
}

// Close enough for names: equal, one containing the other (both long enough), or a small edit distance.
BOOL MRGNamesMatch(NSString *x, NSString *y) {
    NSString *a = norm(x), *b = norm(y);
    if (!a.length || !b.length) return NO;
    if ([a isEqualToString:b]) return YES;
    if (a.length >= 4 && b.length >= 4 && ([a containsString:b] || [b containsString:a])) return YES;
    NSUInteger shorter = MIN(a.length, b.length);
    NSInteger d = MRGEditDistance(a, b);
    return (shorter >= 5 && d <= 1) || (shorter >= 9 && d <= 2);
}

// The artists the model wrote for a pick ("A feat. B", "A & B", "A, B", "A x B").
static NSArray<NSString *> *artistParts(NSString *artist) {
    NSMutableArray *out = [NSMutableArray array];
    if (![artist isKindOfClass:NSString.class]) return out;
    NSString *l = [artist lowercaseString];
    for (NSString *sep in @[@" feat. ", @" feat ", @" ft. ", @" ft ", @" featuring ", @" & ", @", ", @" x ", @" and ", @" with "])
        l = [l stringByReplacingOccurrencesOfString:sep withString:@"|"];
    for (NSString *p in [l componentsSeparatedByString:@"|"]) if (norm(p).length) [out addObject:p];
    if (![out containsObject:artist.lowercaseString]) [out insertObject:artist.lowercaseString atIndex:0];
    return out;
}

// A search hit counts when the title matches (exactly, as a prefix with a suffix such as "- Remastered", or within a
// typo) and one of its artists matches one the model named. The best-scoring hit wins; a song the model made up finds
// nothing and is dropped.
static NSDictionary *bestMatch(id json, NSString *title, NSString *artist) {
    NSArray *items = itemsIn(json, @"tracks");
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSString *t = norm(title);
    if (!t.length) return nil;
    NSArray *wanted = artistParts(artist);
    NSDictionary *best = nil;
    NSInteger bestScore = 0;
    for (NSDictionary *track in items) {
        if (![track isKindOfClass:NSDictionary.class] || ![track[@"uri"] isKindOfClass:NSString.class]) continue;
        if (![track[@"uri"] hasPrefix:@"spotify:track:"]) continue;
        NSString *name = norm([track[@"name"] isKindOfClass:NSString.class] ? track[@"name"] : @"");
        if (!name.length) continue;
        NSInteger score = 0;
        if ([name isEqualToString:t]) score = 100;
        else if (([name hasPrefix:t] && t.length >= 4) || ([t hasPrefix:name] && name.length >= 4)) score = 80;
        else if (MIN(name.length, t.length) >= 6 && MRGEditDistance(name, t) <= 2) score = 60;
        else if (t.length >= 6 && name.length >= 6 && ([name containsString:t] || [t containsString:name])) score = 50;
        if (!score) continue;
        BOOL artistOK = !wanted.count;
        for (NSDictionary *ar in [track[@"artists"] isKindOfClass:NSArray.class] ? track[@"artists"] : nil) {
            NSString *n = [ar isKindOfClass:NSDictionary.class] && [ar[@"name"] isKindOfClass:NSString.class] ? ar[@"name"] : nil;
            for (NSString *w in wanted) if (MRGNamesMatch(n, w)) { artistOK = YES; break; }
            if (artistOK) break;
        }
        if (!artistOK) continue;
        if (score > bestScore) { bestScore = score; best = track; }
    }
    return best ? resolved(best) : nil;
}

void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSDictionary *, NSString *)) {
    NSString *strict = [NSString stringWithFormat:@"track:\"%@\" artist:\"%@\"", title, artist];
    NSString *path = [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc(strict)];
    call(@"GET", path, nil, ^(id j, NSInteger s, NSString *e) {
        NSDictionary *match = e ? nil : bestMatch(j, title, artist);
        if (match) { done(match, nil); return; }
        if (e && s != 0 && s != 400 && s != 404) { done(nil, e); return; }
        NSString *loose = [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc([NSString stringWithFormat:@"%@ %@", title, artist])];
        call(@"GET", loose, nil, ^(id j2, NSInteger s2, NSString *e2) {
            NSDictionary *m2 = e2 ? nil : bestMatch(j2, title, artist);
            if (m2) { done(m2, nil); return; }
            if (e2) { MRGDJLog(@"resolve: Web API search failed (%@)", e2); done(nil, e2); return; }
            // The title on its own (the model's artist spelling can be far off from Spotify's), then the first artist
            // named with the title.
            NSString *bare = [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc(title)];
            call(@"GET", bare, nil, ^(id j3, NSInteger s3, NSString *e3) {
                NSDictionary *m3 = e3 ? nil : bestMatch(j3, title, artist);
                if (m3) { done(m3, nil); return; }
                MRGDJLog(@"resolve: no real match for \"%@\" by %@ after 3 searches, dropped", title, artist);
                done(nil, e3);
            });
        });
    });
}

// The largest-but-reasonable image of an artist object (about 300px), or nil.
static NSString *artistImage(NSDictionary *artist) {
    NSArray *images = [artist[@"images"] isKindOfClass:NSArray.class] ? artist[@"images"] : nil;
    NSString *best = nil;
    NSInteger bestDiff = NSIntegerMax;
    for (NSDictionary *im in images) {
        if (![im isKindOfClass:NSDictionary.class] || ![im[@"url"] isKindOfClass:NSString.class]) continue;
        NSInteger w = [im[@"width"] respondsToSelector:@selector(integerValue)] ? [im[@"width"] integerValue] : 300;
        NSInteger diff = labs(w - 320);
        if (diff < bestDiff) { bestDiff = diff; best = im[@"url"]; }
    }
    return best;
}

void MRGWebSearch(NSString *query, NSString *type, NSInteger limit, void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    if (!query.length) { done(@[], nil); return; }
    NSString *t = [type isEqualToString:@"artist"] || [type isEqualToString:@"playlist"] || [type isEqualToString:@"album"] ? type : @"track";
    NSString *path = [NSString stringWithFormat:@"/search?type=%@&limit=%ld&q=%@", t, (long)MAX(1, MIN(10, limit)), enc(query)];
    call(@"GET", path, nil, ^(id j, NSInteger s, NSString *e) {
        if (e) { MRGDJLog(@"search (%@): Web API search failed (%@)", t, e); done(nil, e); return; }
        NSArray *items = itemsIn(j, [t stringByAppendingString:@"s"]);
        NSMutableArray *out = [NSMutableArray array];
        for (NSDictionary *it in [items isKindOfClass:NSArray.class] ? items : @[]) {
            if (![it isKindOfClass:NSDictionary.class] || ![it[@"uri"] isKindOfClass:NSString.class]) continue;
            if ([t isEqualToString:@"track"]) { NSDictionary *r = resolved(it); if (r) [out addObject:r]; continue; }
            NSMutableDictionary *d = [@{@"uri": it[@"uri"], @"name": [it[@"name"] isKindOfClass:NSString.class] ? it[@"name"] : @""} mutableCopy];
            NSString *img = artistImage(it);
            if (img) d[@"image"] = img;
            if ([it[@"popularity"] isKindOfClass:NSNumber.class]) d[@"popularity"] = it[@"popularity"];
            if ([it[@"genres"] isKindOfClass:NSArray.class]) d[@"genres"] = [it[@"genres"] subarrayWithRange:NSMakeRange(0, MIN(3, [it[@"genres"] count]))];
            NSDictionary *owner = it[@"owner"];
            if ([owner isKindOfClass:NSDictionary.class] && [owner[@"display_name"] isKindOfClass:NSString.class]) d[@"owner"] = owner[@"display_name"];
            NSArray *artists = it[@"artists"];
            if ([artists isKindOfClass:NSArray.class] && artists.count && [artists[0] isKindOfClass:NSDictionary.class]) d[@"artist"] = artists[0][@"name"] ?: @"";
            [out addObject:d];
        }
        MRGDJLog(@"search (%@): %lu results via Web API search", t, (unsigned long)out.count);
        done(out, nil);
    });
}

#pragma mark - artists

static NSString *artistIDOf(NSString *uri) { return [uri hasPrefix:@"spotify:artist:"] ? [uri substringFromIndex:15] : nil; }

static NSDictionary *artistOut(NSDictionary *it) {
    if (![it isKindOfClass:NSDictionary.class] || ![it[@"uri"] isKindOfClass:NSString.class] || ![it[@"name"] isKindOfClass:NSString.class]) return nil;
    NSMutableDictionary *d = [@{@"uri": it[@"uri"], @"name": it[@"name"]} mutableCopy];
    NSString *img = artistImage(it);
    if (img) d[@"image"] = img;
    if ([it[@"popularity"] isKindOfClass:NSNumber.class]) d[@"popularity"] = it[@"popularity"];
    if ([it[@"genres"] isKindOfClass:NSArray.class]) {
        NSMutableArray *g = [NSMutableArray array];
        for (id x in it[@"genres"]) if ([x isKindOfClass:NSString.class]) [g addObject:x];
        d[@"genres"] = [g subarrayWithRange:NSMakeRange(0, MIN(g.count, (NSUInteger)4))];
    }
    return d;
}

// Finds the artist someone means by what they typed ("yvl", "Pz", "the weeknd", "travis"): artist search on the text
// as typed and in upper case, the closest name (exact, then fuzzy, then the first hit if the text is its initials),
// then a track search whose artists are checked the same way, then a combined search.
void MRGWebFindArtist(NSString *query, void (^done)(NSDictionary *artist, NSString *how)) {
    NSString *q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) { done(nil, @"empty"); return; }
    NSString *nq = norm(q);
    NSDictionary *(^pick)(NSArray *) = ^NSDictionary *(NSArray *list) {
        NSDictionary *exact = nil, *fuzzy = nil, *initials = nil;
        for (NSDictionary *it in list) {
            NSDictionary *a = artistOut(it);
            if (!a) continue;
            NSString *n = norm(a[@"name"]);
            if ([n isEqualToString:nq]) { exact = exact ?: a; continue; }
            if (!fuzzy && MRGNamesMatch(a[@"name"], q)) fuzzy = a;
            if (!initials && nq.length >= 2 && nq.length <= 5) {
                NSMutableString *ini = [NSMutableString string];
                for (NSString *w in [[a[@"name"] lowercaseString] componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) if (w.length) [ini appendString:[w substringToIndex:1]];
                if ([norm(ini) isEqualToString:nq]) initials = a;
            }
        }
        return exact ?: fuzzy ?: initials;
    };
    NSArray *variants = [q.uppercaseString isEqualToString:q] ? @[q] : @[q, q.uppercaseString];
    __block void (^tryVariant)(NSUInteger);
    __block void (^viaTracks)(void);
    void (^fallback)(void) = ^{
        call(@"GET", [NSString stringWithFormat:@"/search?type=artist,track&limit=10&q=%@", enc(q)], nil, ^(id j, NSInteger s, NSString *e) {
            NSDictionary *a = e ? nil : pick(itemsIn(j, @"artists"));
            if (!a) {
                for (NSDictionary *tr in itemsIn(j, @"tracks") ?: @[]) {
                    for (NSDictionary *ar in [tr isKindOfClass:NSDictionary.class] && [tr[@"artists"] isKindOfClass:NSArray.class] ? tr[@"artists"] : @[]) {
                        if ([ar isKindOfClass:NSDictionary.class] && MRGNamesMatch(ar[@"name"], q) && [ar[@"uri"] isKindOfClass:NSString.class]) { a = @{@"uri": ar[@"uri"], @"name": ar[@"name"]}; break; }
                    }
                    if (a) break;
                }
            }
            MRGDJLog(@"artist: %@ for a %lu-letter request%@", a ? @"found via combined search" : @"no match", (unsigned long)q.length, e ? [@", " stringByAppendingString:e] : @"");
            done(a, a ? @"combined search" : nil);
        });
    };
    viaTracks = ^{
        call(@"GET", [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc(q)], nil, ^(id j, NSInteger s, NSString *e) {
            NSDictionary *found = nil;
            for (NSDictionary *tr in e ? @[] : (itemsIn(j, @"tracks") ?: @[])) {
                for (NSDictionary *ar in [tr isKindOfClass:NSDictionary.class] && [tr[@"artists"] isKindOfClass:NSArray.class] ? tr[@"artists"] : @[]) {
                    if ([ar isKindOfClass:NSDictionary.class] && [ar[@"name"] isKindOfClass:NSString.class] && [ar[@"uri"] isKindOfClass:NSString.class] && MRGNamesMatch(ar[@"name"], q)) { found = @{@"uri": ar[@"uri"], @"name": ar[@"name"]}; break; }
                }
                if (found) break;
            }
            if (found) { MRGDJLog(@"artist: found via track search"); done(found, @"track search"); return; }
            fallback();
        });
    };
    tryVariant = ^(NSUInteger i) {
        if (i >= variants.count) { void (^v)(void) = viaTracks; tryVariant = nil; v(); return; }
        call(@"GET", [NSString stringWithFormat:@"/search?type=artist&limit=10&q=%@", enc(variants[i])], nil, ^(id j, NSInteger s, NSString *e) {
            NSDictionary *a = e ? nil : pick(itemsIn(j, @"artists"));
            if (a) { MRGDJLog(@"artist: found via artist search"); tryVariant = nil; done(a, @"artist search"); return; }
            tryVariant(i + 1);
        });
    };
    tryVariant(0);
}

// The artist's most played tracks: the top-tracks endpoint, or a search on artist:"Name" filtered to that artist.
void MRGWebArtistTracks(NSDictionary *artist, NSInteger limit, void (^done)(NSArray<NSDictionary *> *tracks)) {
    NSString *aid = artistIDOf(artist[@"uri"]);
    NSString *name = [artist[@"name"] isKindOfClass:NSString.class] ? artist[@"name"] : nil;
    if (!aid || !name.length) { done(@[]); return; }
    BOOL (^byArtist)(NSDictionary *) = ^BOOL(NSDictionary *tr) {
        for (NSDictionary *ar in [tr[@"artists"] isKindOfClass:NSArray.class] ? tr[@"artists"] : @[])
            if ([ar isKindOfClass:NSDictionary.class] && ([ar[@"uri"] isEqual:artist[@"uri"]] || MRGNamesMatch(ar[@"name"], name))) return YES;
        return NO;
    };
    void (^search)(NSMutableArray *) = ^(NSMutableArray *have) {
        NSString *q = [NSString stringWithFormat:@"artist:\"%@\"", name];
        call(@"GET", [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc(q)], nil, ^(id j, NSInteger s, NSString *e) {
            NSMutableSet *seen = [NSMutableSet set];
            for (NSDictionary *t in have) [seen addObject:t[@"uri"]];
            for (NSDictionary *tr in itemsIn(j, @"tracks") ?: @[]) {
                if (![tr isKindOfClass:NSDictionary.class] || !byArtist(tr)) continue;
                NSDictionary *r = resolved(tr);
                if (r[@"uri"] && ![seen containsObject:r[@"uri"]]) { [seen addObject:r[@"uri"]]; [have addObject:r]; }
            }
            call(@"GET", [NSString stringWithFormat:@"/search?type=track&limit=10&offset=10&q=%@", enc(q)], nil, ^(id j2, NSInteger s2, NSString *e2) {
                for (NSDictionary *tr in itemsIn(j2, @"tracks") ?: @[]) {
                    if (![tr isKindOfClass:NSDictionary.class] || !byArtist(tr)) continue;
                    NSDictionary *r = resolved(tr);
                    if (r[@"uri"] && ![seen containsObject:r[@"uri"]]) { [seen addObject:r[@"uri"]]; [have addObject:r]; }
                }
                MRGDJLog(@"artist: %lu tracks of theirs found", (unsigned long)have.count);
                done([have subarrayWithRange:NSMakeRange(0, MIN(have.count, (NSUInteger)MAX(1, limit)))]);
            });
        });
    };
    call(@"GET", [NSString stringWithFormat:@"/artists/%@/top-tracks?market=from_token", aid], nil, ^(id j, NSInteger s, NSString *e) {
        NSMutableArray *out = [NSMutableArray array];
        id list = [j isKindOfClass:NSDictionary.class] ? j[@"tracks"] : nil;
        for (NSDictionary *tr in [list isKindOfClass:NSArray.class] ? list : @[]) { NSDictionary *r = [tr isKindOfClass:NSDictionary.class] ? resolved(tr) : nil; if (r[@"uri"]) [out addObject:r]; }
        if (out.count >= limit || out.count >= 10) { done([out subarrayWithRange:NSMakeRange(0, MIN(out.count, (NSUInteger)limit))]); return; }
        search(out);
    });
}

// Related artists (the endpoint may be closed to this token: then an empty list, and the model's picks stand in).
void MRGWebRelatedArtists(NSDictionary *artist, void (^done)(NSArray<NSDictionary *> *artists)) {
    NSString *aid = artistIDOf(artist[@"uri"]);
    if (!aid) { done(@[]); return; }
    call(@"GET", [NSString stringWithFormat:@"/artists/%@/related-artists", aid], nil, ^(id j, NSInteger s, NSString *e) {
        NSMutableArray *out = [NSMutableArray array];
        id list = [j isKindOfClass:NSDictionary.class] ? j[@"artists"] : nil;
        for (NSDictionary *it in [list isKindOfClass:NSArray.class] ? list : @[]) { NSDictionary *a = artistOut(it); if (a) [out addObject:a]; if (out.count >= 10) break; }
        done(out);
    });
}

// The artist object itself (genres, popularity, image), or nil.
void MRGWebArtist(NSString *uri, void (^done)(NSDictionary *artist)) {
    NSString *aid = artistIDOf(uri);
    if (!aid) { done(nil); return; }
    call(@"GET", [NSString stringWithFormat:@"/artists/%@", aid], nil, ^(id j, NSInteger s, NSString *e) { done(e ? nil : artistOut(j)); });
}
