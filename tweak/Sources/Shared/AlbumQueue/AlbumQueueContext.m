#import "AlbumQueue.h"

static BOOL validURI(NSString *uri, NSString *prefix) {
    if (![uri isKindOfClass:NSString.class] || ![uri hasPrefix:prefix] || uri.length != prefix.length + 22) return NO;
    for (NSUInteger i = prefix.length; i < uri.length; i++) {
        unichar c = [uri characterAtIndex:i];
        if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'))) return NO;
    }
    return YES;
}

NSArray<NSString *> *SGAlbumQueueTrackURIs(id context, NSString *uri, NSString **error) {
    if (error) *error = @"Spotify did not return a complete album.";
    if (!validURI(uri, @"spotify:album:") || ![context isKindOfClass:NSDictionary.class] || ![context[@"uri"] isEqual:uri]) return nil;
    id pages = context[@"pages"];
    if (![pages isKindOfClass:NSArray.class] || ![pages count]) return nil;
    NSMutableArray *tracks = [NSMutableArray array];
    for (id page in pages) {
        if (![page isKindOfClass:NSDictionary.class]) return nil;
        // Do not queue just the first page of a large release. No queue command runs for a partial answer.
        id next = page[@"next_page_url"];
        if (next && next != NSNull.null && ![next isEqual:@""]) return nil;
        id entries = page[@"tracks"];
        if (![entries isKindOfClass:NSArray.class]) return nil;
        for (id entry in entries) {
            if (![entry isKindOfClass:NSDictionary.class] || !validURI(entry[@"uri"], @"spotify:track:")) return nil;
            [tracks addObject:entry[@"uri"]];
            if (tracks.count > 5000) return nil;
        }
    }
    if (!tracks.count) return nil;
    if (error) *error = nil;
    return tracks;
}

BOOL SGAlbumQueueIsAlbumURI(NSString *uri) { return validURI(uri, @"spotify:album:"); }
