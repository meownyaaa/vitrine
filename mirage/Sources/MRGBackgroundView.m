#import "MRGBackgroundView.h"
#import "MRGPrefs.h"
#import <CoreImage/CoreImage.h>

static CGFloat blurRadius(void) { return MRGBlur() * 40.0; }

#pragma mark - video engine

@implementation MRGVideoEngine {
    AVPlayerLooper *_looper;
    NSHashTable *_visible;
    NSURL *_loadedURL;
    double _loadedBlur;
    BOOL _active;
    AVPlayerItemVideoOutput *_output;
    __weak AVPlayerItem *_outputItem;
    CGAffineTransform _posterTransform;
    UIImage *_poster;
}

+ (instancetype)shared {
    static MRGVideoEngine *engine;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ engine = [MRGVideoEngine new]; });
    return engine;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _player = [AVQueuePlayer new];
    // Never audible, never routed anywhere, never keeps the screen on: Spotify owns the audio session
    // and the AirPlay route, and this player must not touch either. It never sets an AVAudioSession
    // category, so it cannot interrupt or duck Spotify's playback.
    _player.muted = YES;
    _player.volume = 0;
    _player.allowsExternalPlayback = NO;
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
    if (@available(iOS 15.0, *)) _player.audiovisualBackgroundPlaybackPolicy = AVPlayerAudiovisualBackgroundPlaybackPolicyPauses;
    _visible = [NSHashTable weakObjectsHashTable];
    _posterTransform = CGAffineTransformIdentity;
    _output = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:@{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)}];
    // The looper swaps the queue's item every loop: the output follows the current one.
    [_player addObserver:self forKeyPath:@"currentItem" options:NSKeyValueObservingOptionNew context:NULL];
    _active = UIApplication.sharedApplication.applicationState != UIApplicationStateBackground;
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    // queue:nil and a hop to main (Vitrine's AGENTS.md: never block a posting thread on main).
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ self->_active = NO; [self update]; });
    }];
    [nc addObserverForName:UIApplicationWillEnterForegroundNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        dispatch_async(dispatch_get_main_queue(), ^{ self->_active = YES; [self update]; });
    }];
    return self;
}

// The file's video track alone: whatever audio a picked video had is not even in the item.
static AVPlayerItem *videoOnlyItem(NSURL *url, double blur) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
    if (!track) return nil;
    AVMutableComposition *comp = [AVMutableComposition composition];
    AVMutableCompositionTrack *ct = [comp addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    if (![ct insertTimeRange:CMTimeRangeMake(kCMTimeZero, asset.duration) ofTrack:track atTime:kCMTimeZero error:nil]) return nil;
    ct.preferredTransform = track.preferredTransform;
    AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:comp];
    if (blur > 0.5) {
        CGFloat radius = blur;
        item.videoComposition = [AVVideoComposition videoCompositionWithAsset:comp applyingCIFiltersWithHandler:^(AVAsynchronousCIImageFilteringRequest *req) {
            CIImage *src = req.sourceImage;
            CIImage *out = [[src imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:radius];
            [req finishWithImage:[out imageByCroppingToRect:src.extent] context:nil];
        }];
    }
    item.preferredForwardBufferDuration = 2;
    return item;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    void (^move)(void) = ^{
        AVPlayerItem *item = self->_player.currentItem;
        if (item == self->_outputItem) return;
        AVPlayerItem *old = self->_outputItem;
        if (old && [old.outputs containsObject:self->_output]) {
            // Keep a frame from the outgoing item before the output leaves it.
            [self capturePoster];
            [old removeOutput:self->_output];
        }
        if (item && ![item.outputs containsObject:self->_output]) [item addOutput:self->_output];
        self->_outputItem = item;
    };
    if (NSThread.isMainThread) move(); else dispatch_async(dispatch_get_main_queue(), move);
}

static CIContext *posterContext(void) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    return ctx;
}

- (void)capturePoster {
    AVPlayerItem *item = _outputItem;
    if (!item) return;
    CMTime t = item.currentTime;
    if (!CMTIME_IS_VALID(t)) return;
    CVPixelBufferRef pb = [_output copyPixelBufferForItemTime:t itemTimeForDisplay:NULL];
    if (!pb) return;
    CIImage *ci = [CIImage imageWithCVPixelBuffer:pb];
    CVPixelBufferRelease(pb);
    if (!CGAffineTransformIsIdentity(_posterTransform)) {
        ci = [ci imageByApplyingTransform:_posterTransform];
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(-ci.extent.origin.x, -ci.extent.origin.y)];
    }
    CGImageRef cg = [posterContext() createCGImage:ci fromRect:ci.extent];
    if (!cg) return;
    _poster = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
}

- (UIImage *)posterFrame {
    if (!_loadedURL) return nil;
    [self capturePoster];
    return _poster;
}

- (void)reload {
    NSURL *url = MRGCurrentKind() == MRGMediaVideo ? MRGCurrentMediaURL() : nil;
    double blur = blurRadius();
    if ((url == _loadedURL || [url isEqual:_loadedURL]) && blur == _loadedBlur) { [self update]; return; }
    [_looper disableLooping];
    _looper = nil;
    [_player pause];
    [_player removeAllItems];
    _loadedURL = url;
    _loadedBlur = blur;
    _poster = nil;
    _outputItem = nil;
    _posterTransform = CGAffineTransformIdentity;
    AVPlayerItem *item = url ? videoOnlyItem(url, blur) : nil;
    // Frames out of the output are the track's own; with no video composition the player layer applies the
    // track's preferred transform at display, so the poster gets it too (the blur's composition renders
    // frames already transformed).
    if (item && !item.videoComposition) {
        AVAssetTrack *track = [item.asset tracksWithMediaType:AVMediaTypeVideo].firstObject;
        if (track) _posterTransform = track.preferredTransform;
    }
    if (url) {
        // A first poster before anything has played: the frame at the start, through the same pipeline.
        AVAssetImageGenerator *gen = [AVAssetImageGenerator assetImageGeneratorWithAsset:item.asset];
        gen.appliesPreferredTrackTransform = YES;
        gen.videoComposition = item.videoComposition;
        gen.maximumSize = CGSizeMake(1280, 1280);
        __weak MRGVideoEngine *weakSelf = self;
        NSURL *forURL = url;
        [gen generateCGImagesAsynchronouslyForTimes:@[[NSValue valueWithCMTime:kCMTimeZero]]
                                  completionHandler:^(CMTime req, CGImageRef image, CMTime actual, AVAssetImageGeneratorResult result, NSError *error) {
            if (result != AVAssetImageGeneratorSucceeded || !image) return;
            UIImage *poster = [UIImage imageWithCGImage:image];
            dispatch_async(dispatch_get_main_queue(), ^{
                MRGVideoEngine *me = weakSelf;
                if (me && [me->_loadedURL isEqual:forURL] && !me->_poster) me->_poster = poster;
            });
        }];
    }
    if (item) _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];
    [self update];
}

- (void)update {
    BOOL play = _active && _loadedURL && _visible.count > 0;
    if (play && _player.rate == 0) [_player play];
    else if (!play && _player.rate != 0) [_player pause];
}

- (void)viewAppeared:(id)view { [_visible addObject:view]; [self update]; }
- (void)viewDisappeared:(id)view {
    [_visible removeObject:view];
    if (!_visible.count) [self capturePoster];   // the frame the next background to appear starts on
    [self update];
}

@end

#pragma mark - view

CGRect MRGWindowRectInView(UIView *view) {
    UIWindow *window = view.window;
    CGSize size = window ? window.bounds.size : UIScreen.mainScreen.bounds.size;
    if (!window) return (CGRect){CGPointZero, size};
    // The window point of view's bounds origin, walked up through center/bounds rather than frame, which
    // is undefined under a transform.
    CGPoint p = view.bounds.origin;
    for (UIView *v = view; v && v != window; v = v.superview) {
        CGPoint anchor = v.layer.anchorPoint;
        CGPoint inSuper = CGPointMake(v.center.x + (p.x - v.bounds.origin.x - v.bounds.size.width * anchor.x),
                                      v.center.y + (p.y - v.bounds.origin.y - v.bounds.size.height * anchor.y));
        p = inSuper;
        if (!v.superview) break;
    }
    // p is where view's bounds origin sits in the window; the window's origin is that far up and left.
    return CGRectMake(view.bounds.origin.x - p.x, view.bounds.origin.y - p.y, size.width, size.height);
}

@implementation MRGBackgroundView {
    CADisplayLink *_link;
    UIView *_canvas;
    UIImageView *_imageView;
    AVPlayerLayer *_playerLayer;
    UIView *_dim;
    BOOL _posterUp;     // the image view shows the engine's poster until the player layer has a frame
}

static UIImage *sg_still;
static NSString *sg_stillKey;

+ (UIImage *)currentStill {
    NSURL *url = MRGCurrentKind() == MRGMediaImage ? MRGCurrentMediaURL() : nil;
    if (!url) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%.2f", url.lastPathComponent, blurRadius()];
    if ([key isEqualToString:sg_stillKey]) return sg_still;
    UIImage *image = [UIImage imageWithContentsOfFile:url.path];
    if (image && blurRadius() > 0.5) {
        // Once per change of picture or blur, not per frame.
        CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
        CIImage *out = [[[ci imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:blurRadius() * 2] imageByCroppingToRect:ci.extent];
        static CIContext *ctx;
        if (!ctx) ctx = [CIContext contextWithOptions:nil];
        CGImageRef cg = [ctx createCGImage:out fromRect:ci.extent];
        if (cg) { image = [UIImage imageWithCGImage:cg scale:image.scale orientation:image.imageOrientation]; CGImageRelease(cg); }
    }
    sg_still = image;
    sg_stillKey = key;
    return image;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.clipsToBounds = YES;
    self.backgroundColor = UIColor.clearColor;
    self.accessibilityElementsHidden = YES;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.insetsLayoutMarginsFromSafeArea = NO;
    _canvas = [[UIView alloc] initWithFrame:self.bounds];
    _canvas.userInteractionEnabled = NO;
    _canvas.backgroundColor = UIColor.blackColor;
    [self addSubview:_canvas];
    _imageView = [[UIImageView alloc] initWithFrame:_canvas.bounds];
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_canvas addSubview:_imageView];
    _dim = [[UIView alloc] initWithFrame:_canvas.bounds];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dim.backgroundColor = UIColor.blackColor;
    [_canvas addSubview:_dim];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGSettingsChangedNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [_link invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [MRGVideoEngine.shared viewDisappeared:self];
}

- (void)refresh {
    MRGMediaKind kind = MRGCurrentKind();
    MRGScaleMode scale = MRGScale();
    _dim.alpha = MIN(0.95, MRGDim() + _extraDim);
    _imageView.contentMode = scale == MRGScaleFit ? UIViewContentModeScaleAspectFit
                           : scale == MRGScaleStretch ? UIViewContentModeScaleToFill : UIViewContentModeScaleAspectFill;
    if (kind == MRGMediaImage) {
        _imageView.image = [MRGBackgroundView currentStill];
        _imageView.hidden = NO;
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    } else if (!_posterUp) {
        _imageView.image = nil;
        _imageView.hidden = YES;
    }
    if (kind == MRGMediaVideo) {
        [MRGVideoEngine.shared reload];
        if (!_playerLayer) {
            _playerLayer = [AVPlayerLayer playerLayerWithPlayer:MRGVideoEngine.shared.player];
            [_canvas.layer insertSublayer:_playerLayer below:_dim.layer];
            [self showPosterIfNeeded];
        }
        _playerLayer.videoGravity = scale == MRGScaleFit ? AVLayerVideoGravityResizeAspect
                                  : scale == MRGScaleStretch ? AVLayerVideoGravityResize : AVLayerVideoGravityResizeAspectFill;
    } else {
        [MRGVideoEngine.shared reload];
    }
    [self setNeedsLayout];
}

// A new player layer draws nothing until the player hands it a frame, a beat after it is on screen: the
// now playing sheet slid up dark gray and the picture popped in. The shared player is already running (or
// paused on a frame), so the engine's latest frame goes up at once, under the player layer, and comes down
// once that layer is ready.
- (void)showPosterIfNeeded {
    if (!_playerLayer || _playerLayer.isReadyForDisplay) { [self dropPoster]; return; }
    UIImage *poster = [MRGVideoEngine.shared posterFrame];
    if (!poster) return;
    _imageView.image = poster;
    _imageView.hidden = NO;
    _posterUp = YES;
}

- (void)dropPoster {
    if (!_posterUp) return;
    _posterUp = NO;
    if (MRGCurrentKind() != MRGMediaImage) { _imageView.image = nil; _imageView.hidden = YES; }
}

- (void)pinCanvas {
    CGRect target = (self.window && !_fitsBounds) ? MRGWindowRectInView(self) : self.bounds;
    UIView *follow = self.followView;
    if (self.window && !_fitsBounds && follow.window == self.window) {
        CGRect f = MRGWindowRectInView(follow);   // its origin is minus the card's own place on the window
        target.origin.x -= f.origin.x;
        target.origin.y -= f.origin.y;
    }
    if (CGRectEqualToRect(_canvas.frame, target) && CGRectEqualToRect(_playerLayer.frame, _canvas.bounds)) return;
    // No implicit animation: a frame that animates lags the page it sits in, which reads as a jump.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [UIView performWithoutAnimation:^{ self->_canvas.frame = target; }];
    _playerLayer.frame = _canvas.bounds;
    [CATransaction commit];
}

- (void)setExtraDim:(CGFloat)extraDim {
    if (extraDim == _extraDim) return;
    _extraDim = extraDim;
    _dim.alpha = MIN(0.95, MRGDim() + _extraDim);
}

- (void)setFitsBounds:(BOOL)fits {
    _fitsBounds = fits;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self pinCanvas];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    [self setNeedsLayout];
}

// The host can move without laying out (a scroll, the side drawer's peek, Library's grid/list switch, a page
// transition), and a canvas left where the window was a moment ago showed whatever was behind it: the page's
// black. While in a window the canvas is re-pinned once per frame; pinCanvas costs a walk up a few superviews
// and does nothing when nothing moved.
- (void)tick:(CADisplayLink *)link {
    [self pinCanvas];
    if (_posterUp && _playerLayer.isReadyForDisplay) [self dropPoster];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_link invalidate];
    _link = nil;
    if (self.window && !self.fitsBounds) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    if (self.window) [self pinCanvas];
    if (self.window && !_playerLayer.isReadyForDisplay) [self showPosterIfNeeded];
    if (self.window && !self.hidden) [MRGVideoEngine.shared viewAppeared:self];
    else [MRGVideoEngine.shared viewDisappeared:self];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (self.window && !hidden) [MRGVideoEngine.shared viewAppeared:self];
    else [MRGVideoEngine.shared viewDisappeared:self];
}

@end
