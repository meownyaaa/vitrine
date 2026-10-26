// Anchors the playing track's lossless file again whenever the anchor stops holding: a new track, a seek, a resume.
// Only at normal speed with Karaoke off; anything else leaves Spotify's own sound.
#import "Core/SGCore.h"
#import <objc/runtime.h>
#import "Shared/Player/PlayerState.h"
#import "Shared/Sing/Sing.h"
#import "Shared/Player/SpeedPitch.h"
#import "SGLossless.h"
#import "SGLosslessStore.h"
#import "LosslessQuality.h"

static const int kTries = 3;            // failed anchors in a row before waiting for the next change of source
static const double kRetrySeconds = 2;
// The store's lookups read the folder and open untagged files, so they run here, one at a time.
static dispatch_queue_t sg_storeQueue;

@interface SGLosslessCoordinator : NSObject <SGPlayerStateObserver>
@end

@implementation SGLosslessCoordinator {
    NSString *_track, *_path;
    BOOL _busy, _looked, _looking, _nextHas, _nextLooking;
    NSString *_next;
    NSTimer *_ticker;
    NSDate *_folderChanged;
    int _failures;
    uint64_t _gaveUpEpoch;
    double _retryAt;
}

// Position reports are not change callbacks, and a seek or resume shows only in the source's epoch: while
// Spotify plays, a tick each second catches those, and a file that arrives while the song before plays.
- (void)playerStateDidChange:(SPTPlayerState *)state {
    BOOL playing = state.isPlaying && !state.isPaused;
    if (playing && !_ticker) {
        _ticker = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) { [self tick]; }];
    } else if (!playing) {
        [_ticker invalidate];
        _ticker = nil;
    }
    [self tick];
}

- (void)tick {
    SPTPlayerState *state = SGPlayerState();
    NSString *track = SGURIString(state.track.URI);
    if (![track isEqualToString:_track]) {
        if (_path) SGLosslessStop(YES);
        _track = track;
        _path = nil;
        _looked = NO;
        _failures = 0;
        _gaveUpEpoch = 0;
    }
    // A track's first report can come before its title and length: look again until both are known.
    if (track && !_looked && !_looking) {
        _looking = YES;
        NSString *title = state.track.trackTitle ?: @"";
        double duration = state.duration;
        dispatch_async(sg_storeQueue, ^{
            NSString *path = SGLosslessStoreFile(track, title, duration);
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_looking = NO;
                if ([track isEqualToString:self->_track]) {
                    self->_path = path;
                    self->_looked = path || (title.length && duration > 0);
                    // Not looked yet: the next tick looks again, not this one.
                    if (!self->_looked) return;
                    SGLog(@"lossless: %@ (%.1f s): %@", track, duration, path.lastPathComponent ?: @"no file");
                }
                [self tick];
            });
        });
    }
    // Spotify fetches a song as it starts, so its quality is set while the one before plays.
    id future = [state respondsToSelector:@selector(future)] ? state.future : nil;
    id upcoming = [future isKindOfClass:NSArray.class] ? [(NSArray *)future firstObject] : nil;
    SPTPlayerTrack *next = [upcoming isKindOfClass:objc_getClass("SPTPlayerTrack")] ? upcoming : nil;
    NSString *nextURI = SGURIString(next.URI);
    // Again when the folder changes: a file can arrive while the song before plays.
    NSDate *changed = [NSFileManager.defaultManager attributesOfItemAtPath:SGLosslessStoreDirectory() error:NULL].fileModificationDate;
    if (!_nextLooking && (![nextURI isEqualToString:_next] || ![changed isEqualToDate:_folderChanged])) {
        _next = nextURI;
        _folderChanged = changed;
        _nextHas = NO;
        if (nextURI) {
            // Spotify's quality stays as it is until the answer is in; a tick then sets it.
            _nextLooking = YES;
            NSString *title = next.trackTitle ?: @"";
            dispatch_async(sg_storeQueue, ^{
                BOOL has = SGLosslessStoreHas(nextURI, title);
                dispatch_async(dispatch_get_main_queue(), ^{
                    self->_nextLooking = NO;
                    self->_nextHas = has;
                    [self tick];
                });
            });
        }
    }
    if (!_nextLooking) SGLosslessLowerQuality(_nextHas);

    if (!_path || _busy || SGLosslessPlaying()) return;
    if (!state.isPlaying || state.isPaused || fabs(state.playbackSpeed - 1) > 0.001 || SGSingOn()) return;
    uint64_t epoch = SGPlayerSourceEpoch();
    if (_gaveUpEpoch && _gaveUpEpoch == epoch) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (now < _retryAt) return;

    _busy = YES;
    NSString *path = _path;
    double hint = state.position;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *error;
        NSDictionary *anchored = SGLosslessAnchor(path, hint, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_busy = NO;
            if (![track isEqualToString:self->_track]) return;
            if (anchored) {
                self->_failures = 0;
                SGLosslessStoreRemember(track, path);
                SGLog(@"lossless: playing %@ from %.2f s", path.lastPathComponent, [anchored[@"file_seconds"] doubleValue]);
                return;
            }
            self->_retryAt = CFAbsoluteTimeGetCurrent() + kRetrySeconds;
            if (++self->_failures >= kTries) {
                self->_failures = 0;
                self->_gaveUpEpoch = SGPlayerSourceEpoch();
                SGLog(@"lossless: gave up on %@ until the source changes: %@", path.lastPathComponent, error);
            } else {
                SGLog(@"lossless: no anchor (%@)", error);
            }
        });
    });
}
@end

%ctor {
    if (!SGHidden(SGKeyLossless)) return;
    sg_storeQueue = dispatch_queue_create("spotifyglass.lossless.store", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    dispatch_async(dispatch_get_main_queue(), ^{
        static SGLosslessCoordinator *coordinator;
        coordinator = [SGLosslessCoordinator new];
        SGAddPlayerStateObserver(coordinator);
    });
}
