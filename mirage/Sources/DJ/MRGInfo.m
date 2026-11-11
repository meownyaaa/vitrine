#import "MRGInfo.h"
#import "MRGSpotifyWeb.h"
#import "MRGAI.h"
#import "MRGDJLog.h"

static void getText(NSString *url, NSString *ua, void (^done)(NSString *text, NSInteger status)) {
    NSURL *u = [NSURL URLWithString:url];
    if (!u) { done(nil, 0); return; }
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:u];
    r.timeoutInterval = 8;
    [r setValue:ua ?: @"Mirage/0.4 (iOS; music info)" forHTTPHeaderField:@"User-Agent"];
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSString *text = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(error ? nil : text, status); });
    }] resume];
}

static NSString *pathPart(NSString *title) {
    NSString *t = [title stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSMutableCharacterSet *ok = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
    [ok addCharactersInString:@"_-.()'"];
    return [t stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

// The first Wikipedia summary among the titles that is a real page and reads like music (and names `must` if given).
static void wikiFirst(NSArray<NSString *> *titles, NSString *must, void (^done)(NSDictionary *wiki)) {
    if (!titles.count) { done(nil); return; }
    NSString *url = [@"https://en.wikipedia.org/api/rest_v1/page/summary/" stringByAppendingString:pathPart(titles.firstObject)];
    getText(url, nil, ^(NSString *text, NSInteger status) {
        NSDictionary *j = text ? [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSString *extract = [j isKindOfClass:NSDictionary.class] && [j[@"extract"] isKindOfClass:NSString.class] ? j[@"extract"] : nil;
        NSString *type = [j isKindOfClass:NSDictionary.class] && [j[@"type"] isKindOfClass:NSString.class] ? j[@"type"] : nil;
        static NSRegularExpression *music;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ music = [NSRegularExpression regularExpressionWithPattern:@"singer|musician|rapper|band|songwriter|producer|\\bDJ\\b|record(ing)? artist|album|song|single|music" options:NSRegularExpressionCaseInsensitive error:nil]; });
        BOOL good = status == 200 && extract.length > 40 && ![type isEqualToString:@"disambiguation"]
                 && [music numberOfMatchesInString:extract options:0 range:NSMakeRange(0, extract.length)] > 0
                 && (!must.length || [extract.lowercaseString containsString:must.lowercaseString]);
        if (good) {
            NSString *page = nil;
            id urls = j[@"content_urls"];
            if ([urls isKindOfClass:NSDictionary.class] && [urls[@"mobile"] isKindOfClass:NSDictionary.class] && [urls[@"mobile"][@"page"] isKindOfClass:NSString.class]) page = urls[@"mobile"][@"page"];
            NSString *title = [j[@"title"] isKindOfClass:NSString.class] ? j[@"title"] : titles.firstObject;
            done(@{@"title": title, @"extract": extract.length > 900 ? [[extract substringToIndex:900] stringByAppendingString:@"…"] : extract,
                   @"url": page ?: [@"https://en.wikipedia.org/wiki/" stringByAppendingString:pathPart(title)]});
            return;
        }
        wikiFirst([titles subarrayWithRange:NSMakeRange(1, titles.count - 1)], must, done);
    });
}

static NSString *artistID(NSString *uri) { return [uri hasPrefix:@"spotify:artist:"] ? [uri substringFromIndex:15] : nil; }

// "12.3M monthly listeners" from the public artist page (its og:description), when Spotify serves it.
static void monthlyListeners(NSString *uri, void (^done)(NSString *count)) {
    NSString *aid = artistID(uri);
    if (!aid) { done(nil); return; }
    getText([@"https://open.spotify.com/artist/" stringByAppendingString:aid],
            @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            ^(NSString *html, NSInteger status) {
        if (!html.length) { done(nil); return; }
        NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([0-9][0-9.,]*\\s?[KMB]?) monthly listeners" options:0 error:nil];
        NSTextCheckingResult *m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
        done(m ? [html substringWithRange:[m rangeAtIndex:1]] : nil);
    });
}

static void addSource(NSMutableArray *sources, NSString *title, NSString *url) {
    if (!url.length) return;
    for (NSDictionary *s in sources) if ([s[@"url"] isEqualToString:url]) return;
    [sources addObject:@{@"title": title ?: url, @"url": url}];
}

void MRGArtistInfo(NSString *name, void (^done)(NSDictionary *info)) {
    NSString *q = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!q.length) { done(@{@"error": @"no artist name"}); return; }
    MRGWebFindArtist(q, ^(NSDictionary *artist, NSString *how) {
        if (!artist) { done(@{@"error": [NSString stringWithFormat:@"Spotify doesn't know an artist called %@", q]}); return; }
        NSMutableDictionary *info = [artist mutableCopy];
        NSMutableArray *sources = [NSMutableArray array];
        NSString *aid = artistID(artist[@"uri"]);
        if (aid) addSource(sources, @"Spotify", [@"https://open.spotify.com/artist/" stringByAppendingString:aid]);
        NSString *full = artist[@"name"] ?: q;
        __block BOOL finished = NO;
        void (^finish)(void) = ^{
            if (finished) return;
            finished = YES;
            info[@"sources"] = [sources copy];
            MRGDJLog(@"info: %@ → followers %@, listeners %@, wiki %@, web %@, %lu sources", full, info[@"followers"] ?: @"?", info[@"monthlyListeners"] ?: @"?",
                     info[@"wiki"] ? @"yes" : @"no", info[@"web"] ? @"yes" : @"no", (unsigned long)sources.count);
            done([info copy]);
        };
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);
        dispatch_group_t g = dispatch_group_create();
        dispatch_group_enter(g);
        MRGWebArtistTracks(artist, 5, ^(NSArray<NSDictionary *> *tracks) { if (tracks.count) info[@"topTracks"] = tracks; dispatch_group_leave(g); });
        if (!info[@"followers"]) {
            dispatch_group_enter(g);
            MRGWebArtist(artist[@"uri"], ^(NSDictionary *a) {
                if (a[@"followers"]) info[@"followers"] = a[@"followers"];
                if (!info[@"genres"] && a[@"genres"]) info[@"genres"] = a[@"genres"];
                dispatch_group_leave(g);
            });
        }
        dispatch_group_enter(g);
        monthlyListeners(artist[@"uri"], ^(NSString *count) { if (count) info[@"monthlyListeners"] = count; dispatch_group_leave(g); });
        dispatch_group_enter(g);
        wikiFirst(@[[full stringByAppendingString:@" (musician)"], [full stringByAppendingString:@" (singer)"], [full stringByAppendingString:@" (rapper)"], [full stringByAppendingString:@" (band)"], full], nil, ^(NSDictionary *wiki) {
            if (wiki) { info[@"wiki"] = wiki; addSource(sources, @"Wikipedia", wiki[@"url"]); }
            dispatch_group_leave(g);
        });
        dispatch_group_enter(g);
        MRGAIGrounded([NSString stringWithFormat:@"Who is the music artist %@ (on Spotify%@)? In 3 short factual sentences: who they are, where they're from, what they're known for, and anything recent. Only facts from search results.", full,
                       [artist[@"genres"] count] ? [NSString stringWithFormat:@"; genres %@", [artist[@"genres"] componentsJoinedByString:@", "]] : @""],
                      ^(NSString *text, NSArray<NSDictionary *> *web, NSString *error) {
            if (text.length && web.count) {
                info[@"web"] = @{@"text": text.length > 700 ? [[text substringToIndex:700] stringByAppendingString:@"…"] : text};
                for (NSDictionary *s in web) addSource(sources, s[@"title"], s[@"url"]);
            } else if (error) MRGDJLog(@"info: web search failed (%@)", error);
            dispatch_group_leave(g);
        });
        dispatch_group_notify(g, dispatch_get_main_queue(), finish);
    });
}

void MRGTrackInfo(NSString *title, NSString *artist, void (^done)(NSDictionary *info)) {
    MRGWebResolve(title ?: @"", artist ?: @"", ^(NSDictionary *track, NSString *error) {
        void (^withTrack)(NSDictionary *) = ^(NSDictionary *t) {
            if (!t) { done(@{@"error": [NSString stringWithFormat:@"Couldn't find \"%@\" on Spotify", title ?: @""]}); return; }
            NSMutableDictionary *info = [t mutableCopy];
            NSMutableArray *sources = [NSMutableArray array];
            NSString *uri = t[@"uri"];
            if ([uri hasPrefix:@"spotify:track:"]) addSource(sources, @"Spotify", [@"https://open.spotify.com/track/" stringByAppendingString:[uri substringFromIndex:14]]);
            NSString *who = t[@"artist"] ?: artist ?: @"";
            NSString *firstWho = [who componentsSeparatedByString:@", "].firstObject ?: who;
            __block BOOL finished = NO;
            void (^finish)(void) = ^{ if (finished) return; finished = YES; info[@"sources"] = [sources copy]; MRGDJLog(@"info: song %@ — %@, wiki %@", t[@"title"], who, info[@"wiki"] ? @"yes" : @"no"); done([info copy]); };
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12 * NSEC_PER_SEC)), dispatch_get_main_queue(), finish);
            dispatch_group_t g = dispatch_group_create();
            dispatch_group_enter(g);
            NSString *tt = t[@"title"] ?: title;
            wikiFirst(@[[NSString stringWithFormat:@"%@ (%@ song)", tt, firstWho], [tt stringByAppendingString:@" (song)"], tt], firstWho, ^(NSDictionary *wiki) {
                if (wiki) { info[@"wiki"] = wiki; addSource(sources, @"Wikipedia", wiki[@"url"]); }
                dispatch_group_leave(g);
            });
            dispatch_group_enter(g);
            MRGAIGrounded([NSString stringWithFormat:@"The song \"%@\" by %@: in 2-3 short factual sentences, when it came out, which album, and what it's about or known for. Only facts from search results.", tt, who],
                          ^(NSString *text, NSArray<NSDictionary *> *web, NSString *e) {
                if (text.length && web.count) { info[@"web"] = @{@"text": text}; for (NSDictionary *s in web) addSource(sources, s[@"title"], s[@"url"]); }
                dispatch_group_leave(g);
            });
            dispatch_group_notify(g, dispatch_get_main_queue(), finish);
        };
        if (track) { withTrack(track); return; }
        MRGWebSearch([NSString stringWithFormat:@"%@ %@", title ?: @"", artist ?: @""], @"track", 1, ^(NSArray<NSDictionary *> *results, NSString *e) { withTrack(results.firstObject); });
    });
}

static NSString *compact(NSNumber *n) {
    double v = n.doubleValue;
    if (v >= 1e6) return [NSString stringWithFormat:@"%.1fM", v / 1e6];
    if (v >= 1e3) return [NSString stringWithFormat:@"%.0fK", v / 1e3];
    return n.stringValue;
}

NSString *MRGInfoFacts(NSDictionary *info) {
    if (info[@"error"]) return [@"Error: " stringByAppendingString:info[@"error"]];
    NSMutableString *f = [NSMutableString string];
    if (info[@"name"]) [f appendFormat:@"Artist (Spotify): %@\n", info[@"name"]];
    if (info[@"title"] && !info[@"name"]) [f appendFormat:@"Song (Spotify): %@ by %@%@%@\n", info[@"title"], info[@"artist"] ?: @"?",
                                           info[@"album"] ? [NSString stringWithFormat:@", album %@", info[@"album"]] : @"",
                                           info[@"released"] ? [NSString stringWithFormat:@", released %@", info[@"released"]] : @""];
    if ([info[@"followers"] isKindOfClass:NSNumber.class]) [f appendFormat:@"Followers: %@\n", compact(info[@"followers"])];
    if (info[@"monthlyListeners"]) [f appendFormat:@"Monthly listeners: %@\n", info[@"monthlyListeners"]];
    if (info[@"popularity"]) [f appendFormat:@"Spotify popularity: %@/100\n", info[@"popularity"]];
    if ([info[@"genres"] count]) [f appendFormat:@"Genres: %@\n", [info[@"genres"] componentsJoinedByString:@", "]];
    if ([info[@"topTracks"] count]) {
        NSMutableArray *t = [NSMutableArray array];
        for (NSDictionary *x in info[@"topTracks"]) if (x[@"title"]) [t addObject:x[@"title"]];
        [f appendFormat:@"Top tracks: %@\n", [t componentsJoinedByString:@", "]];
    }
    if (info[@"wiki"]) [f appendFormat:@"Wikipedia (%@): %@\n", info[@"wiki"][@"title"], info[@"wiki"][@"extract"]];
    if (info[@"web"]) [f appendFormat:@"Google search: %@\n", info[@"web"][@"text"]];
    return f.length > 2000 ? [f substringToIndex:2000] : f;
}

NSDictionary *MRGInfoCard(NSDictionary *info) { return @{@"type": @"info", @"info": info ?: @{}}; }
