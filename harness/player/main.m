// A mock of Spotify's full screen player under its own class names and accessibility identifiers, built
// from trees/clean/player/01.txt, so Redesigned/Player's lyrics state can be laid out, animated and
// looked at on the Mac. Tapping the lyrics glyph in the footer works exactly as it does on the phone;
// the harness also toggles it once by itself so a screenshot catches each state.
//
// HARNESS_SCENARIO (simctl launch passes it as SIMCTL_CHILD_HARNESS_SCENARIO) picks what it does:
//     lyrics   (default) the lyrics opened at 2 s, closed at 6, opened again at 10
//     look     one track playing, a second one from another album at 8 s, nothing opened
//     scroll   the list moved up and down in code; the log says whether it stayed at its top, then a scrub of
//              the progress bar begun and ended in code; the log says whether it held the list's pan
//     cover    the lyric preview given room under a smaller cover, as Spotify lays a track with lyrics out;
//              the log says whether the cover took that room back, PASS or FAIL
//     immersive the lyrics left alone: what fades, where the lines go, the tap that brings the controls
//              back, a scroll and the thumbnail; the log says PASS or FAIL
//     artwork  issue #58: tracks change while the covers on screen and the picture server lag behind,
//              checked by color at the end of each step; the log says PASS or FAIL
//     landscape the landscape lyrics at 3 s, a line's meanings over them, a pause and a resume; each
//              step logs whether the controls are up and what a touch on the lines lands on
//     motion   Animated artwork: a clip (HARNESS_CANVAS_FILE, an mp4) that comes in before the player has
//              laid out, then the field, the lyrics, a field built again, the menu's switch and the player
//              closed, each step checked; the log ends with motion checks n of m right -- PASS or FAIL
//     catalog  Apple Music's catalog behind a stub: the search term without the edition, the album of the same
//              name first, and the pause after a 429; the log says PASS or FAIL
//     settings the redesign's Player page (PlayerSettings.m) over the player with the clip of `motion`: the
//              card over Animated, then Fluid, Colors, Still and Visualizer as the segmented control picks
//              them, and Animated again, the note under it changing and the rows under the header holding
//              still; each step checked, the log ends with settings checks n of m right -- PASS or FAIL
//     preview  the Player page's card picking Animated while the player has no clip (the background Still at
//              launch): the card looks the track's clip up itself, shows Fluid until it comes in 2 s late, then
//              the clip; the clip is in the store for the player, and asked for only while the page shows;
//              the log ends with preview checks n of m right -- PASS or FAIL
//     visualiser the Visualizer background (PlayerVisualiser.m) fed a song of the harness's own (stubs.m):
//              the hills moving, blurred behind the lyrics, settling and stopping on a pause, back on play,
//              and the ⋯ menu's switch to Fluid and back; the log ends with visualizer checks n of m right
//              -- PASS or FAIL
// HARNESS_VOLUME=0 leaves out the volume row the phone has (trees/clean/player/01.txt has none).
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "Shared/Lyrics/Lyrics.h"
#import "Redesigned/Player/Player.h"
#import "Shared/AnimatedArtwork/AnimatedArtwork.h"
#import "Redesigned/Kit/SGRBridges.h"
#import "Redesigned/Kit/SGRField.h"
#import "Redesigned/Lyrics/MeaningSheet.h"
#import "Redesigned/Lyrics/SGRKaraokeView.h"

void SGRHarnessPlayFrom(NSInteger ms);
void SGRHarnessSetTrack(NSString *uri, NSString *imageURI, BOOL paused);
// ../tabbar/touch.m: a finger's touches, through UIKit's own recognizers.
extern void SGHarnessHold(UIWindow *window, CGPoint point, NSTimeInterval seconds);

static NSString *scenario(void) {
    const char *value = getenv("HARNESS_SCENARIO");
    return value ? @(value) : @"lyrics";
}

#pragma mark - the picture server

// i.scdn.co as the harness wants it: each picture by the last 24 digits of its id, served after a delay
// of its own, or failed as if the phone were offline.
@interface SGRHarnessPicture : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic) NSTimeInterval delay;
@property (nonatomic) BOOL fails;
@end
@implementation SGRHarnessPicture
@end

static NSMutableDictionary<NSString *, SGRHarnessPicture *> *sg_pictures;
static NSUInteger sg_served;
// How many times the clip itself was served.
static NSUInteger sg_canvasServed;
// The catalog scenario's Apple Music: the addresses asked, in order, what it answers, and the clips' playlists
// asked for after it.
static NSMutableArray<NSURL *> *sg_catalogAsked, *sg_canvasAsked;
static NSInteger sg_catalogStatus = 200;
static NSData *sg_catalogBody;

static void serve(NSString *imageURI, UIImage *image, NSTimeInterval delay, BOOL fails) {
    if (!sg_pictures) sg_pictures = [NSMutableDictionary dictionary];
    SGRHarnessPicture *picture = [SGRHarnessPicture new];
    picture.image = image;
    picture.delay = delay;
    picture.fails = fails;
    sg_pictures[[imageURI substringFromIndex:imageURI.length - 24]] = picture;
}

@interface SGRHarnessPictureServer : NSURLProtocol
@end

@implementation SGRHarnessPictureServer {
    BOOL _stopped;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([request.URL.host isEqualToString:@"amp-api.music.apple.com"]) return sg_catalogAsked != nil;
    return [request.URL.host isEqualToString:@"i.scdn.co"] || [request.URL.host isEqualToString:@"canvas.harness"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    if ([self.request.URL.host isEqualToString:@"amp-api.music.apple.com"]) {
        @synchronized (sg_catalogAsked) { [sg_catalogAsked addObject:self.request.URL]; }
        NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:sg_catalogStatus HTTPVersion:@"HTTP/1.1"
                                                                headerFields:@{@"Content-Type": @"application/json"}];
        [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        [self.client URLProtocol:self didLoadData:sg_catalogBody ?: [NSData data]];
        [self.client URLProtocolDidFinishLoading:self];
        return;
    }
    if (sg_canvasAsked && [self.request.URL.path hasSuffix:@".m3u8"]) {
        @synchronized (sg_canvasAsked) { [sg_canvasAsked addObject:self.request.URL]; }
        [self answer:nil];
        return;
    }
    // The motion scenario's clip, at once, or HARNESS_CANVAS_DELAY seconds late.
    if ([self.request.URL.host isEqualToString:@"canvas.harness"]) {
        const char *file = getenv("HARNESS_CANVAS_FILE"), *delay = getenv("HARNESS_CANVAS_DELAY");
        NSData *data = file ? [NSData dataWithContentsOfFile:@(file)] : nil;
        // HARNESS_CANVAS_FAILS=n: the first n requests for it fail on the way, as a download iOS canceled.
        static int failing = -1;
        if (failing < 0) failing = getenv("HARNESS_CANVAS_FAILS") ? atoi(getenv("HARNESS_CANVAS_FAILS")) : 0;
        if (failing > 0) {
            failing--;
            data = nil;
            NSLog(@"[harness] canvas server: this request fails");
        }
        NSThread *thread = NSThread.currentThread;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((delay ? atof(delay) : 0) * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
            sg_canvasServed++;
            [self performSelector:@selector(answer:) onThread:thread withObject:data waitUntilDone:NO];
        });
        return;
    }
    NSString *name = self.request.URL.lastPathComponent;
    SGRHarnessPicture *picture = name.length >= 24 ? sg_pictures[[name substringFromIndex:name.length - 24]] : nil;
    NSThread *thread = NSThread.currentThread;
    NSLog(@"[harness] picture server: %@ asked for, %@", name, picture ? (picture.fails ? @"will fail" : [NSString stringWithFormat:@"answers in %.1f s", picture.delay]) : @"unknown");
    NSData *data = picture.fails ? nil : UIImagePNGRepresentation(picture.image);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(picture.delay * NSEC_PER_SEC)), dispatch_get_global_queue(0, 0), ^{
        [self performSelector:@selector(answer:) onThread:thread withObject:data waitUntilDone:NO];
    });
}

- (void)answer:(NSData *)data {
    if (_stopped) return;
    if (!data) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
        return;
    }
    sg_served++;
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:200 HTTPVersion:@"HTTP/1.1"
                                                            headerFields:@{@"Content-Type": @"image/png"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    _stopped = YES;
}

@end

// Every session the mod makes is handed the server first.
@implementation NSURLSessionConfiguration (SGRHarness)
+ (NSURLSessionConfiguration *)sgr_harnessDefault {
    NSURLSessionConfiguration *configuration = [self sgr_harnessDefault];
    configuration.protocolClasses = [@[SGRHarnessPictureServer.class] arrayByAddingObjectsFromArray:configuration.protocolClasses ?: @[]];
    return configuration;
}
@end

#pragma mark - pictures

static UIImage *solid(UIColor *color) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    return [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(300, 300) format:format] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [color setFill];
        UIRectFill(CGRectMake(0, 0, 300, 300));
    }];
}

// The color a picture is, by the pixel in its middle, named the way the checks name them.
static NSString *colorName(UIImage *image) {
    if (!image.CGImage) return @"none";
    uint8_t px[4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(px, 1, 1, 8, 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    CGFloat w = CGImageGetWidth(image.CGImage), h = CGImageGetHeight(image.CGImage);
    CGContextDrawImage(context, CGRectMake(-w / 2, -h / 2, w, h), image.CGImage);
    CGContextRelease(context);
    int r = px[0] > 128, g = px[1] > 128, b = px[2] > 128;
    NSArray *names = @[@"black", @"blue", @"green", @"cyan", @"red", @"magenta", @"yellow", @"white"];
    return names[r << 2 | g << 1 | b];
}

#pragma mark - Spotify's classes, by name

@interface _TtC19NowPlaying_ViewImpl24NowPlayingViewController : UIViewController @end
@implementation _TtC19NowPlaying_ViewImpl24NowPlayingViewController @end

@interface _TtC20NowPlaying_ModesImpl23InformationElementsUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl23InformationElementsUnit @end

@interface _TtC20NowPlaying_ModesImpl19DurationElementUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl19DurationElementUnit @end

@interface _TtC20NowPlaying_ModesImpl20FloatingElementsUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl20FloatingElementsUnit @end

@interface _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit @end

@interface _TtC20NowPlaying_ModesImpl18HeaderElementsUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl18HeaderElementsUnit @end

@interface _TtC20NowPlaying_ModesImpl18FooterElementsUnit : UIViewController @end
@implementation _TtC20NowPlaying_ModesImpl18FooterElementsUnit @end

@interface _TtC21NowPlaying_ScrollImpl23NPVScrollViewController : UIViewController <UIScrollViewDelegate> @end
@implementation _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)scrollViewDidScroll:(UIScrollView *)list {}
@end

@interface _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView : UICollectionView @end
@implementation _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView @end

@interface _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl : UICollectionViewCell @end
@implementation _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl @end

@interface _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController : UIViewController @end
@implementation _TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController @end

// One of the units Spotify shows its music video in (Switch to video); PlayerMotion.x hooks its video surface.
@interface _TtC22NowPlaying_ElementsKit14VideoElementUI : NSObject @end
@implementation _TtC22NowPlaying_ElementsKit14VideoElementUI
- (void)videoSurfaceDidAttachVideo:(id)surface {}
- (void)videoSurfaceDidDetachVideo:(id)surface {}
@end

@interface _TtC18NowPlaying_BarImpl27NowPlayingBarViewController : UIViewController @end
@implementation _TtC18NowPlaying_BarImpl27NowPlayingBarViewController @end

@interface _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView : UIView
- (void)handleTap;
@end
@implementation _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)handleTap {}
@end

@interface _TtC22Lyrics_NPVContainerKit19LyricsContainerView : UIView @end
@implementation _TtC22Lyrics_NPVContainerKit19LyricsContainerView @end

// The progress bar's slider (01.txt:224), tracking without a touch so the harness can scrub it in code.
@interface _TtCO17NowPlaying_ECMKit11ProgressBar6Slider : UISlider @end
@implementation _TtCO17NowPlaying_ECMKit11ProgressBar6Slider
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { return YES; }
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {}
- (void)cancelTrackingWithEvent:(UIEvent *)event {}
@end

// The play button's view, which PlayerControls.x hooks for its tap.
@interface _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView : UIView @end
@implementation _TtC28EncoreConsumerMobile_BaseKit14PlayButtonView
- (void)uiButtonTapped {}
@end

@interface MockEncoreButton : UIControl @end
@implementation MockEncoreButton @end

#pragma mark - building the tree

static UIView *box(UIView *parent, Class cls, CGRect frame, NSString *identifier) {
    UIView *view = [[cls alloc] initWithFrame:frame];
    view.accessibilityIdentifier = identifier;
    [parent addSubview:view];
    return view;
}

static UILabel *marquee(UIView *parent, CGRect frame, NSString *text, CGFloat size, UIColor *color, NSString *identifier) {
    UIView *clip = box(parent, UIView.class, frame, identifier);
    clip.clipsToBounds = YES;
    UILabel *inner = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 900, frame.size.height)];
    inner.text = text;
    inner.font = [UIFont systemFontOfSize:size weight:UIFontWeightBold];
    inner.textColor = color;
    [inner sizeToFit];
    [clip addSubview:inner];
    return inner;
}

static UIView *glyphButton(UIView *parent, CGRect frame, NSString *symbol, NSString *identifier) {
    UIView *button = box(parent, MockEncoreButton.class, frame, identifier);
    UIImageView *glyph = [[UIImageView alloc] initWithFrame:CGRectInset(button.bounds, 10, 10)];
    glyph.image = [UIImage systemImageNamed:symbol];
    glyph.contentMode = UIViewContentModeScaleAspectFit;
    glyph.tintColor = UIColor.whiteColor;
    [button addSubview:glyph];
    return button;
}

static UIImage *artwork(void) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(354, 354)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat components[] = {0.11, 0.06, 0.35, 1, 0.83, 0.15, 0.62, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, components, NULL, 2);
        CGContextDrawLinearGradient(ctx.CGContext, gradient, CGPointZero, CGPointMake(354, 354), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        [[UIColor colorWithWhite:1 alpha:0.9] set];
        [@"LOOSE\nCANON" drawAtPoint:CGPointMake(28, 28) withAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:44 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.92 blue:0.2 alpha:1],
        }];
    }];
}

// A second album, busier: a warm sky over teal water with a sun in it, for the track change.
static UIImage *secondArtwork(void) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(354, 354)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGFloat sky[] = {0.98, 0.55, 0.20, 1, 0.85, 0.22, 0.30, 1};
        CGGradientRef gradient = CGGradientCreateWithColorComponents(space, sky, NULL, 2);
        CGContextDrawLinearGradient(c, gradient, CGPointZero, CGPointMake(0, 200), 0);
        CGGradientRelease(gradient);
        CGFloat sea[] = {0.05, 0.45, 0.50, 1, 0.02, 0.12, 0.22, 1};
        gradient = CGGradientCreateWithColorComponents(space, sea, NULL, 2);
        CGContextSaveGState(c);
        CGContextClipToRect(c, CGRectMake(0, 200, 354, 154));
        CGContextDrawLinearGradient(c, gradient, CGPointMake(0, 200), CGPointMake(0, 354), 0);
        CGContextRestoreGState(c);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        [[UIColor colorWithRed:1 green:0.9 blue:0.55 alpha:1] setFill];
        CGContextFillEllipseInRect(c, CGRectMake(210, 110, 90, 90));
        [@"LOW\nTIDE" drawAtPoint:CGPointMake(26, 230) withAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:40 weight:UIFontWeightHeavy],
            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.9],
        }];
    }];
}

// A song with words timed inside each line, the shape SGRKaraokeView draws.
static void loadLyrics(void) {
    NSArray<NSString *> *texts = @[
        @"Who got the 808 under the 809",
        @"Making everybody jump?",
        @"Easy, I'm motivated",
        @"I got the feeling this is overrated",
        @"Give me the respect or give me nothing",
        @"Running up the hill with a heavy load",
        @"Tell them that the kid never folded",
        @"Every single verse was a promise kept",
        @"Nobody was there when it started",
        @"Now everybody wanna say they knew",
    ];
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    NSInteger at = 0;
    for (NSString *text in texts) {
        NSArray<NSString *> *words = [text componentsSeparatedByString:@" "];
        NSMutableArray<SGKaraokeWord *> *built = [NSMutableArray array];
        NSInteger cursor = at;
        for (NSString *word in words) {
            SGKaraokeWord *w = [SGKaraokeWord new];
            w.text = word;
            w.start = cursor;
            cursor += 260 + word.length * 40;
            // Each line's last word is held, as sung lines often end, so the held-word glow shows.
            if (word == words.lastObject) cursor += 1600;
            w.end = cursor;
            [built addObject:w];
        }
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = built;
        line.start = at;
        line.end = cursor;
        [lines addObject:line];
        at = cursor + 400;
    }
    SGKaraokeKeepLines(@"harness", lines);
}

#pragma mark - the harness

// PlayerArtwork.x's hold on the cover, whose badge the badge scenario shows and hides by hand.
@interface NSObject (SGRHarnessHold)
- (void)showBadge:(BOOL)shown on:(UIView *)cover;
@end

// PlayerLyrics.x's tap that brings the controls back and the thumbnail's, fired by hand.
@interface NSObject (SGRHarnessLyrics)
- (void)sgr_woke;
- (void)sgr_thumbTapped;
@end

@interface SGRHarnessDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGRHarnessDelegate {
    NSArray<UIViewController *> *_units;
    NSUInteger _headerDowns;
    UIImageView *_cover, *_barCover;
    UIViewController *_bar;
    UICollectionView *_covers;
    UIScrollView *_list;
    UIView *_plane, *_host;
    UIViewController *_background;
    UIView *_tilt;
    NSUInteger _failures, _checks;
    float _dimAlone;   // the motion scenario's dim before the lyrics
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    loadLyrics();
    SGRHarnessPlayFrom(2400);
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.07 blue:0.17 alpha:1];
    self.window.rootViewController = root;

    CGFloat W = root.view.bounds.size.width, H = root.view.bounds.size.height;
    // The player's own numbers are the tree's 402x874; the simulator's screen is whatever it is, so the
    // rows are placed as shares of it, the way Spotify's layout puts them.
    CGFloat headerTop = 62, headerHeight = 48;
    CGFloat bandTop = headerTop + headerHeight;
    const char *volumeEnv = getenv("HARNESS_VOLUME");
    BOOL hasVolume = !(volumeEnv && volumeEnv[0] == '0');
    CGFloat bottomHeight = 236 + (hasVolume ? 44 : 0);   // the tree's rows plus a volume row, as the phone has it
    CGFloat bottomTop = H - bottomHeight - 61.33;
    CGFloat bandHeight = bottomTop - bandTop;
    CGFloat coverSide = MIN(354, W - 48);

    // NPVScrollViewController: the list the player is the header of.
    UIView *page = box(root.view, UIView.class, root.view.bounds, nil);
    UIScrollView *list = [[UIScrollView alloc] initWithFrame:page.bounds];
    list.accessibilityIdentifier = @"scrolling_npv_collection_view_accessibility_identifier";
    list.contentSize = CGSizeMake(W, H + 326);       // the player and a card's worth of cards under it
    [page addSubview:list];
    UIViewController *scrollUnit = [_TtC21NowPlaying_ScrollImpl23NPVScrollViewController new];
    scrollUnit.view = page;
    list.delegate = (id<UIScrollViewDelegate>)scrollUnit;
    _list = list;

    // NPVBackgroundViewController's plane, the field's home (trees/clean/player/01.txt:449), under the player.
    UIView *plane = box(list, UIView.class, CGRectMake(0, 0, W, H), nil);
    plane.backgroundColor = [UIColor colorWithRed:0.3 green:0.1 blue:0.3 alpha:1];
    UIViewController *background = [_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController new];
    background.view = plane;

    UIView *host = box(list, UIView.class, CGRectMake(0, 0, W, H), @"SPTNowPlayingView");

    // the content layers: the sideways list of covers
    UIView *layers = box(host, UIView.class, host.bounds, nil);
    UICollectionViewFlowLayout *flow = [UICollectionViewFlowLayout new];
    UICollectionView *covers = [[_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView alloc]
                                initWithFrame:layers.bounds collectionViewLayout:flow];
    covers.accessibilityIdentifier = @"nowplaying-contentlayer-collectionview";
    covers.backgroundColor = UIColor.clearColor;
    [layers addSubview:covers];
    UIView *cell = box(covers, _TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl.class, covers.bounds, @"nowplaying-contentlayer-cell-0");
    UIView *band = box(cell, UIView.class, CGRectMake(0, bandTop, W, bandHeight), nil);
    UIView *inner = box(band, UIView.class, CGRectMake(24, 8, W - 48, bandHeight - 16), nil);
    UIView *tilt = box(inner, _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView.class,
                       CGRectMake(0, round((inner.bounds.size.height - coverSide) / 2), coverSide, coverSide), nil);
    tilt.accessibilityLabel = @"Inspect cover art";
    _tilt = tilt;
    // The Encore.ImageView holding the picture (01.txt:40), which PlayerField.x reads the cover from.
    UIView *coverElement = box(tilt, UIView.class, tilt.bounds, @"Encore.ImageView");
    coverElement.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImage *picture = artwork();
    UIImageView *cover = [[UIImageView alloc] initWithFrame:coverElement.bounds];
    cover.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    cover.image = picture;
    _cover = cover;
    cover.contentMode = UIViewContentModeScaleAspectFill;
    [coverElement addSubview:cover];
    box(inner, _TtC22Lyrics_NPVContainerKit19LyricsContainerView.class, CGRectMake(0, inner.bounds.size.height, coverSide, 0), nil);

    // the header row
    UIView *header = box(host, UIStackView.class, CGRectMake(0, headerTop, W, headerHeight), nil);
    glyphButton(header, CGRectMake(12, 0, 48, 48), @"chevron.down", @"now-playing-minimize-button");
    glyphButton(header, CGRectMake(W - 60, 0, 48, 48), @"ellipsis", @"Context menu");

    // the bottom stack: information, duration, controls, volume, footer
    UIView *bottom = box(host, UIStackView.class, CGRectMake(0, bottomTop, W, bottomHeight), @"npv.bottomStackView");

    UIView *floatingView = box(bottom, UIView.class, CGRectMake(0, -32, W, 32), nil);
    UIView *chip = box(floatingView, UIView.class, CGRectMake(24, 0, 148, 32), nil);
    chip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    chip.layer.cornerRadius = 16;
    UILabel *chipLabel = [[UILabel alloc] initWithFrame:chip.bounds];
    chipLabel.text = @"  \u25B6  Switch to video";
    chipLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    chipLabel.textColor = UIColor.whiteColor;
    [chip addSubview:chipLabel];

    UIView *infoView = box(bottom, UIView.class, CGRectMake(0, 0, W, 64), nil);
    UIView *infoRow = box(infoView, UIStackView.class, CGRectMake(12, 8, W - 24, 48), nil);
    UIView *infoInner = box(infoRow, UIStackView.class, infoRow.bounds, nil);
    box(infoInner, UIView.class, CGRectMake(0, 24, 0, 0), nil);          // Spotify's own mini cover, unused
    box(infoInner, UIView.class, CGRectMake(0, 24, 12, 0), nil);         // the spacer after it
    CGFloat titleWidth = infoInner.bounds.size.width - 12 - 60;
    UIView *titleElement = box(infoInner, UIView.class, CGRectMake(12, 2.33, titleWidth, 43.33), nil);
    UIView *titleContainer = box(titleElement, UIView.class, titleElement.bounds, nil);
    marquee(titleContainer, CGRectMake(0, 0, titleWidth, 25.33), @"We Are The People - southstar Remix (Extended)", 21,
            UIColor.whiteColor, @"now-playing-title-label");
    marquee(titleContainer, CGRectMake(0, 25.33, titleWidth, 18), @"Canon", 13,
            [UIColor colorWithWhite:1 alpha:0.7], @"now-playing-subtitle-label");
    glyphButton(infoInner, CGRectMake(infoInner.bounds.size.width - 48, 0, 48, 48), @"star", @"Components.UI.AddToButton");

    UIView *durationView = box(bottom, UIView.class, CGRectMake(0, 64, W, 40), nil);
    UIView *track = box(durationView, UIView.class, CGRectMake(24, 8, W - 48, 6), nil);
    track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    track.layer.cornerRadius = 3;
    UIView *played = box(track, UIView.class, CGRectMake(0, 0, (W - 48) * 0.22, 6), nil);
    played.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    played.layer.cornerRadius = 3;

    UIView *controls = box(bottom, UIView.class, CGRectMake(0, 104, W, 88), nil);
    glyphButton(controls, CGRectMake(W / 2 - 130, 20, 48, 48), @"backward.fill", nil);
    glyphButton(controls, CGRectMake(W / 2 - 24, 14, 48, 60), @"pause.fill", nil);
    glyphButton(controls, CGRectMake(W / 2 + 82, 20, 48, 48), @"forward.fill", nil);

    if (hasVolume) {
        UIView *volume = box(bottom, UIView.class, CGRectMake(0, 192, W, 44), nil);
        UIView *volumeTrack = box(volume, UIView.class, CGRectMake(44, 19, W - 88, 6), nil);
        volumeTrack.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
        volumeTrack.layer.cornerRadius = 3;
    }

    UIView *footerView = box(bottom, UIView.class, CGRectMake(0, hasVolume ? 236 : 192, W, 44), nil);
    UIView *footerRow = box(footerView, UIStackView.class, CGRectMake(12, 0, W - 24, 44), nil);
    UIView *connect = box(footerRow, UIView.class, CGRectMake(0, 4, 153.67, 36), nil);
    UIView *connectHolder = box(connect, UIView.class, connect.bounds, @"Components.ConnectButtonOutputSwitcher");
    UIImageView *connectGlyph = [[UIImageView alloc] initWithFrame:CGRectMake(0, 8, 19, 19)];
    connectGlyph.image = [UIImage systemImageNamed:@"airpods.pro"];
    connectGlyph.tintColor = UIColor.whiteColor;
    [connectHolder addSubview:connectGlyph];
    glyphButton(footerRow, CGRectMake(279, 0, 44, 44), @"square.and.arrow.up", @"ShareButtonNowPlayingView");
    glyphButton(footerRow, CGRectMake(323, 6, 47, 32), @"list.bullet", @"QueueButtonNowPlaying");

    // The now playing bar, off screen: the Kit reads its 40pt cover (SPTNowPlayingBar > Encore.ImageView >
    // UIImageView, trees/clean/artist/01.txt).
    UIView *barView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, 64)];
    UIView *barCard = box(barView, UIView.class, CGRectMake(8, 8, W - 16, 48), @"SPTNowPlayingBar");
    UIView *barHolder = box(barCard, UIView.class, CGRectMake(8, 4, 40, 40), @"Encore.ImageView");
    UIImageView *barCover = [[UIImageView alloc] initWithFrame:barHolder.bounds];
    barCover.image = picture;
    [barHolder addSubview:barCover];
    _barCover = barCover;
    _bar = [_TtC18NowPlaying_BarImpl27NowPlayingBarViewController new];
    _bar.view = barView;

    [self.window makeKeyAndVisible];

    UIViewController *info = [_TtC20NowPlaying_ModesImpl23InformationElementsUnit new];
    info.view = infoView;
    UIViewController *duration = [_TtC20NowPlaying_ModesImpl19DurationElementUnit new];
    duration.view = durationView;
    UIViewController *floating = [_TtC20NowPlaying_ModesImpl20FloatingElementsUnit new];
    floating.view = floatingView;
    UIViewController *footer = [_TtC20NowPlaying_ModesImpl18FooterElementsUnit new];
    footer.view = footerView;
    UIViewController *playback = [_TtC20NowPlaying_ModesImpl28PlaybackControlsElementsUnit new];
    playback.view = controls;
    UIViewController *headerUnit = [_TtC20NowPlaying_ModesImpl18HeaderElementsUnit new];
    headerUnit.view = header;
    UIViewController *player = [_TtC19NowPlaying_ViewImpl24NowPlayingViewController new];
    player.view = host;
    _units = @[headerUnit, info, duration, floating, playback, footer, scrollUnit, background, player];
    _covers = covers;
    _plane = plane;
    _host = host;
    _background = background;
    // The player has not been opened yet: its background plane is laid out only when it is.
    if ([scenario() isEqualToString:@"motion"]) {
        [plane removeFromSuperview];
        _units = @[headerUnit, info, duration, floating, playback, footer, scrollUnit, player];
    }
    [self start];
    [self layOut];
    // Spotify lays its units out again as a track's elements arrive, which is what the redesign's
    // transforms and narrowed labels have to survive.
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) { [self layOut]; }];

    NSLog(@"[harness] lyrics available: %d", SGRPlayerLyricsAvailable());
    // With the lines up, the row that rose into them must still be Spotify's to touch, and the lines
    // themselves must take the tap that seeks.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *star = nil;
        for (UIView *v in infoInner.subviews) if ([v.accessibilityIdentifier isEqualToString:@"Components.UI.AddToButton"]) star = v;
        CGPoint onStar = [self.window convertPoint:CGPointMake(CGRectGetMidX(star.bounds), CGRectGetMidY(star.bounds)) fromView:star];
        CGPoint onTitle = [self.window convertPoint:CGPointMake(40, 12) fromView:titleElement];
        CGPoint onLines = CGPointMake(W / 2, H * 0.45);
        NSLog(@"[harness] hit on the star: %@", NSStringFromClass([self.window hitTest:onStar withEvent:nil].class));
        NSLog(@"[harness] hit on the title: %@", NSStringFromClass([self.window hitTest:onTitle withEvent:nil].class));
        NSLog(@"[harness] hit on the lines: %@", NSStringFromClass([self.window hitTest:onLines withEvent:nil].class));
    });
    if ([scenario() isEqualToString:@"artwork"]) [self runArtworkChecks];
    else if ([scenario() isEqualToString:@"look"]) [self runLook];
    else if ([scenario() isEqualToString:@"scroll"]) [self runScrollChecks];
    else if ([scenario() isEqualToString:@"landscape"]) [self runLandscape];
    else if ([scenario() isEqualToString:@"motion"]) [self runMotionChecks];
    else if ([scenario() isEqualToString:@"catalog"]) [self runCatalogChecks];
    else if ([scenario() isEqualToString:@"badge"]) [self runBadgeChecks];
    else if ([scenario() isEqualToString:@"cover"]) [self runCoverChecks];
    else if ([scenario() isEqualToString:@"immersive"]) [self runImmersiveChecks];
    else if ([scenario() isEqualToString:@"settings"]) [self runSettingsChecks];
    else if ([scenario() isEqualToString:@"preview"]) [self runPreviewChecks];
    else if ([scenario() isEqualToString:@"seek"]) [self runSeekChecks];
    else if ([scenario() isEqualToString:@"visualiser"]) [self runVisualiserChecks];
    else if ([scenario() isEqualToString:@"header"]) [self runHeaderChecks];
    // Opened, closed and opened again, so a screenshot can be taken of each state and of the move itself.
    else for (NSNumber *at in @[@2, @6, @10]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(at.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NSLog(@"[harness] %@ the lyrics", SGRPlayerLyricsOpen() ? @"closing" : @"opening");
            SGRPlayerToggleLyrics();
        });
    }
    return YES;
}

- (void)layOut {
    for (UIViewController *unit in _units) [unit viewDidLayoutSubviews];
}

#pragma mark - tracks

static NSString *imageURI(NSString *digits) {
    // 16 digits of size, then the picture's own 24 (padded here from a short name).
    NSString *hash = [[digits stringByPaddingToLength:24 withString:@"0" startingAtIndex:0] substringToIndex:24];
    return [@"spotify:image:ab67616d0000b273" stringByAppendingString:hash];
}

static UIViewController *unitOf(UIView *view) {
    UIResponder *next = view.nextResponder;
    return [next isKindOfClass:UIViewController.class] ? (UIViewController *)next : nil;
}

static UIView *firstOfClass(UIView *root, NSString *name);

// The alpha of a gradient's stop `index`.
static CGFloat stopAlpha(CAGradientLayer *gradient, NSUInteger index) {
    return CGColorGetAlpha((__bridge CGColorRef)gradient.colors[index]);
}

static void after(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// What Spotify's screens do when a track changes: the list of covers moves to the new cell and lays out,
// still showing whatever picture that cell had, and the bar's cover stays what it was, until the
// pictures load and are set on the image views -- which lays nothing out.
- (void)playTrack:(NSString *)uri image:(NSString *)image {
    NSLog(@"[harness] track %@ (picture %@)", uri, [image substringFromIndex:image.length - 24]);
    SGRHarnessSetTrack(uri, image, NO);
    [_covers setNeedsLayout];
    [_covers layoutIfNeeded];
}

- (void)showOnScreen:(UIImage *)picture {
    _cover.image = picture;
    _barCover.image = picture;
}

- (void)start {
    BOOL checks = [scenario() isEqualToString:@"artwork"];
    UIImage *first = checks ? solid(UIColor.redColor) : _cover.image;
    [self showOnScreen:first];
    serve(imageURI(@"aaaa"), first, 0.2, NO);
    // card: nothing plays; the Player page's card shows the last track played, or none.
    if ([scenario() isEqualToString:@"card"]) {
        after(1, ^{
            UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:SGRPlayerSettingsPage(@[])];
            nav.modalPresentationStyle = UIModalPresentationFullScreen;
            [self.window.rootViewController presentViewController:nav animated:NO completion:nil];
            after(2, ^{
                UIView *card = firstOfClass(((UITableViewController *)nav.topViewController).tableView.tableHeaderView, @"SGRPlayerShowcase");
                UIImageView *cover = [card valueForKey:@"_cover"];
                NSLog(@"[harness] card: \"%@\", \"%@\", cover %.0fx%.0f", [[card valueForKey:@"_title"] text], [[card valueForKey:@"_artist"] text],
                      cover.image.size.width, cover.image.size.height);
            });
        });
        return;
    }
    [self playTrack:@"spotify:track:harnessA" image:imageURI(@"aaaa")];
    // The bar lays out once as the app comes up.
    [_bar viewDidLayoutSubviews];
}

#pragma mark - landscape

static UIViewController *landscapeScreen(void) {
    for (UIWindow *window in UIApplication.sharedApplication.connectedScenes.anyObject ? ((UIWindowScene *)UIApplication.sharedApplication.connectedScenes.anyObject).windows : @[]) {
        if (!window.hidden && [NSStringFromClass(window.rootViewController.class) isEqualToString:@"SGRLandscapeLyricsController"]) return window.rootViewController;
    }
    return nil;
}

// What a touch on the lines lands on, and whether the controls are up.
static void logLandscape(NSString *step, NSString *want) {
    UIViewController *screen = landscapeScreen();
    UIView *view = screen.view, *shield = [screen valueForKey:@"shield"];
    CGPoint onLine = CGPointMake(view.bounds.size.width * 0.7, view.bounds.size.height * 0.5);
    UIView *hit = [view hitTest:onLine withEvent:nil];
    CGFloat controls = [[screen valueForKey:@"controls"] alpha];
    NSString *got = hit == shield ? @"shield" : @"lines";
    NSLog(@"[harness] landscape %@: controls %.0f, a touch on the lines lands on %@ (%@) -- want %@: %@", step, controls,
          got, NSStringFromClass(hit.class), want, [got isEqualToString:want] ? @"ok" : @"WRONG");
}

// The landscape lyrics as a turned phone shows them: a line's meanings over them as a card on the bottom
// edge, the controls staying up behind the sheet and fading once it is gone, the shield taking the touch
// that brings them back, and a pause and a resume from elsewhere starting the clock again.
- (void)runLandscape {
    after(3, ^{ SGRPlayerShowLandscape(YES); });
    // The window comes up clear and fades in with the turn; it and what it presents are dark; the
    // controls say what they do and are 44pt.
    after(3.05, ^{
        UIWindow *window = landscapeScreen().view.window;
        NSLog(@"[harness] landscape window as it comes up: alpha %.2f -- want under 1: %@", window.alpha, window.alpha < 1 ? @"ok" : @"WRONG");
    });
    after(3.9, ^{
        UIViewController *screen = landscapeScreen();
        UIWindow *window = screen.view.window;
        NSLog(@"[harness] landscape window: alpha %.2f, %@ -- want 1, dark: %@", window.alpha,
              window.overrideUserInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"not dark",
              window.alpha == 1 && window.overrideUserInterfaceStyle == UIUserInterfaceStyleDark ? @"ok" : @"WRONG");
        NSMutableArray<UIButton *> *buttons = [[[screen valueForKey:@"controls"] arrangedSubviews] mutableCopy];
        [buttons addObject:[screen valueForKey:@"_close"]];
        for (UIButton *button in buttons) {
            BOOL ok = button.accessibilityLabel.length && button.bounds.size.width >= 44 && button.bounds.size.height >= 44;
            NSLog(@"[harness] landscape button \"%@\" %@ -- want a label, 44pt: %@", button.accessibilityLabel,
                  NSStringFromCGSize(button.bounds.size), ok ? @"ok" : @"WRONG");
        }
        UILabel *title = [screen valueForKey:@"_title"], *artist = [screen valueForKey:@"_artist"];
        NSLog(@"[harness] landscape text: title %.0fpt in %@, artist %.0fpt in %@, close %@", title.font.pointSize,
              NSStringFromCGRect(title.frame), artist.font.pointSize, NSStringFromCGRect(artist.frame),
              NSStringFromCGRect([[screen valueForKey:@"_close"] frame]));
    });
    after(4, ^{
        SGLyricsMeaning *meaning = [SGLyricsMeaning new];
        meaning.author = SGLyricsMeaningByArtist;
        meaning.body = @"A line of the harness's song, explained at the length Genius explains one, so the card has a body to show and to wrap.";
        meaning.url = @"https://genius.com";
        SGRShowMeanings(@"Harness line", @[meaning]);
    });
    after(6, ^{
        UIViewController *sheet = landscapeScreen().presentedViewController;
        UIView *window = sheet.view.window;
        NSLog(@"[harness] landscape meanings: %@ %@ in a window %@, height class %ld, edge attached %d",
              NSStringFromClass(sheet.class), NSStringFromCGRect([sheet.view convertRect:sheet.view.bounds toView:window]),
              NSStringFromCGSize(window.bounds.size), (long)sheet.traitCollection.verticalSizeClass,
              sheet.sheetPresentationController.prefersEdgeAttachedInCompactHeight);
    });
    after(8.5, ^{ logLandscape(@"with the sheet up past the rest", @"lines"); });
    after(9, ^{ [landscapeScreen() dismissViewControllerAnimated:YES completion:nil]; });
    after(14, ^{ logLandscape(@"rested after the sheet went", @"shield"); });
    after(14.5, ^{ SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), YES); });
    after(15, ^{ logLandscape(@"paused", @"lines"); });
    after(15.5, ^{ SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), NO); });
    after(17, ^{ logLandscape(@"just resumed", @"lines"); });
    after(21, ^{ logLandscape(@"rested after the resume", @"shield"); });
    // VoiceOver's escape turns the screen back, and the player is key once it has faded.
    after(22, ^{ NSLog(@"[harness] landscape escape answered %d", [landscapeScreen() accessibilityPerformEscape]); });
    after(23, ^{
        BOOL gone = !landscapeScreen(), key = self.window.isKeyWindow;
        NSLog(@"[harness] landscape after the escape: gone %d, the player key %d -- %@", gone, key, gone && key ? @"ok" : @"WRONG");
    });
}

#pragma mark - badge

// The hold's 2x badge: the Kit's glass capsule first in it with its effect on, the label over it, the
// glyph an attachment; a hold again while it fades out keeps it; let go, it goes.
- (void)runBadgeChecks {
    __block NSObject *hold = nil;
    for (UIGestureRecognizer *recognizer in _tilt.gestureRecognizers) {
        if ([NSStringFromClass(recognizer.class) isEqualToString:@"SGRCoverHold"]) hold = recognizer;
    }
    __block NSUInteger right = 0, checks = 0;
    void (^check)(NSString *, BOOL) = ^(NSString *step, BOOL ok) {
        checks++;
        if (ok) right++;
        NSLog(@"[harness] badge %@: %@", step, ok ? @"ok" : @"WRONG");
    };
    UIView *tilt = _tilt;
    UIView *(^badge)(void) = ^UIView *{ return [hold valueForKey:@"badge"]; };
    after(2, ^{ [hold showBadge:YES on:tilt]; });
    after(2.8, ^{
        UIView *shape = badge().subviews.firstObject;
        UILabel *label = [hold valueForKey:@"badgeLabel"];
        __block BOOL glyph = NO;
        [label.attributedText enumerateAttribute:NSAttachmentAttributeName inRange:NSMakeRange(0, label.attributedText.length) options:0
                                      usingBlock:^(id value, NSRange range, BOOL *stop) { if (value) glyph = YES; }];
        check(@"up", badge().superview == tilt && [shape isKindOfClass:UIVisualEffectView.class]
              && ((UIVisualEffectView *)shape).effect && label.superview == badge() && label.alpha == 1
              && CGAffineTransformIsIdentity(badge().transform) && glyph);
        NSLog(@"[harness] badge %@ with %@ (%@), label %@ fits %d", NSStringFromCGRect(badge().frame), NSStringFromClass(shape.class),
              NSStringFromClass([(UIVisualEffectView *)shape effect].class), label.attributedText.string,
              label.intrinsicContentSize.width <= badge().bounds.size.width);
        [hold showBadge:NO on:tilt];
    });
    after(2.85, ^{ [hold showBadge:YES on:tilt]; });
    after(3.5, ^{
        check(@"held again while it faded", badge().superview == tilt && [(UIVisualEffectView *)badge().subviews.firstObject effect]);
        [hold showBadge:NO on:tilt];
    });
    after(4, ^{
        check(@"let go", !badge().superview);
        NSLog(@"[harness] badge checks: %lu of %lu right -- %@", (unsigned long)right, (unsigned long)checks, right == checks ? @"PASS" : @"FAIL");
    });
}

- (void)check:(NSString *)step want:(NSString *)want {
    NSString *uri = nil;
    UIImage *artwork = SGRNowPlayingArtwork(&uri, NULL);
    UIImage *drawn = [SGRPlayerField() valueForKey:@"image"];
    NSString *kit = colorName(artwork), *field = colorName(drawn);
    BOOL ok = [kit isEqualToString:want] && [field isEqualToString:want];
    _checks++;
    if (!ok) _failures++;
    NSLog(@"[harness] check %@: want %@, the Kit has %@ (for %@), the field draws %@ -- %@", step, want, kit, uri, field, ok ? @"ok" : @"WRONG");
}

// Issue #58: after a switch to another album the field kept the last one's picture until the next track.
- (void)runArtworkChecks {
    UIImage *green = solid(UIColor.greenColor), *blue = solid(UIColor.blueColor), *yellow = solid(UIColor.yellowColor),
            *magenta = solid(UIColor.magentaColor);
    after(1.5, ^{ [self check:@"1 first track" want:@"red"]; });

    // Another album: the screens go on showing the last picture for 3.5 s, well past the Kit's last look
    // at them, and the picture server answers in 1 s.
    after(2, ^{
        serve(imageURI(@"bbbb"), green, 1.0, NO);
        [self playTrack:@"spotify:track:harnessB" image:imageURI(@"bbbb")];
    });
    after(5.5, ^{ [self showOnScreen:green]; });
    after(7, ^{ [self check:@"2 album switch, the screens late" want:@"green"]; });

    // Two tracks in quick succession, the first one's picture answering last.
    after(7.5, ^{
        serve(imageURI(@"cccc"), blue, 2.0, NO);
        [self playTrack:@"spotify:track:harnessC" image:imageURI(@"cccc")];
    });
    after(7.7, ^{ [self showOnScreen:blue]; });
    after(7.8, ^{
        serve(imageURI(@"dddd"), yellow, 0.3, NO);
        [self playTrack:@"spotify:track:harnessD" image:imageURI(@"dddd")];
    });
    after(8.1, ^{ [self showOnScreen:yellow]; });
    after(11, ^{ [self check:@"3 skip twice, the older answer last" want:@"yellow"]; });

    // Offline: the server fails, and the screens show the new picture 0.8 s after the change.
    after(11.5, ^{
        serve(imageURI(@"eeee"), magenta, 0.1, YES);
        [self playTrack:@"spotify:track:harnessE" image:imageURI(@"eeee")];
    });
    after(12.3, ^{ [self showOnScreen:magenta]; });
    after(14.5, ^{ [self check:@"4 offline, the screens only" want:@"magenta"]; });

    after(15, ^{
        NSLog(@"[harness] artwork checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

// Up must be taken back to the top, down (the dismissal's pull) left where it went.
#pragma mark - Animated artwork

BOOL SGPlayerMenuAnimatedArtwork(void);
void SGPlayerMenuSetAnimatedArtwork(BOOL on);

static UIView *motionView(void) {
    for (UIView *view in SGRPlayerField().subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"SGRPlayerMotionView"]) return view;
    }
    return nil;
}

- (void)expect:(BOOL)ok step:(NSString *)step detail:(NSString *)detail {
    _checks++;
    if (!ok) _failures++;
    NSLog(@"[harness] %@ check %@: %@ -- %@", scenario(), step, detail, ok ? @"ok" : @"WRONG");
}

// The field covered by the clip, and its Fluid copies hidden for it.
static BOOL fieldCovered(void) {
    SGRArtworkField *field = SGRPlayerField();
    CALayer *fluid = [field valueForKey:@"_fluidLayer"];
    return field.covered && fluid && fluid.hidden;
}

- (void)runMotionChecks {
    // The clip comes in before the player has laid out, as for the track restored at launch.
    after(3, ^{
        [self expect:SGRPlayerMotionShowing() && !SGRPlayerField() step:@"before the player opened"
              detail:[NSString stringWithFormat:@"clip %@, field %@", SGRPlayerMotionShowing() ? @"in" : @"missing", SGRPlayerField() ? @"made" : @"not made"]];
    });
    after(4, ^{
        [self->_list insertSubview:self->_plane atIndex:0];
        self->_units = [self->_units arrayByAddingObject:self->_background];
        [self layOut];
    });
    after(5, ^{
        UIView *motion = motionView();
        CALayer *foot = [motion valueForKey:@"_foot"], *clip = [motion valueForKey:@"_clip"];
        UIVisualEffectView *seam = [motion valueForKey:@"_seamBlur"];
        // The lyrics' blur is a filter on the clip, there only while the lyrics are up.
        BOOL lyricsBlurred = ((UIView *)[motion valueForKey:@"_picture"]).layer.filters.count > 0;
        [self expect:motion != nil && self->_covers.layer.mask != nil step:@"the player opened"
              detail:[NSString stringWithFormat:@"clip %@ the field, cover %@", motion ? @"on" : @"not on", self->_covers.layer.mask ? @"hidden" : @"shown"]];
        CGFloat seamAt = round(clip.frame.size.height * 0.9);
        BOOL footDown = foot && fabs(foot.frame.origin.y - seamAt) < 1 && CGRectGetMaxY(foot.frame) >= self.window.bounds.size.height
            && foot.contents && foot.contentsRect.size.height < 0.05 && CGRectGetMaxY(foot.contentsRect) > 0.999;
        [self expect:footDown step:@"the foot"
              detail:[NSString stringWithFormat:@"clip %@, foot %@ from rows %@", NSStringFromCGRect(clip.frame), NSStringFromCGRect(foot.frame), NSStringFromCGRect(foot.contentsRect)]];
        // The poster under the video, so the clip has a picture before its first frame is decoded; and the
        // Fluid field under it held still and, the clip being opaque, hidden.
        CALayer *still = clip.superlayer;
        [self expect:still.contents && CGRectEqualToRect(still.bounds, clip.frame) && still.mask && SGRPlayerField().motionHeld
                     && fieldCovered()
                step:@"the poster and the held field"
              detail:[NSString stringWithFormat:@"poster %@ at %@, video %@, fade %@, field %@, %@", still.contents ? @"in" : @"missing",
                      NSStringFromCGRect(still.frame), NSStringFromCGRect(clip.frame), still.mask ? @"on the poster" : @"missing",
                      SGRPlayerField().motionHeld ? @"held" : @"moving", fieldCovered() ? @"its Fluid copies hidden" : @"its Fluid copies drawn"]];
        [self expect:seam.effect && !lyricsBlurred step:@"the blur from the seam"
              detail:[NSString stringWithFormat:@"seam blur %@, from %@ of the height, lyrics blur %@", seam.effect ? @"on" : @"off",
                      [[seam.maskView.layer.sublayers.firstObject valueForKey:@"locations"] componentsJoinedByString:@" to "], lyricsBlurred ? @"on" : @"off"]];
        // Dimmed by its brightness: HARNESS_DIM is what the clip in HARNESS_CANVAS_FILE should get (0.54 for white,
        // 0.10 for black); the rule itself is checked at its ends.
        CAGradientLayer *dim = [motion valueForKey:@"_dim"];
        // Only where text is: whole at the top and from the seam's blur down, clear between (issue #101).
        BOOL banded = dim && stopAlpha(dim, 1) == 1 && stopAlpha(dim, 2) == 0 && stopAlpha(dim, 4) == 1;
        const char *expected = getenv("HARNESS_DIM");
        BOOL rule = fabs(SGRPlayerClipDim(1, NO, NO) - 0.54) < 0.01 && fabs(SGRPlayerClipDim(1, YES, NO) - 0.65) < 0.01
                    && SGRPlayerClipDim(0, NO, NO) == 0.10 && fabs(SGRPlayerClipDim(0, NO, YES) - 0.25) < 1e-6
                    && fabs(SGRPlayerClipDim(0.5, NO, NO) - 0.37) < 0.01;
        self->_dimAlone = dim.opacity;
        [self expect:rule && banded && dim && dim.superlayer == clip.superlayer.superlayer && (!expected || fabs(dim.opacity - atof(expected)) < 0.02)
                step:@"the dim" detail:[NSString stringWithFormat:@"rule %@, dim %.2f %@%@", rule ? @"right" : @"wrong", dim.opacity,
                                        banded ? [NSString stringWithFormat:@"whole to %@ and from %@", dim.locations[1], dim.locations[4]] : @"not banded",
                                        expected ? [NSString stringWithFormat:@", %s expected", expected] : @""]];
        NSLog(@"[harness] motion: screenshot the clip now");
    });
    after(7, ^{ SGRPlayerToggleLyrics(); });
    after(8.5, ^{
        BOOL lyricsBlurred = ((UIView *)[motionView() valueForKey:@"_picture"]).layer.filters.count > 0;
        UIView *thumb = nil;
        for (UIView *view in self->_host.subviews) {
            if ([NSStringFromClass(view.class) isEqualToString:@"SGRPlayerLyricsOverlay"]) thumb = [view valueForKey:@"thumb"];
        }
        BOOL away = thumb && !CGAffineTransformIsIdentity(thumb.transform) && thumb.alpha > 0.99;
        CAGradientLayer *shade = [motionView() valueForKey:@"_dim"];
        float dim = shade.opacity;
        // The lyrics run down the whole screen, so the dim covers all of it.
        BOOL whole = shade && stopAlpha(shade, 2) == 1;
        [self expect:whole && fabsf(dim - self->_dimAlone - 0.15f) < 0.01f step:@"the dim under the lyrics"
              detail:[NSString stringWithFormat:@"%.2f, %.2f without them", dim, self->_dimAlone]];
        [self expect:SGRPlayerLyricsOpen() && lyricsBlurred && away step:@"the lyrics"
              detail:[NSString stringWithFormat:@"lyrics %@, clip blurred %@, thumbnail %@ at alpha %.2f", SGRPlayerLyricsOpen() ? @"up" : @"down",
                      lyricsBlurred ? @"yes" : @"no", thumb && !CGAffineTransformIsIdentity(thumb.transform) ? @"in its corner" : @"at the cover", thumb.alpha]];
        NSLog(@"[harness] motion: screenshot the lyrics now");
    });
    after(10, ^{ SGRPlayerToggleLyrics(); });
    // Spotify builds the player's background again: the clip goes onto the new field.
    after(11.5, ^{
        UIView *old = SGRPlayerField();
        UIView *plane = [[UIView alloc] initWithFrame:self->_plane.frame];
        UIViewController *background = [_TtC21NowPlaying_ScrollImpl27NPVBackgroundViewController new];
        background.view = plane;
        [self->_plane removeFromSuperview];
        [self->_list insertSubview:plane atIndex:0];
        self->_plane = plane;
        NSMutableArray *units = [self->_units mutableCopy];
        [units replaceObjectAtIndex:[units indexOfObject:self->_background] withObject:background];
        self->_units = units;
        self->_background = background;
        [self layOut];
        [self expect:SGRPlayerField() != old && motionView() != nil && fieldCovered() step:@"a field built again"
              detail:[NSString stringWithFormat:@"%@, its Fluid copies %@", motionView() ? @"the clip moved onto it" : @"the clip left behind",
                      fieldCovered() ? @"hidden" : @"drawn"]];
    });
    // Switched off, the clip and the cover cross over: the clip's fade out and the cover's fade in start
    // together, over the same time.
    after(12.5, ^{
        SGPlayerMenuSetAnimatedArtwork(NO);
        UIView *fading = motionView();
        CALayer *picture = ((UIView *)[fading valueForKey:@"_picture"]).layer, *mask = self->_covers.layer.mask;
        CAAnimation *out = [picture animationForKey:@"opacity"], *in = [mask animationForKey:@"opacity"];
        [self expect:!SGRPlayerMotionShowing() && fading && out && in && fabs(out.duration - in.duration) < 0.01 && picture.opacity == 0
                     && mask.opacity == 1 && !SGRPlayerField().motionHeld && !fieldCovered()
                step:@"switched off, crossing over"
              detail:[NSString stringWithFormat:@"clip %@ to %.0f over %.2f s, cover to %.0f over %.2f s, field %@, its Fluid copies %@", fading ? @"fading" : @"gone",
                      picture.opacity, out.duration, mask.opacity, in.duration, SGRPlayerField().motionHeld ? @"held" : @"moving",
                      fieldCovered() ? @"hidden" : @"drawn"]];
    });
    after(13.2, ^{
        [self expect:!SGRPlayerMotionShowing() && !motionView() && !self->_covers.layer.mask && !SGPlayerMenuAnimatedArtwork()
                step:@"switched off from the menu" detail:[NSString stringWithFormat:@"clip %@, cover %@", motionView() ? @"still there" : @"gone",
                                                                 self->_covers.layer.mask ? @"hidden" : @"back"]];
        SGPlayerMenuSetAnimatedArtwork(YES);
    });
    after(14.7, ^{
        // Faded in on screen this time, so the field is covered once the fade has finished.
        [self expect:motionView() && self->_covers.layer.mask && fieldCovered() step:@"switched on again"
              detail:[NSString stringWithFormat:@"clip %@, cover %@, its Fluid copies %@", motionView() ? @"back" : @"missing",
                      self->_covers.layer.mask ? @"hidden" : @"shown", fieldCovered() ? @"hidden" : @"drawn"]];
        // The player closed: the cover list cannot be found, and switching off must still bring its cover back.
        [self->_host removeFromSuperview];
        SGPlayerMenuSetAnimatedArtwork(NO);
        [self expect:!self->_covers.layer.mask step:@"switched off with the player closed" detail:self->_covers.layer.mask ? @"cover still hidden" : @"cover back"];
        [self->_list addSubview:self->_host];
    });
    after(15.7, ^{ SGPlayerMenuSetAnimatedArtwork(YES); });
    // The song paused and played again: the clip holds its frame, then moves on.
    after(17.2, ^{
        AVPlayer *player = [motionView() valueForKey:@"_player"];
        AVPlayerLayer *clip = [motionView() valueForKey:@"_clip"];
        [self expect:player.rate > 0 && clip.readyForDisplay step:@"playing" detail:[NSString stringWithFormat:@"clip at rate %.1f, %@", player.rate,
              clip.readyForDisplay ? @"drawn" : @"not drawn"]];
        SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), YES);
        AVPlayer *paused = [motionView() valueForKey:@"_player"];
        [self expect:motionView() && paused.rate == 0 step:@"paused" detail:[NSString stringWithFormat:@"clip %@ at rate %.1f",
              motionView() ? @"there" : @"gone", paused.rate]];
        SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), NO);
        [self expect:paused.rate > 0 step:@"played again" detail:[NSString stringWithFormat:@"rate %.1f", paused.rate]];
    });
    // Spotify's music video comes and goes: the clip goes for it, and comes back after.
    __block id video = nil;
    after(17.5, ^{
        video = [NSClassFromString(@"_TtC22NowPlaying_ElementsKit14VideoElementUI") new];
        [video videoSurfaceDidAttachVideo:nil];
    });
    after(18.5, ^{
        [self expect:!SGRPlayerMotionShowing() step:@"Spotify's video showing" detail:SGRPlayerMotionShowing() ? @"the clip stayed" : @"the clip went"];
        [video videoSurfaceDidDetachVideo:nil];
    });
    after(19.5, ^{
        [self expect:SGRPlayerMotionShowing() && self->_covers.layer.mask step:@"Spotify's video gone"
              detail:SGRPlayerMotionShowing() ? @"the clip back" : @"no clip"];
        // A track whose first state names no Canvas, as on a skip before Spotify's extended metadata.
        unsetenv("HARNESS_CANVAS");
        SGRHarnessSetTrack(@"spotify:track:harnessB", imageURI(@"bbbb"), NO);
    });
    after(20.5, ^{
        [self expect:!SGRPlayerMotionShowing() step:@"a track with no Canvas yet" detail:SGRPlayerMotionShowing() ? @"a clip left" : @"no clip"];
        setenv("HARNESS_CANVAS", "https://canvas.harness/clip.mp4", 1);
        SGRHarnessSetTrack(@"spotify:track:harnessB", imageURI(@"bbbb"), NO);
    });
    // A skip to a track whose clip is in the store: the clip stays for the next one to cross over it.
    __block UIView *before = nil;
    after(21.5, ^{
        [self expect:SGRPlayerMotionShowing() step:@"its Canvas came late" detail:SGRPlayerMotionShowing() ? @"the clip in" : @"no clip"];
        before = motionView();
        SGRHarnessSetTrack(@"spotify:track:harnessC", imageURI(@"cccc"), NO);
    });
    after(21.6, ^{
        [self expect:SGRPlayerMotionShowing() && self->_covers.layer.mask step:@"skipped, the clip kept a moment"
              detail:SGRPlayerMotionShowing() ? @"a clip in" : @"the cover back"];
    });
    after(22.3, ^{
        CALayer *mask = self->_covers.layer.mask;
        [self expect:SGRPlayerMotionShowing() && motionView() != before && mask && mask.opacity == 0 step:@"the next clip over the last"
              detail:[NSString stringWithFormat:@"%@, cover %@", motionView() != before ? @"a new clip" : @"the same clip", mask && mask.opacity == 0 ? @"still hidden" : @"back"]];
    });
    // Low Power Mode (Reduce Motion takes the same path): the clip goes for Fluid and the cover, and comes back
    // once it is off. The simulator has no Low Power Mode, so the process says it is on.
    __block BOOL lowPower = NO;
    after(22.5, ^{
        Class info = object_getClass(NSProcessInfo.processInfo);
        for (NSString *name in @[@"isLowPowerModeEnabled", @"lowPowerModeEnabled"]) {
            Method method = class_getInstanceMethod(info, NSSelectorFromString(name));
            if (method) method_setImplementation(method, imp_implementationWithBlock(^BOOL(id process) { return lowPower; }));
        }
        lowPower = YES;
        [NSNotificationCenter.defaultCenter postNotificationName:NSProcessInfoPowerStateDidChangeNotification object:nil];    });
    after(23.5, ^{
        [self expect:!SGRPlayerMotionShowing() && !motionView() && !self->_covers.layer.mask step:@"Low Power Mode"
              detail:[NSString stringWithFormat:@"clip %@, cover %@", motionView() ? @"still there" : @"gone", self->_covers.layer.mask ? @"hidden" : @"back"]];
        lowPower = NO;
        [NSNotificationCenter.defaultCenter postNotificationName:NSProcessInfoPowerStateDidChangeNotification object:nil];
    });
    // A track change with the app in the background: the last clip goes at once, with no fade to come back to.
    __block UIApplicationState state = UIApplicationStateActive;
    after(24.5, ^{
        [self expect:SGRPlayerMotionShowing() && self->_covers.layer.mask step:@"Low Power Mode off"
              detail:SGRPlayerMotionShowing() ? @"the clip back" : @"no clip"];
        Method method = class_getInstanceMethod(UIApplication.class, @selector(applicationState));
        method_setImplementation(method, imp_implementationWithBlock(^UIApplicationState(id app) { return state; }));
        state = UIApplicationStateBackground;
        unsetenv("HARNESS_CANVAS");
        SGRHarnessSetTrack(@"spotify:track:harnessD", imageURI(@"dddd"), NO);
    });
    after(24.6, ^{
        CALayer *mask = self->_covers.layer.mask;
        [self expect:!SGRPlayerMotionShowing() && !motionView() && !mask step:@"a track change in the background"
              detail:[NSString stringWithFormat:@"clip %@, cover %@", motionView() ? @"still there" : @"gone at once",
                      mask ? [NSString stringWithFormat:@"hidden, at %.2f", mask.opacity] : @"back at once"]];
        state = UIApplicationStateActive;
    });
    after(25, ^{
        NSLog(@"[harness] motion checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

#pragma mark - Apple Music's catalog

static NSData *catalogAlbums(NSArray<NSArray<NSString *> *> *albums) {
    NSMutableArray *data = [NSMutableArray array];
    for (NSArray<NSString *> *album in albums) {
        [data addObject:@{@"attributes": @{@"name": album[0], @"artistName": album[1],
                                           @"editorialVideo": @{@"motionTallVideo3x4": @{@"video": album[2]}}}}];
    }
    return [NSJSONSerialization dataWithJSONObject:@{@"results": @{@"albums": @{@"data": data}}} options:0 error:nil];
}

static NSString *termOf(NSURL *url) {
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"term"]) return item.value;
    }
    return nil;
}

// The album search's term without the edition, the album of the same name before another edition, and the pause
// after a 429: nothing asked of the catalog for the next album, which finds nothing at once.
- (void)runCatalogChecks {
    sg_catalogAsked = [NSMutableArray array];
    sg_canvasAsked = [NSMutableArray array];
    // A web player token that has not run out, so no browse page is read.
    NSString *(^part)(NSString *) = ^NSString *(NSString *json) {
        NSString *base = [[json dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
        return [[[base stringByReplacingOccurrencesOfString:@"+" withString:@"-"] stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                stringByReplacingOccurrencesOfString:@"=" withString:@""];
    };
    NSString *token = [NSString stringWithFormat:@"%@.%@.c2ln", part(@"{\"alg\":\"none\"}"), part(@"{\"iss\":\"AMPWebPlay\",\"exp\":4102444800}")];
    [NSUserDefaults.standardUserDefaults setObject:token forKey:@"spotifyglass.motion.token"];

    NSDictionary<NSString *, NSString *> *names = @{
        @"Abbey Road (Remastered)": @"Abbey Road", @"Rumours - 2004 Remaster": @"Rumours", @"[Deluxe]": @"[Deluxe]",
        @"Thriller 25 [Super Deluxe Edition] (Remastered)": @"Thriller 25", @"Midnights": @"Midnights",
    };
    __block BOOL namesRight = YES;
    [names enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *searched, BOOL *stop) {
        if (![SGMotionSearchName(name) isEqualToString:searched]) {
            namesRight = NO;
            NSLog(@"[harness] catalog: %@ searched as \"%@\", not \"%@\"", name, SGMotionSearchName(name), searched);
        }
    }];
    [self expect:namesRight step:@"search names" detail:namesRight ? @"editions taken off" : @"see above"];

    sg_catalogBody = catalogAlbums(@[@[@"Midnights", @"Taylor Swift", @"https://canvas.harness/standard.m3u8"],
                                     @[@"Midnights (3am Edition)", @"Taylor Swift", @"https://canvas.harness/3am.m3u8"]]);
    after(1, ^{ SGMotionAlbumCover(@"Taylor Swift", @"Midnights (3am Edition)", SGMotionTall, 600, ^(NSURL *file) {}); });
    after(2.5, ^{
        NSString *term = termOf(sg_catalogAsked.firstObject), *master = sg_canvasAsked.firstObject.lastPathComponent;
        [self expect:sg_catalogAsked.count == 1 && [term isEqualToString:@"Taylor Swift Midnights"] step:@"the term"
              detail:[NSString stringWithFormat:@"%lu asked, \"%@\"", (unsigned long)sg_catalogAsked.count, term]];
        [self expect:[master isEqualToString:@"3am.m3u8"] step:@"the album of the same name first" detail:master ?: @"none asked"];
        sg_catalogStatus = 429;
        SGMotionAlbumCover(@"Artist X", @"Album One", SGMotionTall, 600, ^(NSURL *file) {});
    });
    __block BOOL answered = NO;
    after(4, ^{
        [self expect:sg_catalogAsked.count == 2 step:@"a 429" detail:[NSString stringWithFormat:@"%lu asked", (unsigned long)sg_catalogAsked.count]];
        sg_catalogStatus = 200;
        SGMotionAlbumCover(@"Artist X", @"Album Two", SGMotionTall, 600, ^(NSURL *file) { answered = !file; });
    });
    after(5, ^{
        [self expect:sg_catalogAsked.count == 2 && answered step:@"paused after it"
              detail:[NSString stringWithFormat:@"%lu asked, the next album %@", (unsigned long)sg_catalogAsked.count, answered ? @"found nothing at once" : @"waits"]];
        NSLog(@"[harness] catalog checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

static UIView *firstOfClass(UIView *root, NSString *name) {
    if ([NSStringFromClass(root.class) isEqualToString:name]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = firstOfClass(sub, name);
        if (found) return found;
    }
    return nil;
}

// The Player page over the player, its card checked for each background the segmented control picks.
- (void)runSettingsChecks {
    __block UINavigationController *nav;
    __block CGFloat headerHeight = 0;
    UITableView *(^table)(void) = ^{ return ((UITableViewController *)nav.topViewController).tableView; };
    UIView *(^showcase)(void) = ^{ return firstOfClass(table().tableHeaderView, @"SGRPlayerShowcase"); };
    UISegmentedControl *(^control)(void) = ^{ return (UISegmentedControl *)firstOfClass(table().tableHeaderView, @"UISegmentedControl"); };
    // A segment picked as a tap on it does.
    void (^pick)(NSUInteger) = ^(NSUInteger index) {
        UISegmentedControl *segments = control();
        segments.selectedSegmentIndex = (NSInteger)index;
        [segments sendActionsForControlEvents:UIControlEventValueChanged];
    };
    void (^expectBackground)(NSString *, BOOL, BOOL, BOOL, BOOL) = ^(NSString *step, BOOL fluid, BOOL flows, BOOL clip, BOOL hills) {
        UIView *view = showcase();
        SGRArtworkField *field = (SGRArtworkField *)firstOfClass(view, @"SGRArtworkField");
        UIView *motion = firstOfClass(view, @"SGRPlayerMotionView"), *visualiser = firstOfClass(view, @"SGRVisualiserView");
        UIView *cover = [view valueForKey:@"_cover"];
        UILabel *note = [nav.topViewController valueForKey:@"_note"];
        NSInteger rows = [table() numberOfRowsInSection:0];
        CGFloat height = table().tableHeaderView.bounds.size.height;
        BOOL ok = field && field.fluid == fluid && field.flows == flows && (motion != nil) == clip && (visualiser != nil) == hills
                  && field.motionHeld == (clip || hills) && !cover.hidden && rows == (clip ? 2 : 0)
                  && note.text.length && (headerHeight == 0 || fabs(height - headerHeight) < 0.5);
        headerHeight = height;
        [self expect:ok step:step detail:[NSString stringWithFormat:@"field %@ fluid %d flows %d held %d, clip %@, hills %@, cover %@, %ld rows over the Mini player (%@), header %.0f, note \"%@\"",
                                          field ? @"in" : @"missing", field.fluid, field.flows, field.motionHeld, motion ? @"on" : @"off", visualiser ? @"on" : @"off", cover.hidden ? @"hidden" : @"shown",
                                          (long)rows, view.accessibilityValue, height, note.text]];
    };
    // The clip is in by 3 s (the motion scenario's first step), and the page opens over the player then.
    after(3, ^{
        nav = [[UINavigationController alloc] initWithRootViewController:SGRPlayerSettingsPage(@[])];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.window.rootViewController presentViewController:nav animated:NO completion:nil];
    });
    after(4, ^{
        UIView *view = showcase();
        UISegmentedControl *segments = control();
        CGRect card = view.frame, header = table().tableHeaderView.frame;
        BOOL shaped = view.window && card.size.width > card.size.height && card.size.width > header.size.width - 48;
        // Every segment's title whole: the widest, Visualizer's, is not cut short.
        BOOL whole = YES;
        for (UILabel *label in [self labelsIn:segments]) whole = whole && label.intrinsicContentSize.width <= label.bounds.size.width + 0.5;
        [self expect:shaped && segments.numberOfSegments == 5 && whole && CGRectGetMinY(segments.frame) > CGRectGetMaxY(card)
                step:@"the card leads the page, the five backgrounds under it, their names whole"
              detail:[NSString stringWithFormat:@"card %@ in a header of %@, control %@ with %ld segments", NSStringFromCGRect(card),
                      NSStringFromCGRect(header), NSStringFromCGRect(segments.frame), (long)segments.numberOfSegments]];
        NSInteger sections = table().numberOfSections;
        [self expect:sections == 2 && [table() numberOfRowsInSection:1] == 3 step:@"the Mini player section on the page"
              detail:[NSString stringWithFormat:@"%ld sections, %ld rows in the second", (long)sections, (long)[table() numberOfRowsInSection:1]]];
        expectBackground(@"Animated", YES, NO, YES, NO);
        pick(2);
    });
    after(5, ^{ expectBackground(@"Fluid", YES, NO, NO, NO); pick(1); });
    after(6, ^{ expectBackground(@"Colors", NO, YES, NO, NO); pick(0); });
    after(7, ^{ expectBackground(@"Still", NO, NO, NO, NO); pick(4); });
    after(8, ^{
        expectBackground(@"Visualizer", YES, NO, NO, YES);
        NSLog(@"[harness] settings: screenshot the Visualizer card now");
    });
    // Held a little longer, so the screenshot catches it.
    after(10, ^{ pick(3); });
    after(11, ^{
        expectBackground(@"Animated again", YES, NO, YES, NO);
        NSLog(@"[harness] settings checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

// The Player page opened with the player showing no clip, Animated picked on it: the card looks the clip up.
- (void)runPreviewChecks {
    __block UINavigationController *nav;
    UIView *(^showcase)(void) = ^{
        return firstOfClass(((UITableViewController *)nav.topViewController).tableView.tableHeaderView, @"SGRPlayerShowcase");
    };
    void (^pick)(NSUInteger) = ^(NSUInteger index) {
        UISegmentedControl *segments = (UISegmentedControl *)firstOfClass(showcase().superview, @"UISegmentedControl");
        segments.selectedSegmentIndex = (NSInteger)index;
        [segments sendActionsForControlEvents:UIControlEventValueChanged];
    };
    NSString *(^card)(void) = ^{
        UIView *view = showcase();
        SGRArtworkField *field = (SGRArtworkField *)firstOfClass(view, @"SGRArtworkField");
        UIView *motion = firstOfClass(view, @"SGRPlayerMotionView");
        CALayer *still = [motion valueForKey:@"_still"];
        return [NSString stringWithFormat:@"card: clip %@ (poster %@), field fluid %d held %d; the player's clip %@; the clip served %lu times",
                motion ? @"in" : @"out", still.contents ? @"drawn" : @"none", field.fluid, field.motionHeld, SGRPlayerMotionShowing() ? @"in" : @"none",
                (unsigned long)sg_canvasServed];
    };
    BOOL (^clipIn)(void) = ^{ return (BOOL)(firstOfClass(showcase(), @"SGRPlayerMotionView") != nil); };
    after(1, ^{
        [self expect:sg_canvasServed == 0 && !SGRPlayerMotionShowing() step:@"before the page, nothing asked for"
              detail:[NSString stringWithFormat:@"the clip served %lu times, the player's clip %@", (unsigned long)sg_canvasServed, SGRPlayerMotionShowing() ? @"in" : @"none"]];
        nav = [[UINavigationController alloc] initWithRootViewController:SGRPlayerSettingsPage(@[])];
        nav.modalPresentationStyle = UIModalPresentationFullScreen;
        [self.window.rootViewController presentViewController:nav animated:NO completion:nil];
    });
    after(2, ^{
        [self expect:!clipIn() && sg_canvasServed == 0 step:@"Still on the page, nothing asked for" detail:card()];
        pick(3);
    });
    after(2.5, ^{
        SGRArtworkField *field = (SGRArtworkField *)firstOfClass(showcase(), @"SGRArtworkField");
        [self expect:!clipIn() && field.fluid step:@"Animated picked, Fluid while the clip comes" detail:card()];
    });
    after(6, ^{
        SGRArtworkField *field = (SGRArtworkField *)firstOfClass(showcase(), @"SGRArtworkField");
        CALayer *still = [firstOfClass(showcase(), @"SGRPlayerMotionView") valueForKey:@"_still"];
        [self expect:clipIn() && still.contents && field.motionHeld && sg_canvasServed == 1 && !SGRPlayerMotionShowing()
                step:@"the clip in the card, the player left alone" detail:card()];
        NSLog(@"[harness] preview: screenshot the card now");
        // The player's walk asks the store the same way: it finds the file without asking the server again.
        SGMotionFile([NSURL URLWithString:@(getenv("HARNESS_CANVAS"))], ^(NSURL *file) {
            [self expect:file && sg_canvasServed == 1 step:@"the clip in the store for the player"
                  detail:[NSString stringWithFormat:@"%@, served %lu times", file.lastPathComponent ?: @"no file", (unsigned long)sg_canvasServed]];
        });
    });
    after(8, ^{ pick(2); });
    after(8.5, ^{
        [self expect:!clipIn() step:@"Fluid picked, the clip out" detail:card()];
        pick(3);
        [self expect:clipIn() && sg_canvasServed == 1 step:@"Animated again, the clip at once" detail:card()];
    });
    after(9.5, ^{
        NSLog(@"[harness] preview checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

- (NSArray<UILabel *> *)labelsIn:(UIView *)view {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:UILabel.class]) [labels addObject:(UILabel *)sub];
        [labels addObjectsFromArray:[self labelsIn:sub]];
    }
    return labels;
}

#pragma mark - the Visualizer

BOOL SGRHarnessReading(void);

static UIView *visualiserView(void) {
    for (UIView *view in SGRPlayerField().subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"SGRVisualiserView"]) return view;
    }
    return nil;
}

// The tallest a hill stands over the screen's foot, in points, from its path's bounding box.
static CGFloat hillHeight(UIView *view, NSString *ivar) {
    CAShapeLayer *shape = [view valueForKey:ivar];
    if (!shape.path) return 0;
    return view.bounds.size.height > 0 ? [[view valueForKey:@"baseline"] doubleValue] - CGPathGetPathBoundingBox(shape.path).origin.y : 0;
}

- (void)runVisualiserChecks {
    after(3, ^{
        UIView *hills = visualiserView();
        CADisplayLink *link = [hills valueForKey:@"_link"];
        CGFloat front = hillHeight(hills, @"_frontShape"), back = hillHeight(hills, @"_backShape");
        [self expect:hills && SGRPlayerVisualiserShowing() && SGRPlayerField().fluid && SGRPlayerField().motionHeld && link && SGRHarnessReading() && front > 40
                step:@"playing"
              detail:[NSString stringWithFormat:@"hills %@, field fluid %d held %d, link %@ at up to %.0f fps, reader %@, front %.0f pt, back %.0f pt",
                      hills ? @"on the field" : @"missing", SGRPlayerField().fluid, SGRPlayerField().motionHeld, link ? @"running" : @"stopped",
                      link.preferredFrameRateRange.maximum, SGRHarnessReading() ? @"on" : @"off", front, back]];
        NSLog(@"[harness] visualizer: screenshot the hills now");
    });
    after(4, ^{ SGRPlayerToggleLyrics(); });
    after(5.5, ^{
        UIView *hills = visualiserView();
        UIVisualEffectView *blur = [hills valueForKey:@"_lyricsBlur"];
        CADisplayLink *link = [hills valueForKey:@"_link"];
        [self expect:SGRPlayerLyricsOpen() && blur.effect && link.preferredFrameRateRange.maximum == 30 step:@"behind the lyrics"
              detail:[NSString stringWithFormat:@"lyrics %@, blur %@, link at up to %.0f fps", SGRPlayerLyricsOpen() ? @"up" : @"down",
                      blur.effect ? @"on" : @"off", link.preferredFrameRateRange.maximum]];
        NSLog(@"[harness] visualizer: screenshot the lyrics now");
    });
    after(6.5, ^{ SGRPlayerToggleLyrics(); });
    after(7.5, ^{ SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), YES); });
    after(8, ^{
        CADisplayLink *link = [visualiserView() valueForKey:@"_link"];
        [self expect:link && !SGRHarnessReading() step:@"paused, settling"
              detail:[NSString stringWithFormat:@"link %@, reader %@", link ? @"still running" : @"stopped", SGRHarnessReading() ? @"on" : @"off"]];
    });
    after(12, ^{
        UIView *hills = visualiserView();
        CADisplayLink *link = [hills valueForKey:@"_link"];
        CGFloat front = hillHeight(hills, @"_frontShape");
        [self expect:!link && !SGRHarnessReading() && front < 15 step:@"paused, settled"
              detail:[NSString stringWithFormat:@"link %@, reader %@, front %.0f pt", link ? @"running" : @"stopped", SGRHarnessReading() ? @"on" : @"off", front]];
        NSLog(@"[harness] visualizer: screenshot the paused hills now");
        SGRHarnessSetTrack(@"spotify:track:harnessA", imageURI(@"aaaa"), NO);
    });
    after(13.5, ^{
        UIView *hills = visualiserView();
        [self expect:[hills valueForKey:@"_link"] && SGRHarnessReading() && hillHeight(hills, @"_frontShape") > 40 step:@"playing again"
              detail:[NSString stringWithFormat:@"front %.0f pt", hillHeight(hills, @"_frontShape")]];
        SGRPlayerMenuSetBackground(SGRPlayerBackgroundFluid);
    });
    after(14.2, ^{
        [self expect:!visualiserView() && !SGRPlayerVisualiserShowing() && !SGRPlayerField().motionHeld && !SGRHarnessReading()
                step:@"switched to Fluid from the menu"
              detail:[NSString stringWithFormat:@"hills %@, field %@, reader %@", visualiserView() ? @"still there" : @"gone",
                      SGRPlayerField().motionHeld ? @"held" : @"moving", SGRHarnessReading() ? @"on" : @"off"]];
        SGRPlayerMenuSetBackground(SGRPlayerBackgroundVisualiser);
    });
    after(15.5, ^{
        UIView *hills = visualiserView();
        [self expect:hills && SGRPlayerField().motionHeld && SGRHarnessReading() && hillHeight(hills, @"_frontShape") > 40 step:@"back from the menu"
              detail:[NSString stringWithFormat:@"hills %@, field %@, front %.0f pt", hills ? @"on the field" : @"missing",
                      SGRPlayerField().motionHeld ? @"held" : @"moving", hillHeight(hills, @"_frontShape")]];
        NSLog(@"[harness] visualizer checks: %lu of %lu right -- %@", (unsigned long)(self->_checks - self->_failures), (unsigned long)self->_checks,
              self->_failures ? @"FAIL" : @"PASS");
    });
}

- (void)runScrollChecks {
    after(2, ^{
        UIScrollView *list = self->_list;
        CGFloat top = -list.adjustedContentInset.top;
        list.contentOffset = CGPointMake(0, top + 120);
        BOOL up = list.contentOffset.y == top;
        list.contentOffset = CGPointMake(0, top - 80);
        BOOL down = list.contentOffset.y == top - 80;
        [list setContentOffset:CGPointMake(0, top + 300) animated:NO];
        BOOL again = list.contentOffset.y == top;
        list.contentOffset = CGPointMake(0, top);
        NSLog(@"[harness] scroll checks: up %@, down %@, again %@ -- %@", up ? @"held" : @"moved", down ? @"kept" : @"lost",
              again ? @"held" : @"moved", up && down && again ? @"PASS" : @"FAIL");
    });
    // Issue #172: the list's pan is off while the progress bar is scrubbed, back once the scrub ends however
    // it ends, and a pan that was off already stays off.
    after(3, ^{
        UIView *duration = self->_units[1].view;
        UISlider *slider = [[_TtCO17NowPlaying_ECMKit11ProgressBar6Slider alloc] initWithFrame:CGRectMake(24, 0, duration.bounds.size.width - 48, 20)];
        slider.hidden = YES;
        [duration addSubview:slider];
        UIPanGestureRecognizer *pan = self->_list.panGestureRecognizer;
        UITouch *none = nil;   // the mock tracks without one
        NSMutableArray<NSString *> *wrong = [NSMutableArray array];
        void (^expect)(NSString *, BOOL) = ^(NSString *step, BOOL ok) { if (!ok) [wrong addObject:step]; };
        [slider beginTrackingWithTouch:none withEvent:nil];
        expect(@"held while scrubbing", !pan.enabled);
        [slider endTrackingWithTouch:none withEvent:nil];
        expect(@"back at the end", pan.enabled);
        [slider beginTrackingWithTouch:none withEvent:nil];
        [slider cancelTrackingWithEvent:nil];
        expect(@"back at a cancel", pan.enabled);
        [slider beginTrackingWithTouch:none withEvent:nil];
        [slider removeFromSuperview];
        expect(@"back when the slider left the window", pan.enabled);
        [duration addSubview:slider];
        pan.enabled = NO;
        [slider beginTrackingWithTouch:none withEvent:nil];
        [slider endTrackingWithTouch:none withEvent:nil];
        expect(@"off already, left off", !pan.enabled);
        pan.enabled = YES;
        [slider removeFromSuperview];
        NSLog(@"[harness] scrub checks: %@ -- %@", wrong.count ? [wrong componentsJoinedByString:@", "] : @"all right",
              wrong.count ? @"FAIL" : @"PASS");
    });
}

#pragma mark - the cover's room

// Issue #77: Spotify keeps room for the lyric preview under the cover of a track with lyrics, so the cover
// was smaller and higher with a blank band under it. Here the cover is untouched first (a track without
// lyrics), then given Spotify's layout for one with lyrics, and must fill its room again.
- (void)runCoverChecks {
    __block NSUInteger right = 0, checks = 0;
    void (^check)(NSString *, BOOL, NSString *) = ^(NSString *step, BOOL ok, NSString *detail) {
        checks++;
        if (ok) right++;
        NSLog(@"[harness] cover %@: %@ -- %@", step, detail, ok ? @"ok" : @"WRONG");
    };
    UIView *tilt = _tilt, *room = tilt.superview;
    UIView *preview = nil;
    for (UIView *view in room.subviews) {
        if ([view isKindOfClass:_TtC22Lyrics_NPVContainerKit19LyricsContainerView.class]) preview = view;
    }
    CGFloat side = MIN(room.bounds.size.width, room.bounds.size.height);
    CGRect square = CGRectMake(round((room.bounds.size.width - side) / 2), round((room.bounds.size.height - side) / 2), side, side);
    after(1.5, ^{
        check(@"without lyrics", CGRectEqualToRect(tilt.frame, square), NSStringFromCGRect(tilt.frame));
        NSLog(@"[harness] cover: screenshot without lyrics now");
    });
    after(2, ^{
        // What Spotify does for a track with lyrics: the preview under the cover, the cover shrunk above it.
        CGFloat small = side - 72;
        tilt.frame = CGRectMake(round((room.bounds.size.width - small) / 2), 0, small, small);
        preview.frame = CGRectMake(0, small + 8, room.bounds.size.width, 64);
        [preview invalidateIntrinsicContentSize];
        [self->_covers setNeedsLayout];
        [self->_covers layoutIfNeeded];
    });
    after(2.5, ^{
        check(@"the preview takes no room", CGSizeEqualToSize(preview.frame.size, CGSizeZero)
              && CGSizeEqualToSize(preview.intrinsicContentSize, CGSizeZero) && CGSizeEqualToSize([preview sizeThatFits:room.bounds.size], CGSizeZero),
              [NSString stringWithFormat:@"frame %@, intrinsic %@", NSStringFromCGRect(preview.frame), NSStringFromCGSize(preview.intrinsicContentSize)]);
        check(@"with lyrics, the cover fills its room", CGRectEqualToRect(tilt.frame, square), NSStringFromCGRect(tilt.frame));
        CGRect drawn = SGRPlayerCoverFrameIn(room);
        check(@"the Kit sees it", CGRectEqualToRect(CGRectIntegral(drawn), square),
              [NSString stringWithFormat:@"%@, the picture %@", NSStringFromCGRect(drawn), NSStringFromCGSize(self->_cover.bounds.size)]);
        NSLog(@"[harness] cover: screenshot with lyrics now");
    });
    after(3, ^{
        NSLog(@"[harness] cover checks: %lu of %lu right -- %@", (unsigned long)right, (unsigned long)checks, right == checks ? @"PASS" : @"FAIL");
    });
}

#pragma mark - the lines on their own

static UIView *lyricsOverlay(UIView *host) {
    for (UIView *view in host.subviews) {
        if ([NSStringFromClass(view.class) isEqualToString:@"SGRPlayerLyricsOverlay"]) return view;
    }
    return nil;
}

// Whether the lines' own tap, the one that seeks, is on.
static BOOL linesSeek(SGRKaraokeView *lyrics) {
    BOOL on = NO;
    for (UIGestureRecognizer *recognizer in lyrics.gestureRecognizers) {
        if ([recognizer isKindOfClass:UITapGestureRecognizer.class]) on = on || recognizer.enabled;
    }
    return on;
}

// The lyrics up and left alone past the rest: only the controls under them fade, the lines grow down into
// their room and still scroll, a tap brings the controls back and is not a seek, a scroll hides them again
// and the thumbnail closes the lyrics from there.
- (void)runImmersiveChecks {
    __block NSUInteger right = 0, checks = 0;
    void (^check)(NSString *, BOOL, NSString *) = ^(NSString *step, BOOL ok, NSString *detail) {
        checks++;
        if (ok) right++;
        NSLog(@"[harness] immersive %@: %@ -- %@", step, detail, ok ? @"ok" : @"WRONG");
    };
    UIView *host = _host;
    UIView *info = _units[0].view, *duration = _units[1].view, *playback = _units[3].view, *footer = _units[4].view;
    UIGestureRecognizer *wake = nil;
    for (UIGestureRecognizer *recognizer in host.gestureRecognizers) {
        if ([NSStringFromClass(recognizer.class) isEqualToString:@"SGRPlayerWake"]) wake = recognizer;
    }
    __block CGRect withControls = CGRectNull;
    UIView *(^stage)(void) = ^UIView *{ return [lyricsOverlay(host) valueForKey:@"stage"]; };
    SGRKaraokeView *(^lines)(void) = ^SGRKaraokeView *{ return [lyricsOverlay(host) valueForKey:@"lyrics"]; };
    // Everything in the bottom stack but the title row and the chips: the volume row too, where there is one.
    NSMutableArray<UIView *> *lower = [NSMutableArray array];
    for (UIView *view in info.superview.subviews) {
        if (view != info && view != self->_units[2].view) [lower addObject:view];
    }
    BOOL (^lowerHidden)(void) = ^BOOL { for (UIView *v in lower) if (v.alpha != 0) return NO; return lower.count >= 3; };
    BOOL (^lowerShown)(void) = ^BOOL { for (UIView *v in lower) if (v.alpha != 1) return NO; return lower.count >= 3; };

    after(1.5, ^{ SGRPlayerToggleLyrics(); });
    after(3, ^{
        withControls = [host convertRect:stage().bounds fromView:stage()];
        check(@"open, with the controls", SGRPlayerLyricsOpen() && lowerShown() && !wake.enabled && linesSeek(lines()),
              [NSString stringWithFormat:@"lines %@, wake %d, lines seek %d", NSStringFromCGRect(withControls), wake.enabled, linesSeek(lines())]);
    });
    // kRest is 4 s from the open.
    after(7, ^{
        UIView *thumb = [lyricsOverlay(host) valueForKey:@"thumb"];
        check(@"only the controls under the lines fade", lowerHidden() && info.alpha == 1 && thumb.alpha == 1,
              [NSString stringWithFormat:@"%lu views under the title row %@, progress %.0f, buttons %.0f, footer %.0f, title row %.0f, thumbnail %.0f",
               (unsigned long)lower.count, lowerHidden() ? @"faded" : @"not all faded", duration.alpha, playback.alpha, footer.alpha, info.alpha, thumb.alpha]);
        CGRect alone = [host convertRect:stage().bounds fromView:stage()];
        CGRect safe = UIEdgeInsetsInsetRect(host.bounds, host.safeAreaInsets);
        check(@"the lines grow down only", CGRectGetMinY(alone) == CGRectGetMinY(withControls) && CGRectGetMaxY(alone) > CGRectGetMaxY(withControls)
              && CGRectGetMaxY(alone) <= CGRectGetMaxY(safe),
              [NSString stringWithFormat:@"%@ from %@, safe area to %.0f", NSStringFromCGRect(alone), NSStringFromCGRect(withControls), CGRectGetMaxY(safe)]);
        // Where the buttons were, the lines now take the touch: a drag scrolls them.
        CGPoint onButtons = [host convertPoint:CGPointMake(CGRectGetMidX(playback.bounds), CGRectGetMidY(playback.bounds)) fromView:playback];
        UIView *hit = [host hitTest:onButtons withEvent:nil];
        check(@"a touch on the lines lands on them", [hit isDescendantOfView:lines()],
              [NSString stringWithFormat:@"%@", NSStringFromClass(hit.class)]);
        CGPoint onThumb = [host convertPoint:CGPointMake(CGRectGetMidX(thumb.bounds), CGRectGetMidY(thumb.bounds)) fromView:thumb];
        UIView *thumbHit = [host hitTest:onThumb withEvent:nil];
        check(@"the thumbnail takes its touch", [thumbHit isDescendantOfView:thumb], NSStringFromClass(thumbHit.class));
        check(@"a tap wakes, the lines do not seek", wake.enabled && !linesSeek(lines()),
              [NSString stringWithFormat:@"wake %d, lines seek %d", wake.enabled, linesSeek(lines())]);
        NSLog(@"[harness] immersive: screenshot alone now");
    });
    after(8, ^{
        [wake sgr_woke];
        // Off still for the rest of this turn of the run loop, which the tap that woke is part of.
        check(@"the waking tap does not seek", lowerShown() && !linesSeek(lines()),
              [NSString stringWithFormat:@"controls %.0f, lines seek %d", duration.alpha, linesSeek(lines())]);
    });
    after(8.5, ^{
        check(@"woken", lowerShown() && !wake.enabled && linesSeek(lines()),
              [NSString stringWithFormat:@"controls %.0f, wake %d, lines seek %d", duration.alpha, wake.enabled, linesSeek(lines())]);
        // A scroll through the lines leaves them alone at once.
        lines().browsingBegan();
        check(@"a scroll hides the controls", lowerHidden() && wake.enabled, [NSString stringWithFormat:@"controls %.0f", duration.alpha]);
    });
    after(9.5, ^{
        [lyricsOverlay(host) sgr_thumbTapped];
        check(@"the thumbnail closes the lyrics while alone", !SGRPlayerLyricsOpen() && lowerShown() && !wake.enabled,
              [NSString stringWithFormat:@"lyrics %@, controls %.0f", SGRPlayerLyricsOpen() ? @"up" : @"down", duration.alpha]);
    });
    // A sheet over the player keeps the controls up past the rest, and the clock runs again behind it, so
    // they fade within a rest of the sheet going.
    after(11.5, ^{ SGRPlayerToggleLyrics(); });
    __block UIViewController *sheet = nil;
    after(12, ^{
        sheet = [UIViewController new];
        sheet.view.backgroundColor = UIColor.darkGrayColor;
        [self.window.rootViewController presentViewController:sheet animated:NO completion:nil];
    });
    after(17, ^{
        check(@"a sheet keeps the controls up", SGRPlayerLyricsOpen() && lowerShown(), [NSString stringWithFormat:@"controls %.0f", duration.alpha]);
        [sheet dismissViewControllerAnimated:NO completion:nil];
    });
    after(22, ^{
        check(@"they fade once the sheet has gone", lowerHidden(), [NSString stringWithFormat:@"controls %.0f", duration.alpha]);
        // Sing's mic stays with the lines on their own, and takes its own touch.
        UIView *mic = nil;
        for (UIView *view in lines().subviews) {
            if ([NSStringFromClass(view.class) isEqualToString:@"SGRSingButton"]) mic = view;
        }
        CGPoint onMic = [host convertPoint:CGPointMake(CGRectGetMidX(mic.bounds), CGRectGetMidY(mic.bounds)) fromView:mic];
        UIView *hit = [host hitTest:onMic withEvent:nil];
        CGRect drawn = [host convertRect:mic.bounds fromView:mic];
        check(@"the mic stays and takes its touch", mic && ![[mic valueForKey:@"tucked"] boolValue] && mic.userInteractionEnabled && [hit isDescendantOfView:mic]
              && CGRectGetMaxY(drawn) > CGRectGetMaxY(withControls),
              [NSString stringWithFormat:@"mic %@ at %@, hit %@", mic ? @"there" : @"missing", NSStringFromCGRect(drawn), NSStringFromClass(hit.class)]);
        NSLog(@"[harness] immersive: screenshot the mic alone now");
    });
    after(28, ^{ [wake sgr_woke]; });
    // A finger held on the player (Sing's slider) holds the clock, and lifting it starts the clock over.
    __block UIGestureRecognizer *watcher = nil;
    after(28.5, ^{
        for (UIGestureRecognizer *recognizer in host.gestureRecognizers) {
            if ([NSStringFromClass(recognizer.class) isEqualToString:@"SGRPlayerTouchWatcher"]) watcher = recognizer;
        }
        [watcher touchesBegan:[NSSet set] withEvent:[UIEvent new]];
    });
    after(34, ^{
        check(@"a finger held keeps the controls up", watcher && lowerShown(), [NSString stringWithFormat:@"controls %.0f", duration.alpha]);
        [watcher reset];
    });
    after(39, ^{
        check(@"lifted, the clock runs out", lowerHidden(), [NSString stringWithFormat:@"controls %.0f", duration.alpha]);
    });
    after(40, ^{
        NSLog(@"[harness] immersive checks: %lu of %lu right -- %@", (unsigned long)right, (unsigned long)checks, right == checks ? @"PASS" : @"FAIL");
    });
}

#pragma mark - tap to seek

// The tap around the progress bar (PlayerControls.x): where it lands, what it maps to, and how it seeks. The
// slider is the mock's, given Spotify's identifier, with the two times beside it. A tap is the recognizer's
// action with its starting point set, since the harness cannot make a touch.
- (void)runSeekChecks {
    __block NSUInteger right = 0, checks = 0;
    void (^check)(NSString *, BOOL, NSString *) = ^(NSString *step, BOOL ok, NSString *detail) {
        checks++;
        if (ok) right++;
        NSLog(@"[harness] seek %@: %@ -- %@", step, detail, ok ? @"ok" : @"WRONG");
    };
    UIViewController *durationUnit = _units[1];
    UIView *unit = durationUnit.view;
    CGFloat W = unit.bounds.size.width;
    UISlider *slider = [[_TtCO17NowPlaying_ECMKit11ProgressBar6Slider alloc] initWithFrame:CGRectMake(24, 2, W - 48, 14)];
    slider.accessibilityIdentifier = @"SPTNowPlayingSliderV2";
    slider.value = 0.22;
    [unit addSubview:slider];
    UILabel *taken = [[UILabel alloc] initWithFrame:CGRectMake(24, 20, 44, 16)];
    taken.accessibilityIdentifier = @"now-playing-time-take-label";
    UILabel *remaining = [[UILabel alloc] initWithFrame:CGRectMake(W - 24 - 44, 20, 44, 16)];
    remaining.accessibilityIdentifier = @"now-playing-time-remaning-label";
    [unit addSubview:taken];
    [unit addSubview:remaining];
    [durationUnit viewDidLayoutSubviews];
    [SGPlayerState() setValue:@200 forKey:@"duration"];

    UIGestureRecognizer *tap = nil;
    for (UIGestureRecognizer *recognizer in unit.gestureRecognizers) {
        if ([NSStringFromClass(recognizer.class) isEqualToString:@"SGRSeekTap"]) tap = recognizer;
    }
    CGRect bar = slider.frame;
    CGRect thumb = [unit convertRect:[slider thumbRectForBounds:slider.bounds trackRect:[slider trackRectForBounds:slider.bounds] value:slider.value] fromView:slider];
    check(@"on the duration unit", tap != nil, tap ? @"a recognizer there" : @"none");
    check(@"under the bar", SGRSeekTapLands(unit, slider, CGPointMake(W / 2, CGRectGetMaxY(bar) + 12)), @"12pt below the bar");
    check(@"past the ends", SGRSeekTapLands(unit, slider, CGPointMake(CGRectGetMinX(bar) - 10, 8)) && SGRSeekTapLands(unit, slider, CGPointMake(CGRectGetMaxX(bar) + 10, 8))
          && !SGRSeekTapLands(unit, slider, CGPointMake(CGRectGetMinX(bar) - 20, 8)), @"10pt past either end, not 20");
    check(@"not on the thumb", !SGRSeekTapLands(unit, slider, CGPointMake(CGRectGetMidX(thumb), CGRectGetMidY(thumb))), NSStringFromCGRect(thumb));
    check(@"not on the times", !SGRSeekTapLands(unit, slider, taken.center) && !SGRSeekTapLands(unit, slider, remaining.center), @"either time");
    CGFloat end = SGRSeekShareAt(slider, CGPointMake(slider.bounds.size.width - 1, 7)), start = SGRSeekShareAt(slider, CGPointMake(1, 7));
    CGFloat middle = SGRSeekShareAt(slider, CGPointMake(slider.bounds.size.width / 2, 7));
    check(@"the ends are the song's", end == 1 && start == 0 && fabs(middle - 0.5) < 0.001,
          [NSString stringWithFormat:@"start %.3f, middle %.3f, end %.3f", start, middle, end]);

    // A tap at three quarters of the thumb's travel, played to the slider as a drag.
    NSMutableArray<NSNumber *> *events = [NSMutableArray array];
    __block BOOL answers = NO;
    for (NSNumber *event in @[@(UIControlEventTouchDown), @(UIControlEventValueChanged), @(UIControlEventTouchUpInside)]) {
        [slider addAction:[UIAction actionWithHandler:^(UIAction *action) {
            [events addObject:event];
            if (answers && event.unsignedIntegerValue == UIControlEventTouchUpInside) SGKaraokeSeek((NSInteger)(slider.value * 200000));
        }] forControlEvents:event.unsignedIntegerValue];
    }
    CGFloat from = CGRectGetMidX([slider thumbRectForBounds:slider.bounds trackRect:[slider trackRectForBounds:slider.bounds] value:0]);
    CGFloat to = CGRectGetMidX([slider thumbRectForBounds:slider.bounds trackRect:[slider trackRectForBounds:slider.bounds] value:1]);
    void (^tapAt)(CGFloat) = ^(CGFloat share) {
        CGPoint point = [unit convertPoint:CGPointMake(from + share * (to - from), 7) fromView:slider];
        [tap setValue:[NSValue valueWithCGPoint:point] forKey:@"start"];
        ((void (*)(id, SEL))objc_msgSend)(tap, NSSelectorFromString(@"sgr_seek"));
    };
    tapAt(0.75);
    NSArray *drag = @[@(UIControlEventTouchDown), @(UIControlEventValueChanged), @(UIControlEventTouchUpInside)];
    check(@"played as a drag", [events isEqualToArray:drag] && fabs(slider.value - 0.75) < 0.001 && slider.isTracking,
          [NSString stringWithFormat:@"%lu events, value %.3f, tracking %d", (unsigned long)events.count, slider.value, slider.isTracking]);
    // Nothing seeked for it: after a second the tap seeks directly, and the slider lets go.
    after(1.3, ^{
        NSInteger at = SGKaraokePositionMs();
        check(@"a drag that did not seek is seeked", labs(at - 150000) < 1000 && !slider.isTracking,
              [NSString stringWithFormat:@"at %ld ms, tracking %d", (long)at, slider.isTracking]);
        // Spotify seeking for the drag: the slider lets go as the position arrives.
        answers = YES;
        tapAt(0.3);
        NSInteger now = SGKaraokePositionMs();
        check(@"the slider lets go once the position is there", labs(now - 60000) < 1000 && !slider.isTracking,
              [NSString stringWithFormat:@"at %ld ms, tracking %d", (long)now, slider.isTracking]);
    });
    after(2.6, ^{
        NSLog(@"[harness] seek checks: %lu of %lu right -- %@", (unsigned long)right, (unsigned long)checks, right == checks ? @"PASS" : @"FAIL");
    });
}

// One track, then another album's at 8 s, its picture on the screens 0.4 s later.
// The header's glass circles press in under a finger (PlayerHeader.x): held on the down arrow and then on the
// ⋯, each circle is smaller while the finger is down and whole again once it lifts.
- (void)headerDown:(UIControl *)control {
    _headerDowns++;
}

- (void)runHeaderChecks {
    __block NSUInteger right = 0, checks = 0;
    void (^check)(NSString *, BOOL, NSString *) = ^(NSString *step, BOOL ok, NSString *detail) {
        checks++;
        if (ok) right++;
        NSLog(@"[harness] header %@: %@ -- %@", step, detail, ok ? @"ok" : @"WRONG");
    };
    UIView *header = _units.firstObject.view;
    NSMutableArray<UIView *> *buttons = [NSMutableArray array];
    for (UIView *view in header.subviews) if ([view isKindOfClass:MockEncoreButton.class]) [buttons addObject:view];
    check(@"buttons", buttons.count == 2, [NSString stringWithFormat:@"%lu Encore buttons in the header", (unsigned long)buttons.count]);
    __block NSUInteger i = 0;
    __block void (^next)(void);
    next = ^{
        if (i == buttons.count) {
            NSLog(@"[harness] header checks: %lu of %lu right -- %@", (unsigned long)right, (unsigned long)checks, right == checks ? @"PASS" : @"FAIL");
            next = nil;
            return;
        }
        UIView *button = buttons[i++];
        NSString *name = button.accessibilityIdentifier;
        UIView *circle = button.subviews.firstObject;
        check(name, [circle isKindOfClass:UIVisualEffectView.class] && circle.bounds.size.width == 44, [NSString stringWithFormat:@"a 44pt glass circle first in it (%@)", NSStringFromClass(circle.class)]);
        CGPoint middle = [button convertPoint:CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds)) toView:nil];
        check(name, [self.window hitTest:middle withEvent:nil] == button, @"a touch at its middle lands on the button");
        [(UIControl *)button addTarget:self action:@selector(headerDown:) forControlEvents:UIControlEventTouchDown];
        SGHarnessHold(self.window, middle, 0.5);
        after(0.4, ^{
            CGFloat scale = circle.transform.a;
            check(name, scale < 0.95, [NSString stringWithFormat:@"its circle pressed in while the finger is down (scale %.2f, touch down events %lu, tracking %d)", scale, (unsigned long)self->_headerDowns, ((UIControl *)button).tracking]);
        });
        after(1.2, ^{
            CGFloat scale = [[circle.layer.presentationLayer valueForKeyPath:@"transform.scale.x"] doubleValue];
            check(name, fabs(scale - 1) < 0.01 && CGAffineTransformIsIdentity(circle.transform), [NSString stringWithFormat:@"and whole again once it lifts (scale %.2f)", scale]);
            next();
        });
    };
    after(2, next);
}

- (void)runLook {
    UIImage *second = secondArtwork();
    // Issue #54: the footer row moved down past the bottom stack's bounds must still take its touches,
    // at the bottom edge of each glyph as well as the middle.
    after(3, ^{
        CGFloat bottom = 0;
        for (NSString *symbol in @[@"list.bullet", @"airpods.pro"]) {
            __block UIView *found = nil;
            NSMutableArray *queue = [NSMutableArray arrayWithObject:self.window];
            while (queue.count && !found) {
                UIView *v = queue.firstObject;
                [queue removeObjectAtIndex:0];
                if ([v isKindOfClass:UIImageView.class] && [((UIImageView *)v).image isEqual:[UIImage systemImageNamed:symbol]]) found = v;
                [queue addObjectsFromArray:v.subviews];
            }
            CGRect drawn = [found convertRect:found.bounds toView:self.window];
            bottom = CGRectGetMaxY(drawn);
            for (NSNumber *dy in @[@0, @8]) {
                CGPoint at = CGPointMake(CGRectGetMidX(drawn), CGRectGetMidY(drawn) + dy.doubleValue);
                UIView *hit = [self.window hitTest:at withEvent:nil];
                BOOL inRow = NO;
                for (UIView *v = hit; v; v = v.superview) inRow = inRow || [NSStringFromClass(unitOf(v).class) containsString:@"FooterElementsUnit"] || [v.accessibilityIdentifier isEqualToString:@"QueueButtonNowPlaying"];
                NSLog(@"[harness] touch on %@ at y %.0f (+%.0f): %@ -- %@", symbol, at.y, dy.doubleValue, NSStringFromClass(hit.class), inRow ? @"the footer's" : @"MISSED");
            }
        }
        NSLog(@"[harness] footer glyphs end at %.0f of %.0f", bottom, self.window.bounds.size.height);
    });
    after(8, ^{
        serve(imageURI(@"ffff"), second, 0.25, NO);
        [self playTrack:@"spotify:track:harnessF" image:imageURI(@"ffff")];
    });
    after(8.4, ^{ [self showOnScreen:second]; });
}

@end

// Before every %ctor, so the redesign's gate reads on, and every session gets the picture server.
__attribute__((constructor(101))) static void sgr_harnessDefaults(void) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"spotifyglass.redesign"];
    // Animated artwork, its clip served by the picture server to the shared session too.
    if ([scenario() isEqualToString:@"visualiser"]) [NSUserDefaults.standardUserDefaults setInteger:4 forKey:@"spotifyglass.redesign.player.background"];
    // Still at launch, so the player looks up no clip; an address of this run's own, so the store has none of it yet.
    if ([scenario() isEqualToString:@"preview"]) {
        [NSUserDefaults.standardUserDefaults setInteger:0 forKey:@"spotifyglass.redesign.player.background"];
        setenv("HARNESS_CANVAS", [NSString stringWithFormat:@"https://canvas.harness/preview-%d.mp4", getpid()].UTF8String, 1);
        setenv("HARNESS_CANVAS_DELAY", "2", 1);
        [NSURLProtocol registerClass:SGRHarnessPictureServer.class];
    }
    // card: HARNESS_BACKGROUND (an index, Fluid if unset), and with HARNESS_LAST=1 a last track played whose cover is
    // the picture server's first picture; without it, no track ever played.
    if ([scenario() isEqualToString:@"card"]) {
        NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
        const char *background = getenv("HARNESS_BACKGROUND");
        [store setInteger:background ? atoi(background) : 2 forKey:@"spotifyglass.redesign.player.background"];
        if (getenv("HARNESS_LAST")) {
            [store setObject:@{@"uri": @"spotify:track:last", @"title": @"Holocene, the Long Version Recorded Live at the Old Church",
                               @"artist": @"Bon Iver", @"artwork": [@"https://i.scdn.co/image/" stringByAppendingString:[imageURI(@"aaaa") substringFromIndex:14]],
                               @"canvas": [NSString stringWithFormat:@"https://canvas.harness/last-%d.mp4", getpid()]}
                      forKey:@"spotifyglass.lastTrack"];
        } else {
            [store removeObjectForKey:@"spotifyglass.lastTrack"];
        }
        [NSURLProtocol registerClass:SGRHarnessPictureServer.class];
    }
    // The shared session the catalog asks with.
    if ([scenario() isEqualToString:@"catalog"]) [NSURLProtocol registerClass:SGRHarnessPictureServer.class];
    if ([scenario() isEqualToString:@"motion"] || [scenario() isEqualToString:@"settings"]) {
        [NSUserDefaults.standardUserDefaults setInteger:3 forKey:@"spotifyglass.redesign.player.background"];
        setenv("HARNESS_CANVAS", "https://canvas.harness/clip.mp4", 1);
        [NSURLProtocol registerClass:SGRHarnessPictureServer.class];
    }
    Method original = class_getClassMethod(NSURLSessionConfiguration.class, @selector(defaultSessionConfiguration));
    Method harness = class_getClassMethod(NSURLSessionConfiguration.class, @selector(sgr_harnessDefault));
    method_exchangeImplementations(original, harness);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGRHarnessDelegate.class));
    }
}
