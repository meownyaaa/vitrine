#import "MRGSpotifyWeb.h"
#import "MRGPlayer.h"

static NSString *const kAPI = @"https://api.spotify.com/v1";

static void call(NSString *method, NSString *path, id body, void (^done)(id json, NSInteger status, NSString *error)) {
    NSString *auth = MRGSpotifyHeaders()[@"authorization"];
    if (!auth) { done(nil, 0, @"Spotify hasn't signed a request yet. Browse a page in Spotify and try again."); return; }
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
        if (error) message = error.localizedDescription;
        else if (status == 429) message = @"Spotify is rate-limiting for a moment. Try again shortly.";
        else if (status < 200 || status >= 300) message = [NSString stringWithFormat:@"Spotify's Web API answered HTTP %ld.", (long)status];
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

void MRGWebTaste(void (^done)(NSArray *, NSArray *, NSArray *)) {
    NSMutableArray *top = [NSMutableArray array], *artists = [NSMutableArray array], *liked = [NSMutableArray array];
    dispatch_group_t g = dispatch_group_create();
    dispatch_group_enter(g);
    call(@"GET", @"/me/top/tracks?limit=15&time_range=short_term", nil, ^(id j, NSInteger s, NSString *e) {
        for (id t in [j isKindOfClass:NSDictionary.class] ? j[@"items"] : nil) { NSDictionary *n = nameOf(t); if (n) [top addObject:n]; }
        dispatch_group_leave(g);
    });
    dispatch_group_enter(g);
    call(@"GET", @"/me/top/artists?limit=10&time_range=medium_term", nil, ^(id j, NSInteger s, NSString *e) {
        for (id a in [j isKindOfClass:NSDictionary.class] ? j[@"items"] : nil)
            if ([a isKindOfClass:NSDictionary.class] && [a[@"name"] isKindOfClass:NSString.class]) [artists addObject:a[@"name"]];
        dispatch_group_leave(g);
    });
    dispatch_group_enter(g);
    call(@"GET", @"/me/tracks?limit=20", nil, ^(id j, NSInteger s, NSString *e) {
        for (id item in [j isKindOfClass:NSDictionary.class] ? j[@"items"] : nil) {
            NSDictionary *n = [item isKindOfClass:NSDictionary.class] ? nameOf(item[@"track"]) : nil;
            if (n) [liked addObject:n];
        }
        dispatch_group_leave(g);
    });
    dispatch_group_enter(g);
    call(@"GET", @"/me/player/recently-played?limit=20", nil, ^(id j, NSInteger s, NSString *e) {
        for (id item in [j isKindOfClass:NSDictionary.class] ? j[@"items"] : nil) {
            NSDictionary *n = [item isKindOfClass:NSDictionary.class] ? nameOf(item[@"track"]) : nil;
            if (n && ![top containsObject:n]) [top addObject:n];
        }
        dispatch_group_leave(g);
    });
    dispatch_group_notify(g, dispatch_get_main_queue(), ^{ done(top, artists, liked); });
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

static NSString *bestMatch(id json, NSString *title, NSString *artist) {
    NSArray *items = [json isKindOfClass:NSDictionary.class] ? [json[@"tracks"] valueForKey:@"items"] : nil;
    if (![items isKindOfClass:NSArray.class]) return nil;
    NSString *t = norm(title), *a = norm(artist);
    NSString *fallback = nil;
    for (NSDictionary *track in items) {
        if (![track isKindOfClass:NSDictionary.class] || ![track[@"uri"] isKindOfClass:NSString.class]) continue;
        if (!fallback) fallback = track[@"uri"];
        BOOL titleOK = [norm(track[@"name"] ?: @"") isEqualToString:t] || [norm(track[@"name"] ?: @"") hasPrefix:t];
        BOOL artistOK = !a.length;
        for (NSDictionary *ar in [track[@"artists"] isKindOfClass:NSArray.class] ? track[@"artists"] : nil) {
            NSString *n = norm([ar isKindOfClass:NSDictionary.class] ? ar[@"name"] ?: @"" : @"");
            if (n.length && ([n isEqualToString:a] || [n containsString:a] || [a containsString:n])) { artistOK = YES; break; }
        }
        if (titleOK && artistOK) return track[@"uri"];
    }
    return fallback;
}

void MRGWebResolve(NSString *title, NSString *artist, void (^done)(NSString *, NSString *)) {
    NSString *strict = [NSString stringWithFormat:@"track:\"%@\" artist:\"%@\"", title, artist];
    NSString *path = [NSString stringWithFormat:@"/search?type=track&limit=5&q=%@", enc(strict)];
    call(@"GET", path, nil, ^(id j, NSInteger s, NSString *e) {
        NSString *uri = e ? nil : bestMatch(j, title, artist);
        if (uri) { done(uri, nil); return; }
        if (e && s != 0 && s != 400 && s != 404) { done(nil, e); return; }
        NSString *loose = [NSString stringWithFormat:@"/search?type=track&limit=5&q=%@", enc([NSString stringWithFormat:@"%@ %@", title, artist])];
        call(@"GET", loose, nil, ^(id j2, NSInteger s2, NSString *e2) { done(e2 ? nil : bestMatch(j2, title, artist), e2); });
    });
}

void MRGWebFillDJPlaylist(NSArray<NSString *> *uris, void (^done)(NSString *, NSString *)) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    // PUT /playlists/{id}/items replaces the whole list (the February 2026 name; /tracks before it, tried second).
    void (^fill)(NSString *) = ^(NSString *playlistID) {
        NSString *uri = [@"spotify:playlist:" stringByAppendingString:playlistID];
        call(@"PUT", [NSString stringWithFormat:@"/playlists/%@/items", playlistID], @{@"uris": uris}, ^(id j, NSInteger s, NSString *e) {
            if (!e) { done(uri, nil); return; }
            call(@"PUT", [NSString stringWithFormat:@"/playlists/%@/tracks", playlistID], @{@"uris": uris}, ^(id j2, NSInteger s2, NSString *e2) {
                if (e2 && (s2 == 404 || s2 == 403)) [d removeObjectForKey:@"mirage.dj.playlist"];   // deleted: made again next time
                done(e2 ? nil : uri, e2);
            });
        });
    };
    NSString *known = [d stringForKey:@"mirage.dj.playlist"];
    if (known) { fill(known); return; }
    call(@"POST", @"/me/playlists", @{@"name": @"Mirage DJ", @"public": @NO, @"description": @"Picked by Mirage DJ. Refilled every set."},
         ^(id j, NSInteger s, NSString *e) {
        NSString *pid = [j isKindOfClass:NSDictionary.class] ? j[@"id"] : nil;
        if (![pid isKindOfClass:NSString.class]) { done(nil, e ?: @"Couldn't make the Mirage DJ playlist."); return; }
        [d setObject:pid forKey:@"mirage.dj.playlist"];
        fill(pid);
    });
}
