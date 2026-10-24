#import <Foundation/Foundation.h>
#import "Shared/AlbumQueue/AlbumQueue.h"
static int checks;
static void check(BOOL ok, NSString *name) {
    checks++;
    if (!ok) { NSLog(@"FAIL: %@", name); exit(1); }
}
int main(void) { @autoreleasepool {
    NSString *album = @"spotify:album:4eLPsYPBmXABThSJ821sqY";
    NSString *a = @"spotify:track:1n4jwRVXdkK2U34nBDUKKT", *b = @"spotify:track:6HZILIRieu8S0iqY8kIKhj";
    NSDictionary *(^context)(id) = ^NSDictionary *(id pages) { return @{@"uri":album,@"pages":pages}; };
    NSDictionary *(^page)(NSArray *) = ^NSDictionary *(NSArray *tracks) { return @{@"tracks":tracks}; };
    NSDictionary *ta = @{@"uri":a}, *tb = @{@"uri":b};
    NSString *error = @"stale";
    NSArray *result = SGAlbumQueueTrackURIs(context(@[page(@[ta,tb]),page(@[ta])]), album, &error);
    check([result isEqual:@[a,b,a]] && error == nil, @"disc/page order and repeated tracks survive");
    check(SGAlbumQueueIsAlbumURI(album), @"valid album identity");
    check(!SGAlbumQueueIsAlbumURI(a), @"a track is not an album");
    check(!SGAlbumQueueIsAlbumURI(@"spotify:album:../../../../../../../../"), @"invalid album characters");
    NSArray *bad = @[
        NSNull.null, @{}, @{@"uri":a,@"pages":@[page(@[ta])]},
        context(@[]), context(@[NSNull.null]), context(@[@{@"tracks":@"bad"}]),
        context(@[page(@[])]), context(@[page(@[ta,NSNull.null])]),
        context(@[page(@[ta,@{@"uri":album}])]),
        context(@[page(@[ta,@{@"uri":@"spotify:track:../bad"}])]),
        context(@[@{@"tracks":@[ta],@"next_page_url":@"hm://more"}]),
        context(@[page(@[ta]),@{@"page_url":@"hm://missing-page"}])
    ];
    for (id value in bad) {
        error = nil;
        check(SGAlbumQueueTrackURIs(value, album, &error) == nil && error.length > 0, @"incomplete or malformed context submits no tracks");
    }
    check(SGAlbumQueueTrackURIs(context(@[page(@[ta])]), @"not-an-album", NULL) == nil, @"invalid request identity rejected");
    NSLog(@"%d album context checks passed", checks);
} return 0; }
