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
    AVPlayerItem *item = url ? videoOnlyItem(url, blur) : nil;
    if (item) _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];
    [self update];
}

- (void)update {
    BOOL play = _active && _loadedURL && _visible.count > 0;
    if (play && _player.rate == 0) [_player play];
    else if (!play && _player.rate != 0) [_player pause];
}

- (void)viewAppeared:(id)view { [_visible addObject:view]; [self update]; }
- (void)viewDisappeared:(id)view { [_visible removeObject:view]; [self update]; }

@end

#pragma mark - view

@implementation MRGBackgroundView {
    UIImageView *_imageView;
    AVPlayerLayer *_playerLayer;
    UIView *_dim;
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
    self.backgroundColor = UIColor.blackColor;
    self.accessibilityElementsHidden = YES;
    _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_imageView];
    _dim = [[UIView alloc] initWithFrame:self.bounds];
    _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dim.backgroundColor = UIColor.blackColor;
    [self addSubview:_dim];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGSettingsChangedNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [MRGVideoEngine.shared viewDisappeared:self];
}

- (void)refresh {
    MRGMediaKind kind = MRGCurrentKind();
    MRGScaleMode scale = MRGScale();
    _dim.alpha = MRGDim();
    _imageView.contentMode = scale == MRGScaleFit ? UIViewContentModeScaleAspectFit
                           : scale == MRGScaleStretch ? UIViewContentModeScaleToFill : UIViewContentModeScaleAspectFill;
    if (kind == MRGMediaImage) {
        _imageView.image = [MRGBackgroundView currentStill];
        _imageView.hidden = NO;
        [_playerLayer removeFromSuperlayer];
        _playerLayer = nil;
    } else {
        _imageView.image = nil;
        _imageView.hidden = YES;
    }
    if (kind == MRGMediaVideo) {
        [MRGVideoEngine.shared reload];
        if (!_playerLayer) {
            _playerLayer = [AVPlayerLayer playerLayerWithPlayer:MRGVideoEngine.shared.player];
            [self.layer insertSublayer:_playerLayer below:_dim.layer];
        }
        _playerLayer.videoGravity = scale == MRGScaleFit ? AVLayerVideoGravityResizeAspect
                                  : scale == MRGScaleStretch ? AVLayerVideoGravityResize : AVLayerVideoGravityResizeAspectFill;
    } else {
        [MRGVideoEngine.shared reload];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _playerLayer.frame = self.bounds;
    [CATransaction commit];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !self.hidden) [MRGVideoEngine.shared viewAppeared:self];
    else [MRGVideoEngine.shared viewDisappeared:self];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    if (self.window && !hidden) [MRGVideoEngine.shared viewAppeared:self];
    else [MRGVideoEngine.shared viewDisappeared:self];
}

@end
