#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Headers/SPTPlayer.h"
#import "AlbumQueue.h"

@interface SPTPlayerTrack (SGAlbumQueue)
- (instancetype)initWithURI:(NSURL *)uri albumURI:(NSURL *)album artistURI:(NSURL *)artist andUID:(NSString *)uid;
@end
@interface SPTask : NSObject
- (id)addCallback:(void (^)(id))callback on:(dispatch_queue_t)queue;
- (id)addErrorCallback:(void (^)(NSError *))callback on:(dispatch_queue_t)queue;
@end
@interface SPTPlayerQueueWrapperImpl : NSObject
- (instancetype)initWithPlayer:(id)player;
- (SPTask *)queueMultipleTracks:(NSArray *)tracks loggingParams:(id)params;
@end

// One request at a time, so repeated taps cannot append the same album while its metadata is loading.
@interface SGAlbumQueueRequest : NSObject
@property (nonatomic, copy) void (^done)(NSUInteger, NSString *);
@property (nonatomic, strong) id player;
@property (nonatomic, strong) SPTPlayerQueueWrapperImpl *wrapper;
@property (nonatomic, strong) SPTask *task;
@property (nonatomic) BOOL finished, submitted;
- (void)finish:(NSUInteger)count error:(NSString *)error;
@end
static SGAlbumQueueRequest *sg_request;
@implementation SGAlbumQueueRequest
- (void)finish:(NSUInteger)count error:(NSString *)error {
    if (self.finished) return;
    self.finished = YES;
    void (^done)(NSUInteger, NSString *) = self.done;
    self.done = nil;
    self.task = nil;
    self.wrapper = nil;
    sg_request = nil;
    done(count, error);
}
@end

void SGAlbumQueueAdd(NSString *uri, void (^done)(NSUInteger, NSString *)) {
    NSCAssert(NSThread.isMainThread, @"album queue runs on main");
    if (!SGAlbumQueueIsAlbumURI(uri)) { done(0, @"This is not a Spotify album."); return; }
    if (sg_request) { done(0, @"An album is already being added to the queue."); return; }
    id player = SGPlayer();
    Class wrapper = NSClassFromString(@"SPTPlayerQueueWrapperImpl"), track = NSClassFromString(@"SPTPlayerTrack");
    if (!player || ![wrapper instancesRespondToSelector:@selector(initWithPlayer:)] ||
        ![wrapper instancesRespondToSelector:@selector(queueMultipleTracks:loggingParams:)] ||
        ![track instancesRespondToSelector:@selector(initWithURI:albumURI:artistURI:andUID:)]) {
        done(0, @"Spotify's queue is not ready."); return;
    }
    SGAlbumQueueRequest *request = [SGAlbumQueueRequest new];
    request.player = player;
    request.done = done;
    sg_request = request;
    // SGSpclientHeaders can wait for Spotify's next request. A late header or metadata answer must
    // never queue an album after the user has already been told that loading failed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!request.submitted) [request finish:0 error:@"Spotify took too long to load the album. Try again."];
    });
    __weak SGAlbumQueueRequest *weakRequest = request;
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        SGAlbumQueueRequest *request = weakRequest;
        if (!request || request.finished) return;
        NSString *address = [@"https://spclient.wg.spotify.com/context-resolve/v1/" stringByAppendingString:uri];
        NSMutableURLRequest *http = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
        http.timeoutInterval = 15;
        http.allHTTPHeaderFields = headers;
        [http setValue:@"application/json" forHTTPHeaderField:@"Accept"];
        [[NSURLSession.sharedSession dataTaskWithRequest:http completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            id context = status == 200 && data.length > 0 && data.length <= 2 * 1024 * 1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *reason;
            NSArray *uris = SGAlbumQueueTrackURIs(context, uri, &reason);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (request.finished) return;
                if (!uris) { 
                    if (error || status != 200) SGLog(@"album queue: context-resolve status %ld, %@", (long)status, error);
                    [request finish:0 error:error || status != 200 ? @"Spotify could not load the album. Try again." : reason];
                    return;
                }
                NSMutableArray *tracks = [NSMutableArray arrayWithCapacity:uris.count];
                for (NSString *trackURI in uris) {
                    SPTPlayerTrack *item = [[track alloc] initWithURI:[NSURL URLWithString:trackURI] albumURI:[NSURL URLWithString:uri] artistURI:nil andUID:nil];
                    if (!item) { [request finish:0 error:@"Spotify could not prepare the album."]; return; }
                    [tracks addObject:item];
                }
                request.wrapper = [[wrapper alloc] initWithPlayer:request.player];
                SPTask *task = [request.wrapper queueMultipleTracks:tracks loggingParams:nil];
                if (![task respondsToSelector:@selector(addCallback:on:)] || ![task respondsToSelector:@selector(addErrorCallback:on:)]) {
                    [request finish:0 error:@"Spotify did not return a queue result."]; return;
                }
                request.submitted = YES;
                request.task = task;
                // A task that never answers would otherwise hold sg_request and refuse every later album.
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [request finish:0 error:@"Spotify did not confirm the album was queued. Check the queue before trying again."];
                });
                [task addCallback:^(id value) {
                    SGLog(@"album queue: %lu tracks added", (unsigned long)uris.count);
                    [request finish:uris.count error:nil];
                } on:dispatch_get_main_queue()];
                [task addErrorCallback:^(NSError *failure) {
                    [request finish:0 error:@"Spotify could not add the album to the queue."];
                } on:dispatch_get_main_queue()];
            });
        }] resume];
    });
}
