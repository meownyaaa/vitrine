#import "LockClipView.h"
#import <AVFoundation/AVFoundation.h>
#import <stdatomic.h>

static const NSTimeInterval kFade = 0.35;
// One cover or clip giving way to the next: the new one fades in over the old, which fades out under it.
static const NSTimeInterval kSwap = 0.45;

// A layer's opacity eased to `to` from wherever it is on screen.
static void fade(CALayer *layer, float to) {
    if (!layer) return;
    float from = ((CALayer *)layer.presentationLayer ?: layer).opacity;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    layer.opacity = to;
    [CATransaction commit];
    if (from == to) return;
    CABasicAnimation *ease = [CABasicAnimation animationWithKeyPath:@"opacity"];
    ease.fromValue = @(from);
    ease.toValue = @(to);
    ease.duration = kSwap;
    ease.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [layer addAnimation:ease forKey:@"fade"];
}
// How much of the clip's height, at its top and its bottom, fades into the bands.
static const CGFloat kEdgeFade = 0.12;

// The average colour of `image`'s top and bottom rows.
static void edgeColors(CGImageRef image, UIColor **top, UIColor **bottom) {
    *top = *bottom = UIColor.blackColor;
    if (!image) return;
    enum { width = 16, height = 20 };
    uint8_t pixels[width * height * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context);
    for (int edge = 0; edge < 2; edge++) {
        int row = edge == 0 ? 0 : height - 1;
        double r = 0, g = 0, b = 0;
        for (int x = 0; x < width; x++) {
            const uint8_t *p = pixels + (row * width + x) * 4;
            r += p[0]; g += p[1]; b += p[2];
        }
        UIColor *color = [UIColor colorWithRed:r / width / 255 green:g / width / 255 blue:b / width / 255 alpha:1];
        if (edge == 0) *top = color; else *bottom = color;
    }
}

// One clip's reading, made for each load: the asset, its track, the reader and its output and how far its loops have
// run. Only the feed queue reads and writes these, and the feed's blocks hold the run they were made for, so a new
// clip taking its place on the main thread cannot let go of what the feed is still reading; the old run is cancelled,
// its reader cancelled on the feed queue, and goes once the feed's last block does.
@interface SGVClipRun : NSObject
@property (nonatomic, readonly) AVURLAsset *asset;
@property (nonatomic, readonly) AVAssetTrack *track;
- (instancetype)initWithAsset:(AVURLAsset *)asset track:(AVAssetTrack *)track feed:(dispatch_queue_t)feed;
- (void)cancel;
@property (nonatomic, readonly) BOOL cancelled;
- (void)feed:(AVSampleBufferDisplayLayer *)video;
@end

@implementation SGVClipRun {
    dispatch_queue_t _feed;
    AVAssetReader *_reader;
    AVAssetReaderTrackOutput *_output;
    CMTime _offset;
    // Samples the reader gave since it last started: a pass that gives none is not started again.
    NSUInteger _passSamples;
    atomic_bool _cancelled;
}

- (instancetype)initWithAsset:(AVURLAsset *)asset track:(AVAssetTrack *)track feed:(dispatch_queue_t)feed {
    if (!(self = [super init])) return nil;
    _feed = feed;
    _asset = asset;
    _track = track;
    _offset = kCMTimeZero;
    return self;
}

// Main thread: the feed stops at its next sample, and the reader is cancelled on the feed queue, where it is read; the
// layer has stopped asking by then, so the feed's own check may never run again.
- (void)cancel {
    atomic_store(&_cancelled, true);
    dispatch_async(_feed, ^{ [self->_reader cancelReading]; });
}

- (BOOL)cancelled {
    return atomic_load(&_cancelled);
}

// Feed queue.
- (BOOL)startReader {
    NSError *error = nil;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:_asset error:&error];
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:_track outputSettings:nil];
    if (!reader || ![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    _reader = reader;
    _output = output;
    _passSamples = 0;
    return YES;
}

// Feed queue: as many samples as the layer takes, the clip read again from its start each time it ends, its times moved
// on by a loop's length so the layer's clock runs straight through.
- (void)feed:(AVSampleBufferDisplayLayer *)video {
    if (!_reader && ![self startReader]) {
        [video stopRequestingMediaData];
        return;
    }
    while (video.isReadyForMoreMediaData) {
        if (self.cancelled) {
            [video stopRequestingMediaData];
            [_reader cancelReading];
            return;
        }
        CMSampleBufferRef sample = [_output copyNextSampleBuffer];
        if (!sample) {
            // A pass that read to its end with no sample (an empty or unreadable track) would start again for ever.
            if (_reader.status != AVAssetReaderStatusCompleted || _passSamples == 0) {
                [video stopRequestingMediaData];
                return;
            }
            _offset = CMTimeAdd(_offset, _asset.duration);
            if (![self startReader]) {
                [video stopRequestingMediaData];
                return;
            }
            continue;
        }
        _passSamples++;
        CMItemCount count = 0;
        CMSampleBufferGetSampleTimingInfoArray(sample, 0, NULL, &count);
        CMSampleTimingInfo stack[8];
        CMSampleTimingInfo *timing = count <= 8 ? stack : malloc(sizeof(CMSampleTimingInfo) * count);
        CMSampleBufferGetSampleTimingInfoArray(sample, count, timing, &count);
        for (CMItemCount i = 0; i < count; i++) {
            if (CMTIME_IS_VALID(timing[i].presentationTimeStamp)) timing[i].presentationTimeStamp = CMTimeAdd(timing[i].presentationTimeStamp, _offset);
            if (CMTIME_IS_VALID(timing[i].decodeTimeStamp)) timing[i].decodeTimeStamp = CMTimeAdd(timing[i].decodeTimeStamp, _offset);
        }
        CMSampleBufferRef moved = NULL;
        CMSampleBufferCreateCopyWithNewTiming(kCFAllocatorDefault, sample, count, timing, &moved);
        if (timing != stack) free(timing);
        CFRelease(sample);
        if (!moved) continue;
        [video enqueueSampleBuffer:moved];
        CFRelease(moved);
    }
}

@end

@implementation SGVLockClip {
    CAGradientLayer *_bands;
    AVSampleBufferDisplayLayer *_video;
    AVSampleBufferDisplayLayer *_leaving;   // the last clip's, held on its frame under the next until that one's is in
    CAGradientLayer *_mask;
    CALayer *_still;
    CAGradientLayer *_stillMask;
    UIImage *_cover;
    NSURL *_wanted;   // the clip asked for, kept while suspended
    BOOL _suspended;
    dispatch_queue_t _feed;
    SGVClipRun *_current;   // the clip being read, nil for none
    CGSize _natural;
    NSURL *_playing;
    NSUInteger _run;
    BOOL _startsPlaying;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    _bands = [CAGradientLayer layer];
    _bands.colors = @[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor];
    [self.layer addSublayer:_bands];
    _feed = dispatch_queue_create("com.vitrine.addon.lockclip", DISPATCH_QUEUE_SERIAL);
    _startsPlaying = YES;
    _still = [CALayer layer];
    _still.contentsGravity = kCAGravityResizeAspectFill;
    _stillMask = [self edgeMask];
    _still.mask = _stillMask;
    [self.layer addSublayer:_still];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(failed:) name:AVSampleBufferDisplayLayerFailedToDecodeNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(failed:) name:AVSampleBufferDisplayLayerRequiresFlushToResumeDecodingDidChangeNotification object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

// Its own top and bottom fade into the bands, so no edge of it shows.
- (CAGradientLayer *)edgeMask {
    CAGradientLayer *mask = [CAGradientLayer layer];
    mask.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    mask.locations = @[@0, @(kEdgeFade), @(1 - kEdgeFade), @1];
    return mask;
}

- (BOOL)hasContent {
    return _wanted != nil || _cover != nil;
}

- (CGRect)drawnFrame {
    if (_video && _wanted && !_suspended) return [self fitted];
    CGFloat width = self.bounds.size.width;
    return CGRectMake(0, CGRectGetMidY(self.bounds) - width / 2, width, width);
}

// The display layer could not go on: the clip again on a new one, unless the screen is dark, where it is built as it lights.
- (void)failed:(NSNotification *)note {
    dispatch_async(dispatch_get_main_queue(), ^{
        AVSampleBufferDisplayLayer *video = self->_video;
        if (note.object != video || self->_suspended) return;
        if (video.status != AVQueuedSampleBufferRenderingStatusFailed && !video.requiresFlushToResumeDecoding) return;
        NSLog(@"[vitrine-addon] the clip's display layer failed, starting it over");
        [self rebuild];
    });
}

- (void)rebuild {
    NSURL *clip = _wanted;
    [self load:nil];
    [self load:clip];
}

// Out of a window, nothing is read or decoded; back in one, the clip asked for plays again unless the screen is dark.
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self load:nil];
    else if (!_suspended) [self load:_wanted];
}

- (void)setSuspended:(BOOL)suspended {
    if (_suspended == suspended) return;
    _suspended = suspended;
    if (suspended) [self load:nil];
    else [self load:_wanted];
}

- (void)showCover:(UIImage *)cover {
    if (cover == _cover) return;
    BOOL had = _still.contents != nil;
    _cover = cover;
    // One cover crossfades to the next rather than cutting to it.
    if (had && cover) {
        CATransition *crossfade = [CATransition animation];
        crossfade.type = kCATransitionFade;
        crossfade.duration = kSwap;
        crossfade.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_still addAnimation:crossfade forKey:@"contents"];
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _still.contents = (id)cover.CGImage;
    [CATransaction commit];
    [self setNeedsLayout];
    if (!_wanted) [self paintBands:cover.CGImage];
}

// Where the clip is drawn: its whole width the screen's, in the middle of the height.
- (CGRect)fitted {
    CGRect bounds = self.bounds;
    if (_natural.width < 1 || _natural.height < 1) return bounds;
    CGFloat height = bounds.size.width * _natural.height / _natural.width;
    return CGRectMake(0, CGRectGetMidY(bounds) - height / 2, bounds.size.width, height);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bands.frame = self.bounds;
    _video.frame = [self fitted];
    _mask.frame = _video.bounds;
    CGFloat width = self.bounds.size.width;
    _still.frame = CGRectMake(0, CGRectGetMidY(self.bounds) - width / 2, width, width);
    _stillMask.frame = _still.bounds;
    [CATransaction commit];
}

- (void)paintBands:(CGImageRef)image {
    if (!image) return;
    UIColor *top, *bottom;
    edgeColors(image, &top, &bottom);
    CABasicAnimation *ease = [CABasicAnimation animationWithKeyPath:@"colors"];
    ease.fromValue = (_bands.presentationLayer ?: _bands).colors;
    ease.duration = kFade;
    [_bands addAnimation:ease forKey:@"colors"];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _bands.colors = @[(id)top.CGColor, (id)bottom.CGColor];
    [CATransaction commit];
}

- (void)playClip:(NSURL *)clip {
    if ((clip == nil && _wanted == nil) || [clip isEqual:_wanted]) return;
    _wanted = clip;
    if (!clip) {
        [self paintBands:_cover.CGImage];
        fade(_still, 1);
    }
    if (!_suspended) [self load:clip];
}

- (void)load:(NSURL *)clip {
    // Out of a window nothing is read or decoded, whoever asks: didMoveToWindow loads the clip asked for as it comes back.
    if (!self.window) clip = nil;
    if ((clip == nil && _playing == nil) || [clip isEqual:_playing]) return;
    _playing = clip;
    _run++;
    [_video stopRequestingMediaData];
    [_leaving removeFromSuperlayer];
    _leaving = nil;
    // One clip after another: the last one's frame stays until the next one's first is in, rather than the bands alone,
    // and then fades out under it; a clip giving way to the cover fades out over it.
    if (_video && !_suspended) {
        _leaving = _video;
        if (!clip) [self dropLeaving];
    } else {
        [_video flush];
        [_video removeFromSuperlayer];
    }
    [_current cancel];
    _current = nil;
    _video = nil;
    if (!clip) return;
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:clip options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
#pragma clang diagnostic pop
    if (!track) {
        [self dropLeaving];
        return;
    }
    SGVClipRun *current = _current = [[SGVClipRun alloc] initWithAsset:asset track:track feed:_feed];
    CGSize size = CGSizeApplyAffineTransform(track.naturalSize, track.preferredTransform);
    _natural = CGSizeMake(fabs(size.width), fabs(size.height));
    _video = [AVSampleBufferDisplayLayer layer];
    _video.videoGravity = AVLayerVideoGravityResizeAspect;
    _mask = [self edgeMask];
    _video.mask = _mask;
    CMTimebaseRef timebase = NULL;
    CMTimebaseCreateWithSourceClock(kCFAllocatorDefault, CMClockGetHostTimeClock(), &timebase);
    CMTimebaseSetTime(timebase, kCMTimeZero);
    CMTimebaseSetRate(timebase, _startsPlaying ? 1 : 0);
    _video.controlTimebase = timebase;
    if (timebase) CFRelease(timebase);
    // In once its first frame is: until then, what was there shows.
    _video.opacity = 0;
    [self.layer addSublayer:_video];
    [self setNeedsLayout];

    AVAssetImageGenerator *frames = [AVAssetImageGenerator assetImageGeneratorWithAsset:asset];
    frames.appliesPreferredTrackTransform = YES;
    frames.maximumSize = CGSizeMake(64, 64);
    __weak SGVLockClip *weakSelf = self;
    NSUInteger asked = _run;
    [frames generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:kCMTimeZero]]
                                 completionHandler:^(CMTime requested, CGImageRef image, CMTime actual, AVAssetImageGeneratorResult result, NSError *error) {
        BOOL succeeded = result == AVAssetImageGeneratorSucceeded && image;
        if (succeeded) CGImageRetain(image);
        dispatch_async(dispatch_get_main_queue(), ^{
            SGVLockClip *view = weakSelf;
            if (view && view->_run == asked) {
                // The clip is in: it fades in, and the still under it goes, so a clip of another shape shows no cover at its
                // edges. One that does not read stays out, the cover or the last clip showing.
                if (succeeded) {
                    [view paintBands:image];
                    fade(view->_video, 1);
                    fade(view->_still, 0);
                }
                [view dropLeaving];
            }
            if (succeeded) CGImageRelease(image);
        });
    }];

    // The feed's blocks hold the run and the layer, not the view.
    AVSampleBufferDisplayLayer *video = _video;
    dispatch_queue_t feed = _feed;
    dispatch_async(feed, ^{
        if (current.cancelled) return;
        [video requestMediaDataWhenReadyOnQueue:feed usingBlock:^{ [current feed:video]; }];
    });
}

// The last clip's layer faded out once the next one's first frame is read, or as the cover takes its place, and then
// taken away.
- (void)dropLeaving {
    AVSampleBufferDisplayLayer *leaving = _leaving;
    if (!leaving) return;
    fade(leaving, 0);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSwap * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_leaving != leaving) return;
        [leaving flush];
        [leaving removeFromSuperlayer];
        self->_leaving = nil;
    });
}

- (void)setPlaying:(BOOL)playing {
    _startsPlaying = playing;
    if (_video.controlTimebase) CMTimebaseSetRate(_video.controlTimebase, playing ? 1 : 0);
}

@end

