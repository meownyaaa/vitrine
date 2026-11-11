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
    NSString *artist = [artists isKindOfClass:NSArray.class] && artists.count ? [artists.firstObject valueForKey:@"name"] : @"";
    return @{@"title": track[@"name"], @"artist": [artist isKindOfClass:NSString.class] ? artist : @""};
}

static NSString *norm(NSString *s) {
    NSString *l = [[s lowercaseString] stringByFoldingWithOptions:NSDiacriticInsensitiveSearch locale:nil];
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

static NSDictionary *resolved(NSDictionary *track) {
    if (!track) return nil;
    NSMutableDictionary *d = [@{@"uri": track[@"uri"]} mutableCopy];
    NSDictionary *names = nameOf(track);
    if (names) [d addEntriesFromDictionary:names];   // Spotify's own title and artist, not the model's spelling
    NSString *cover = coverOf(track);
    if (cover) d[@"image"] = cover;
    return d;
}

// A search hit only counts when both the title and an artist match (normalized; a title may carry a suffix such as
// "- Remastered"). The first hit is never taken on its own: a song the model made up finds nothing and is dropped.
static NSDictionary *bestMatch(id json, NSString *title, NSString *artist) {
    NSArray *items = [json isKindOfClass:NSDictionary.class] ? [json[@"tracks"] valueForKey:@"items"] : nil;
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSString *t = norm(title), *a = norm(artist);
    if (!t.length) return nil;
    for (NSDictionary *track in items) {
        if (![track isKindOfClass:NSDictionary.class] || ![track[@"uri"] isKindOfClass:NSString.class]) continue;
        if (![track[@"uri"] hasPrefix:@"spotify:track:"]) continue;
        NSString *name = norm([track[@"name"] isKindOfClass:NSString.class] ? track[@"name"] : @"");
        BOOL titleOK = name.length && ([name isEqualToString:t] || ([name hasPrefix:t] && t.length >= 4) || ([t hasPrefix:name] && name.length >= 4));
        if (!titleOK) continue;
        BOOL artistOK = NO;
        for (NSDictionary *ar in [track[@"artists"] isKindOfClass:NSArray.class] ? track[@"artists"] : nil) {
            NSString *n = norm([ar isKindOfClass:NSDictionary.class] ? ar[@"name"] ?: @"" : @"");
            if (n.length && a.length && ([n isEqualToString:a] || (n.length >= 3 && [a containsString:n]) || (a.length >= 3 && [n containsString:a]))) { artistOK = YES; break; }
        }
        if (artistOK) return resolved(track);
    }
    return nil;
}

void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSDictionary *, NSString *)) {
    NSString *strict = [NSString stringWithFormat:@"track:\"%@\" artist:\"%@\"", title, artist];
    NSString *path = [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc(strict)];
    call(@"GET", path, nil, ^(id j, NSInteger s, NSString *e) {
        NSDictionary *match = e ? nil : bestMatch(j, title, artist);
        if (match) { MRGDJLog(@"resolve: found via Web API search (strict track:/artist: query)"); done(match, nil); return; }
        if (e && s != 0 && s != 400 && s != 404) { done(nil, e); return; }
        NSString *loose = [NSString stringWithFormat:@"/search?type=track&limit=10&q=%@", enc([NSString stringWithFormat:@"%@ %@", title, artist])];
        call(@"GET", loose, nil, ^(id j2, NSInteger s2, NSString *e2) {
            NSDictionary *m2 = e2 ? nil : bestMatch(j2, title, artist);
            if (m2) MRGDJLog(@"resolve: found via Web API search (loose title + artist query)");
            else if (!e2) MRGDJLog(@"resolve: no real match for a pick on Web API search, dropped");
            else MRGDJLog(@"resolve: Web API search failed (%@)", e2);
            done(m2, e2);
        });
    });
}
