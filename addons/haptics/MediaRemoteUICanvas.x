// Vitrine Addon in MediaRemoteUI, the lock screen's Canvas below iOS 26: MediaRemoteUI draws the lock screen's player
// and, when its cover is tapped, the large cover over the lock screen, in a window of its own
// (MediaRemoteUI.SecureWindow, full screen) holding MediaRemoteUI.CoverSheetBackgroundView: an MTKView for the coloured
// field and the large MRUArtworkView, 352pt on a 414pt phone. The player's own small
// cover is in its other window, and the system takes it away as the large one opens.
//
// While the large cover is open, Spotify's switch is on (kSGRelayLockArtOn) and SpringBoard has shared the song's clip
// (kSGRelayLockClipShared, SGLockSharedClipPath), the large cover is hidden and the clip shown full screen in its place,
// over the field (LockClipView.h), and SpringBoard is told (kSGRelayLockShowing) to hide the widgets under the clock.
// A clip that comes later takes the cover's place as it comes; with none the system's cover stays as it is, and closed,
// everything of the system's comes back. The clip holds still while the song is paused.
//
// MediaRemoteUI gives the large cover its alpha back as it animates (the cover would stay over the clip
// until the screen had gone off and on a few times), so a hidden cover keeps alpha 0 whatever it is set to, and gets the
// last alpha MediaRemoteUI asked for back. A tap that closes the large cover (the field's own, heard alongside it) gives
// the cover back at once, for MediaRemoteUI to shrink it into the player as it does with no clip, and fades the clip out
// over it: hidden, the cover had nothing to shrink and the clip went at once.
//
// A song with no clip gets its still cover the same way, the screen's width across on the bands of its edges' colours,
// while Spotify is what plays: the cover from MediaRemote's now playing info, as the lock screen's own player has it.
// While the screen is dark the clip is not read or decoded (com.apple.springboard.hasBlankedScreen), and lit it starts
// over on a new display layer.
//
// A new song changes what is drawn only once it has something to draw: until its cover is in (the now playing info
// comes first with none, or with Spotify's gray placeholder picture, looksLoaded) or its clip is shared, the last song's clip or cover stays,
// rather than the system's gray placeholder showing for a moment. If neither is in after kWait, whatever the song has
// is drawn, the placeholder too.
//
// With the lyrics switch on (kSGRelayLockLyricsOn), a button puts the song's lyrics over the Canvas, dimmed under them,
// and takes them away again (LockLyricsView.h); SpringBoard keeps which of the two was picked. The button sits in the
// lock screen player's own header, in the place of its small cover, which the large one has taken while it is open: the
// lyrics and the Canvas are behind the lock screen's player and notifications, which cover anything put there and take
// its touches. MediaRemoteUI draws that player too, in a window of its own: MRULockscreenView, its header
// MRUNowPlayingHeaderView with the small cover's room before MRUNowPlayingLabelView's labels (14 to 55 pt of a 386 pt
// player on an iPhone 11). Closed, the large cover gives the small one back and the button goes. It is dim and does
// nothing for a song without timed lines, and the Canvas shows. The lyrics scroll by hand and a tap on a line seeks the
// song (kSGRelayLockLyricsSeek); under them the Canvas goes to a dark blur, so the words read on any clip.
//
// The field takes no touches: its window is behind SpringBoard's cover sheet, whose notification list gets them, scrolls
// the player with them and closes the large cover on a tap. So the field says where the lyrics and the clip are
// (kSGRelayLockGestureArea), SpringBoard catches the touches over the lyrics (LockCover.x), and their drags and taps come
// back here (kSGRelayLockGesturePan, kSGRelayLockGestureTap): the lyrics scroll and seek, and no tap closes the cover. With
// them off nothing is caught: the list has its touches, a tap closing the cover as it does without Vitrine.
//
// Only the large cover's view and the cover itself are hooked, as they lay out, come and go and take an alpha.
//
// Nothing of UIKit is made in the constructor, which dyld runs before UIKit has launched: a view made there waits on
// the launch that waits on it (lyricsView() is only called from the main queue once the app runs).
//
// Threading: main thread.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import <notify.h>
#import "LockClipView.h"
#import "LockLyricsView.h"
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

typedef void (*SGMRIsPlaying)(dispatch_queue_t queue, void (^handler)(Boolean playing));
typedef void (*SGMRRegister)(dispatch_queue_t queue);
typedef void (*SGMRGetInfo)(dispatch_queue_t queue, void (^handler)(CFDictionaryRef info));
typedef void (*SGMRGetApp)(dispatch_queue_t queue, void (^handler)(CFStringRef bundle));

static const NSTimeInterval kFade = 0.35;
// How long a new song's cover is waited for before its placeholder is drawn.
static const NSTimeInterval kWait = 2;

static SGMRIsPlaying sg_isPlaying;
static SGMRGetInfo sg_getInfo;
static SGMRGetApp sg_getApp;
static BOOL sg_on, sg_playing = YES, sg_showing, sg_blank;
static UIImage *sg_cover;   // Spotify's song's still cover, nil for none or for another app
static NSData *sg_coverData;
static BOOL sg_coverLoaded;   // sg_cover is the song's own, not a placeholder
static NSString *sg_track;   // the song the now playing info is for
static NSURL *sg_clip;   // this process's own copy of the shared clip, nil for none
// What is drawn: the clip, cover and song above as they were when last taken, held while a new song's are on their way.
static UIImage *sg_shownCover;
static NSData *sg_shownCoverData;
static NSString *sg_shownTrack;
static NSURL *sg_shownClip;
static BOOL sg_waiting;
static NSUInteger sg_wait;   // the wait's number, so a late timeout of one that ended does nothing
static __weak UIView *sg_field;   // the large cover's CoverSheetBackgroundView, while it is open
static char kClipKey, kTapKey, kHiddenKey, kWantedKey, kClosedKey;
static BOOL sg_settingAlpha;   // the alpha set here, not MediaRemoteUI's to remember
// The lyrics: the switch, the choice the button makes (SpringBoard's), and the one view of them, moved into the field
// that is open. A song's lines wait kSGRelayLockLyricsWait as it begins, the last song's held meanwhile.
static BOOL sg_lyricsOn, sg_lyricsPicked;
// The lyrics over the clip right now: the clip holds one frame under their blur instead of decoding on unseen.
static BOOL sg_linesOver;
// Spotify said the song playing has no timed lines (kSGRelayLockLyricsNone), rather than that they are on their way.
static BOOL sg_lyricsNone;
static SGVLockLyrics *sg_lyrics;
static NSUInteger sg_lyricsWait;
static char kDimKey;
// The button, made once the app runs, and the lock screen player it goes into, while there is one.
static UIButton *sg_button;
static __weak UIView *sg_player;
// How far inside the small cover's room the button's disc is drawn, and the gap kept to the labels after it.
static const CGFloat kButtonInset = 2, kLabelGap = 3;
// The lines run from under the clock to over the lock screen's player.
static const CGFloat kLyricsTopShare = 0.27, kLyricsBottomRoom = 190;
// How dark the Canvas goes under the lyrics, over its blur.
static const CGFloat kLyricsDim = 0.25;


static void apply(void);

// The lyrics' button: a disc in the colour of the player's own labels, faint with the glyph in that colour while the
// Canvas shows and solid with the glyph cut out of it while the lyrics do, so it reads as a button on a light player and
// a dark one alike.
@interface SGVLyricsButton : UIButton
@end

@implementation SGVLyricsButton

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
    [self setImage:[UIImage systemImageNamed:@"quote.bubble" withConfiguration:configuration] forState:UIControlStateNormal];
    [self setImage:[UIImage systemImageNamed:@"quote.bubble.fill" withConfiguration:configuration] forState:UIControlStateSelected];
    [self setImage:[UIImage systemImageNamed:@"quote.bubble.fill" withConfiguration:configuration] forState:UIControlStateSelected | UIControlStateHighlighted];
    self.accessibilityLabel = @"Lyrics";
    self.clipsToBounds = YES;
    [self paint];
    return self;
}

- (void)paint {
    BOOL on = self.selected;
    self.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:on ? 0.9 : (self.highlighted ? 0.24 : 0.14)];
    self.tintColor = on ? UIColor.systemBackgroundColor : UIColor.labelColor;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self paint];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self paint];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
}

@end

@interface SGVLyricsButtonTarget : NSObject
@end

@implementation SGVLyricsButtonTarget
- (void)tapped:(UIButton *)button {
    sg_lyricsPicked = !sg_lyricsPicked;
    sg_lyricsNone = NO;
    notify_post(sg_lyricsPicked ? kSGRelayLockModeLyrics : kSGRelayLockModeCanvas);
    apply();
}
@end

// The button in the lock screen player's header, in its small cover's room: from the header's leading edge to the
// labels, as tall as the header. Left alone while the player has no such header.
static void placeButton(void) {
    UIView *player = sg_player;
    if (!sg_button || !player) return;
    Class headerClass = NSClassFromString(@"MRUNowPlayingHeaderView"), labelsClass = NSClassFromString(@"MRUNowPlayingLabelView");
    UIView *header = nil, *labels = nil;
    for (UIView *sub in player.subviews) if (headerClass && [sub isKindOfClass:headerClass]) header = sub;
    for (UIView *sub in header.subviews) if (labelsClass && [sub isKindOfClass:labelsClass]) labels = sub;
    if (!header || !labels) return;
    CGFloat room = MIN(CGRectGetMinX(labels.frame) - kLabelGap, header.bounds.size.height);
    if (room < 20) return;
    CGFloat side = room - 2 * kButtonInset;
    CGRect frame = CGRectMake(kButtonInset, (header.bounds.size.height - side) / 2, side, side);
    if (sg_button.superview != header) [header addSubview:sg_button];
    else if (header.subviews.lastObject != sg_button) [header bringSubviewToFront:sg_button];
    if (!CGRectEqualToRect(sg_button.frame, frame)) sg_button.frame = frame;
}

static UIButton *lyricsButton(void) {
    if (!sg_button) {
        static SGVLyricsButtonTarget *target;
        target = [SGVLyricsButtonTarget new];
        sg_button = [[SGVLyricsButton alloc] initWithFrame:CGRectZero];
        sg_button.alpha = 0;
        [sg_button addTarget:target action:@selector(tapped:) forControlEvents:UIControlEventTouchUpInside];
    }
    placeButton();
    return sg_button;
}

// The button gone, the small cover back in its room.
static void hideButton(void) {
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ sg_button.alpha = 0; } completion:nil];
}

static SGVLockLyrics *lyricsView(void) {
    if (!sg_lyrics) {
        sg_lyrics = [[SGVLockLyrics alloc] initWithFrame:CGRectZero];
        sg_lyrics.alpha = 0;
        sg_lyrics.availabilityChanged = ^{ apply(); };
        sg_lyrics.seek = ^(NSInteger position) {
            static int token;
            if (!token && notify_register_check(kSGRelayLockLyricsSeek, &token) != NOTIFY_STATUS_OK) return;
            notify_set_state(token, (uint64_t)MAX(position, 0));
            notify_post(kSGRelayLockLyricsSeek);
        };
    }
    return sg_lyrics;
}

// Where the lyrics and the clip are, for SpringBoard's catcher, posted as it changes; all zero for none.
static void tellArea(SGLockGestureAreaState area) {
    static uint64_t told = UINT64_MAX;
    static int token;
    uint64_t state = SGLockGestureArea(area);
    if (state == told) return;
    if (!token && notify_register_check(kSGRelayLockGestureArea, &token) != NOTIFY_STATUS_OK) return;
    told = state;
    notify_set_state(token, state);
    notify_post(kSGRelayLockGestureArea);
}
// The last views of the field, in this order, on top of everything of MediaRemoteUI's.
static void keepOnTop(UIView *field, NSArray<UIView *> *views) {
    NSArray<UIView *> *subviews = field.subviews;
    BOOL inOrder = subviews.count >= views.count;
    for (NSUInteger i = 0; inOrder && i < views.count; i++) inOrder = subviews[subviews.count - views.count + i] == views[i];
    if (inOrder) return;
    for (UIView *view in views) [field addSubview:view];
}

@interface SGVFieldTap : NSObject <UIGestureRecognizerDelegate>
@end

static void closing(UIView *field);

@implementation SGVFieldTap
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)recognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}
- (void)tapped:(UITapGestureRecognizer *)tap {
    closing(tap.view);
}
@end

// The large cover hidden or given back: alpha 0 held while hidden, the alpha MediaRemoteUI last asked for after.
static void hideArtwork(UIView *artwork, BOOL hidden, BOOL animated) {
    if (!artwork || !!objc_getAssociatedObject(artwork, &kHiddenKey) == hidden) return;
    NSNumber *wanted = objc_getAssociatedObject(artwork, &kWantedKey);
    objc_setAssociatedObject(artwork, &kHiddenKey, hidden ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat alpha = hidden ? 0 : (wanted ? wanted.doubleValue : 1);
    sg_settingAlpha = YES;
    [UIView animateWithDuration:animated ? kFade : 0 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ artwork.alpha = alpha; } completion:nil];
    sg_settingAlpha = NO;
}

// The large cover in the field: the field's MRUArtworkView.
static UIView *artworkIn(UIView *field) {
    Class artwork = NSClassFromString(@"MRUArtworkView");
    for (UIView *sub in field.subviews) if (artwork && [sub isKindOfClass:artwork]) return sub;
    return nil;
}

static void tellShowing(BOOL showing) {
    if (sg_showing == showing) return;
    sg_showing = showing;
    notify_post(showing ? kSGRelayLockShowing : kSGRelayLockNotShowing);
}

static void apply(void) {
    UIView *field = sg_field;
    // Out of a window, or in a hidden one, nothing of the clip is read or decoded (the clip view rests itself out of one).
    if (!field.window || field.window.hidden) {
        tellShowing(NO);
        hideButton();
        tellArea((SGLockGestureAreaState){NO, 0, 0});
        [(SGVLockClip *)objc_getAssociatedObject(field, &kClipKey) setSuspended:YES];
        return;
    }
    UIView *artwork = artworkIn(field);
    // Closed by a tap, the field stays the system's until it is shown again.
    BOOL on = sg_on && (sg_shownClip || sg_shownCover) && artwork && !objc_getAssociatedObject(field, &kClosedKey);
    SGVLockClip *clip = objc_getAssociatedObject(field, &kClipKey);
    if (!clip && on) {
        clip = [[SGVLockClip alloc] initWithFrame:field.bounds];
        clip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        clip.alpha = 0;
        objc_setAssociatedObject(field, &kClipKey, clip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    // The lyrics belong to a Canvas shown: the button with it, the lines and the dim under them once picked, for a song
    // that has them.
    BOOL offered = on && sg_lyricsOn;
    SGVLockLyrics *lyrics = offered || sg_lyrics.superview == field ? lyricsView() : nil;
    UIView *dim = objc_getAssociatedObject(field, &kDimKey);
    UIButton *button = offered || sg_button ? lyricsButton() : nil;
    if (offered && !dim) {
        // The Canvas blurred dark under the lyrics, as Apple Music's lyrics have their artwork, a little darker still.
        UIVisualEffectView *blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
        blur.contentView.backgroundColor = [UIColor colorWithWhite:0 alpha:kLyricsDim];
        blur.userInteractionEnabled = NO;
        blur.alpha = 0;
        dim = blur;
        objc_setAssociatedObject(field, &kDimKey, dim, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (clip) {
        // Over the field and the large cover, so a cover MediaRemoteUI shows for a moment stays under it, and the
        // lyrics and the dim under them over the clip.
        NSMutableArray<UIView *> *order = [NSMutableArray arrayWithObject:clip];
        if (dim) [order addObject:dim];
        if (dim && lyrics) [order addObject:lyrics];
        keepOnTop(field, order);
        CGRect bounds = field.bounds;
        if (!CGRectEqualToRect(clip.frame, bounds)) clip.frame = bounds;
        if (!CGRectEqualToRect(dim.frame, bounds)) dim.frame = bounds;
        CGFloat top = round(bounds.size.height * kLyricsTopShare);
        CGRect lines = CGRectMake(0, top, bounds.size.width, MAX(0, bounds.size.height - kLyricsBottomRoom - top));
        if (lyrics && !CGRectEqualToRect(lyrics.frame, lines)) lyrics.frame = lines;
    }
    if (on && !objc_getAssociatedObject(field, &kTapKey)) {
        SGVFieldTap *handler = [SGVFieldTap new];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:handler action:@selector(tapped:)];
        tap.delegate = handler;
        tap.cancelsTouchesInView = NO;
        tap.delaysTouchesEnded = NO;
        [field addGestureRecognizer:tap];
        objc_setAssociatedObject(field, &kTapKey, handler, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    tellShowing(on);
    hideArtwork(artwork, on, YES);
    BOOL shown = clip.alpha > 0.99;
    // Dim and dead for a song without lines; its alpha is set with the rest below, so it fades rather than jumps.
    BOOL available = lyrics.available, lines = offered && sg_lyricsPicked && available;
    // Always pressable: Spotify fetches a song's lines only once the lyrics are picked, so until then none are here. Picked,
    // it shows dim only once Spotify has said the song has none, not while they are on their way.
    button.enabled = YES;
    button.selected = sg_lyricsPicked;
    [lyrics setSuspended:!lines || sg_blank];
    [UIView animateWithDuration:kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        button.alpha = offered ? (sg_lyricsPicked && sg_lyricsNone ? 0.5 : 1) : 0;
        dim.alpha = lines ? 1 : 0;
        lyrics.alpha = lines ? 1 : 0;
    } completion:nil];
    [UIView animateWithDuration:shown == on ? 0 : kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        clip.alpha = on ? 1 : 0;
    } completion:^(BOOL finished) {
        if (!(sg_on && sg_shownClip && artworkIn(field)) || objc_getAssociatedObject(field, &kClosedKey)) [clip playClip:nil];
    }];
    sg_linesOver = on && lines && lyrics != nil;
    if (on) {
        [clip setSuspended:sg_blank];
        [clip showCover:sg_shownCover];
        [clip playClip:sg_shownClip];
        [clip setPlaying:sg_playing && !sg_linesOver];
    }
    // The field fills the screen, so its window's points are the screen's.
    SGLockGestureAreaState area = {NO, 0, 0};
    if (on) {
        // The lyrics' band only while they show: with them off, the list's drags and taps are the list's.
        if (lines && lyrics) {
            CGRect frame = [field convertRect:lyrics.frame toView:nil];
            area.lyricsShown = YES;
            area.lyricsTop = CGRectGetMinY(frame);
            area.lyricsBottom = CGRectGetMaxY(frame);
        }
    }
    tellArea(area);
}

// The large cover closing on a tap: the cover back at once, for MediaRemoteUI to shrink it, the clip fading over it.
static void closing(UIView *field) {
    SGVLockClip *clip = objc_getAssociatedObject(field, &kClipKey);
    if (!clip || clip.alpha < 0.01) return;
    objc_setAssociatedObject(field, &kClosedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    hideArtwork(artworkIn(field), NO, NO);
    tellShowing(NO);
    UIView *dim = objc_getAssociatedObject(field, &kDimKey);
    UIView *lyrics = sg_lyrics.superview == field ? sg_lyrics : nil;
    [sg_lyrics setSuspended:YES];
    hideButton();
    tellArea((SGLockGestureAreaState){NO, 0, 0});
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ clip.alpha = dim.alpha = lyrics.alpha = 0; } completion:nil];
}

// A copy of the shared clip taken off disk once it is neither the newest nor the one drawn.
static void forget(NSURL *clip) {
    if (clip && ![clip isEqual:sg_clip] && ![clip isEqual:sg_shownClip]) [NSFileManager.defaultManager removeItemAtURL:clip error:nil];
}

// What came in drawn. Falling back, at the end of a wait, the new song's placeholder is taken too; otherwise a
// placeholder never takes the place of a cover already drawn.
static void take(BOOL fallback) {
    NSURL *old = sg_shownClip;
    sg_waiting = NO;
    sg_shownClip = sg_clip;
    sg_shownTrack = sg_track;
    if (sg_coverLoaded || fallback || !sg_shownCover) {
        sg_shownCover = sg_cover;
        sg_shownCoverData = sg_coverData;
    }
    forget(old);
    apply();
}

// Something of a new song's in: drawn at once outside a wait, and in one once it is the new song's clip or its own cover.
static void changed(void) {
    if (!sg_waiting) {
        take(NO);
        return;
    }
    BOOL newClip = sg_clip && ![sg_clip isEqual:sg_shownClip];
    BOOL newCover = sg_coverLoaded && ![sg_track isEqualToString:sg_shownTrack] && ![sg_coverData isEqualToData:sg_shownCoverData];
    if (newClip || newCover) take(NO);
}

// The wait's end, kWait from now. With the cover not read (the screen dark, readCover), the cover in hand is the last
// song's, so the wait goes on, and starts over as the screen lights and the cover is read.
static BOOL sg_coverStale;
static void armWait(void) {
    NSUInteger run = ++sg_wait;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (sg_waiting && sg_wait == run && !sg_coverStale) take(YES);
    });
}

// A new song on its way: what is drawn stays until changed() finds its clip or cover, or kWait has gone.
static void hold(void) {
    if (!sg_waiting && (sg_shownClip || sg_shownCover)) {
        sg_waiting = YES;
        armWait();
    }
    changed();
}

// A clip shared while it could not be shown (the screen dark, no large cover, the Canvas off): read once it can be.
static BOOL sg_clipStale;
// Each read and each new song's none: a copy that ends after a newer one began is dropped.
static NSUInteger sg_clipRun;

// The shared clip copied into this process's own temporary folder under a new name, so the clip view takes a new file.
// Only while it can be shown, and off the main thread.
static void readShared(void) {
    NSURL *old = sg_clip;
    sg_clip = nil;
    forget(old);
    NSUInteger run = ++sg_clipRun;
    sg_clipStale = sg_blank || !sg_field || !sg_on;
    if (sg_clipStale) {
        changed();
        return;
    }
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.vitrine.addon.clipcopy", DISPATCH_QUEUE_SERIAL); });
    NSURL *shared = [NSURL fileURLWithPath:SGLockSharedClipPath()];
    NSURL *copy = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"vitrine-lockclip-%u.mp4", arc4random()]]];
    dispatch_async(queue, ^{
        NSError *error = nil;
        BOOL copied = [NSFileManager.defaultManager copyItemAtURL:shared toURL:copy error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (run != sg_clipRun) {
                if (copied) [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                return;
            }
            if (copied) sg_clip = copy;
            else NSLog(@"[vitrine-addon] MediaRemoteUI cannot read the shared clip: %@", error.localizedDescription);
            changed();
        });
    });
}

// Whether `cover` is a song's own rather than a placeholder. Spotify's placeholder is a gray field with a gray picture
// glyph on it: gray all over, two or three flat shades, and an edge of the field's shade alone. A song's cover, in color
// or not, has many shades and an edge that varies. The flat gray of a placeholder with no glyph reads the same way.
// Read off a 32 pt copy, in sixteen shades of gray.
static BOOL looksLoaded(UIImage *cover) {
    CGImageRef image = cover.CGImage;
    if (!image) return NO;
    enum { side = 32, levels = 16 };
    uint8_t pixels[side * side * 4] = {0};
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(pixels, side, side, 8, side * 4, space, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(space);
    if (!context) return YES;
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, side, side), image);
    CGContextRelease(context);
    NSUInteger counts[levels] = {0}, edges = 0;
    double chroma = 0, edgeSum = 0, edgeSquares = 0;
    for (int y = 0; y < side; y++) {
        for (int x = 0; x < side; x++) {
            const uint8_t *p = pixels + (y * side + x) * 4;
            double luma = (0.299 * p[0] + 0.587 * p[1] + 0.114 * p[2]) / 255;
            chroma = MAX(chroma, (MAX(p[0], MAX(p[1], p[2])) - MIN(p[0], MIN(p[1], p[2]))) / 255.0);
            counts[MIN(levels - 1, (int)(luma * levels))]++;
            if (x == 0 || y == 0 || x == side - 1 || y == side - 1) {
                edgeSum += luma;
                edgeSquares += luma * luma;
                edges++;
            }
        }
    }
    double edgeMean = edgeSum / edges, edgeSpread = sqrt(MAX(0, edgeSquares / edges - edgeMean * edgeMean));
    NSUInteger shades = 0;
    for (int i = 0; i < levels; i++) if (counts[i] > side * side / 50) shades++;
    return !(chroma < 0.08 && shades <= 3 && edgeSpread < 0.03);
}

// The song, by its title and album: not its artist, which Vitrine's lock screen lyrics write each line into.
static NSString *trackOf(NSDictionary *info) {
    return [NSString stringWithFormat:@"%@\n%@", info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"", info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @""];
}

// Spotify's still cover from the now playing info, read again as the info changes; another app's is not taken. Two XPC
// calls and the artwork's bytes, and Vitrine's lock screen lyrics change the info with every line: none of it while the
// switch is off or the screen is dark, only a note to read it once either comes back.
static void readCover(void) {
    if (!sg_getInfo || !sg_getApp) return;
    if (!sg_on || sg_blank) {
        sg_coverStale = YES;
        return;
    }
    sg_coverStale = NO;
    sg_getApp(dispatch_get_main_queue(), ^(CFStringRef bundle) {
        if (![(__bridge NSString *)bundle isEqualToString:@"com.spotify.client"]) {
            BOOL had = sg_cover != nil || sg_shownCover != nil;
            sg_cover = nil;
            sg_coverData = nil;
            sg_coverLoaded = NO;
            sg_track = nil;
            if (had) take(YES);
            return;
        }
        sg_getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            NSDictionary *now = (__bridge NSDictionary *)info;
            NSString *track = trackOf(now);
            NSData *data = now[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            BOOL sameCover = data == sg_coverData || [data isEqualToData:sg_coverData];
            if (sameCover && [track isEqualToString:sg_track]) return;
            BOOL newTrack = sg_track && ![track isEqualToString:sg_track];
            sg_track = track;
            if (!sameCover) {
                sg_coverData = data;
                sg_cover = data ? [UIImage imageWithData:data] : nil;
                sg_coverLoaded = looksLoaded(sg_cover);
            }
            if (newTrack) hold();
            else changed();
        });
    });
}

static void readPlaying(void) {
    if (!sg_isPlaying) return;
    sg_isPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
        sg_playing = playing;
        SGVLockClip *clip = sg_field ? objc_getAssociatedObject(sg_field, &kClipKey) : nil;
        [clip setPlaying:playing && !sg_linesOver];
    });
}

%hook _TtC13MediaRemoteUI24CoverSheetBackgroundView
- (void)didMoveToWindow {
    %orig;
    UIView *field = (UIView *)self;
    if (field.window) {
        sg_field = field;
        objc_setAssociatedObject(field, &kClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (sg_clipStale) readShared();
    }
    apply();
}

- (void)layoutSubviews {
    %orig;
    UIView *field = (UIView *)self;
    sg_field = field;
    // A field closed by a tap and kept, hidden, for the next time: it is the clip's again as it is shown.
    UIWindow *window = field.window;
    if (field.hidden || field.alpha < 0.01 || !window || window.hidden || window.alpha < 0.01)
        objc_setAssociatedObject(field, &kClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (sg_on || sg_showing) apply();
}
%end

// The lock screen player, kept for the button, which goes back into its header as it lays out.
%group SGVPlayer
%hook MRULockscreenView
- (void)layoutSubviews {
    %orig;
    sg_player = (UIView *)self;
    placeButton();
}
%end
%end

%group SGVArtwork
%hook MRUArtworkView
- (void)setAlpha:(CGFloat)alpha {
    if (!sg_settingAlpha) objc_setAssociatedObject(self, &kWantedKey, @(alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(objc_getAssociatedObject(self, &kHiddenKey) ? 0 : alpha);
}
%end
%end

static void listen(const char *name, void (^handler)(void)) {
    int token;
    notify_register_dispatch(name, &token, dispatch_get_main_queue(), ^(int t) { handler(); });
}

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.MediaRemoteUI"]) return;
    if (@available(iOS 26.0, *)) return;
    if (!objc_getClass("_TtC13MediaRemoteUI24CoverSheetBackgroundView")) {
        NSLog(@"[vitrine-addon] MediaRemoteUI has no CoverSheetBackgroundView, the lock screen's Canvas is off");
        return;
    }
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    sg_isPlaying = remote ? (SGMRIsPlaying)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationIsPlaying") : NULL;
    SGMRRegister registerFor = remote ? (SGMRRegister)dlsym(remote, "MRMediaRemoteRegisterForNowPlayingNotifications") : NULL;
    sg_getInfo = remote ? (SGMRGetInfo)dlsym(remote, "MRMediaRemoteGetNowPlayingInfo") : NULL;
    sg_getApp = remote ? (SGMRGetApp)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
    %init;
    if (objc_getClass("MRUArtworkView")) %init(SGVArtwork);
    if (objc_getClass("MRULockscreenView")) %init(SGVPlayer);
    else NSLog(@"[vitrine-addon] MediaRemoteUI has no MRULockscreenView, the lyrics have no button");
    if (registerFor) registerFor(dispatch_get_main_queue());
    [NSNotificationCenter.defaultCenter addObserverForName:@"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification" object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ readPlaying(); });
    }];
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification", @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ readCover(); });
        }];
    }
    readPlaying();
    readCover();
    static int blankToken;
    notify_register_dispatch("com.apple.springboard.hasBlankedScreen", &blankToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        notify_get_state(t, &state);
        sg_blank = state != 0;
        SGVLockClip *clip = sg_field ? objc_getAssociatedObject(sg_field, &kClipKey) : nil;
        [clip setSuspended:sg_blank];
        if (!sg_blank && sg_coverStale) {
            readCover();
            if (sg_waiting) armWait();
        }
        if (!sg_blank && sg_clipStale) readShared();
        apply();   // the lyrics rest with it
    });
    // As it is now: nothing is posted until it changes.
    uint64_t blankState = 0;
    if (notify_get_state(blankToken, &blankState) == NOTIFY_STATUS_OK) sg_blank = blankState != 0;
    listen(kSGRelayLockArtOn, ^{
        sg_on = YES;
        if (sg_coverStale) readCover();
        if (sg_clipStale) readShared();
        apply();
    });
    listen(kSGRelayLockLyricsOn, ^{ sg_lyricsOn = YES; apply(); });
    listen(kSGRelayLockLyricsOff, ^{ sg_lyricsOn = NO; apply(); });
    listen(kSGRelayLockModeLyrics, ^{ sg_lyricsPicked = YES; apply(); });
    listen(kSGRelayLockModeCanvas, ^{ sg_lyricsPicked = NO; apply(); });
    // A song's lines: read as SpringBoard shares them; a new song holds the last song's until its own come, or
    // kSGRelayLockLyricsWait has gone; a song without timed lines has none.
    listen(kSGRelayLockLyricsShared, ^{
        sg_lyricsWait++;
        sg_lyricsNone = NO;
        if (![lyricsView() takeFile:SGLockSharedLyricsPath()]) [lyricsView() clear];
        apply();
    });
    listen(kSGRelayLockLyricsNone, ^{
        sg_lyricsWait++;
        sg_lyricsNone = YES;
        [lyricsView() clear];
        apply();
    });
    listen(kSGRelayLockLyricsPending, ^{
        NSUInteger wait = ++sg_lyricsWait;
        sg_lyricsNone = NO;
        [lyricsView() hold];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSGRelayLockLyricsWait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (wait != sg_lyricsWait) return;
            [lyricsView() clear];
            apply();
        });
    });
    // SpringBoard's catcher hands the drags and taps over the lyrics in, while they show.
    static int panToken, tapToken;
    notify_register_dispatch(kSGRelayLockGesturePan, &panToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        SGVLockLyrics *lyrics = sg_lyrics;
        if (!lyrics || lyrics.alpha < 0.5 || notify_get_state(t, &state) != NOTIFY_STATUS_OK) return;
        int phase;
        CGFloat translation, velocity;
        SGLockGesturePanRead(state, &phase, &translation, &velocity);
        if (phase == 0) [lyrics dragBegan];
        else [lyrics dragTo:translation];
        if (phase == 2) [lyrics dragEndedWithVelocity:velocity];
    });
    notify_register_dispatch(kSGRelayLockGestureTap, &tapToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        SGVLockLyrics *lyrics = sg_lyrics;
        if (!lyrics || lyrics.alpha < 0.5 || notify_get_state(t, &state) != NOTIFY_STATUS_OK) return;
        [lyrics tapAt:[lyrics convertPoint:SGLockGestureTapRead(state) fromView:nil]];
    });
    static int clockToken;
    notify_register_dispatch(kSGRelayLockLyricsClock, &clockToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        if (notify_get_state(t, &state) == NOTIFY_STATUS_OK) [lyricsView() setClockState:state];
    });
    listen(kSGRelayLockArtOff, ^{ sg_on = NO; apply(); });
    listen(kSGRelayLockClipShared, ^{ readShared(); });
    // Spotify says so as each song begins, before its clip is looked up, so what is drawn waits for the song's cover.
    listen(kSGRelayLockClipNone, ^{
        sg_clipRun++;
        sg_clipStale = NO;
        NSURL *old = sg_clip;
        sg_clip = nil;
        forget(old);
        hold();
    });
    // The switch and the clip as they are now: Spotify answers SpringBoard's pong to this ping with the switch, and a
    // clip already shared is in the shared caches.
    notify_post(kSGRelayPing);
    notify_post(kSGRelayLockModeAsk);
    // A MediaRemoteUI that went away while showing the clip left SpringBoard's widgets hidden: it says it shows nothing.
    notify_post(kSGRelayLockNotShowing);
    if ([NSFileManager.defaultManager fileExistsAtPath:SGLockSharedClipPath()]) readShared();
    // The lines already shared, and the clock Spotify posted last, which a MediaRemoteUI starting late has not heard, so
    // the lines count at once. Not here but once the app runs: the lyrics are a view, and a view made while dyld runs this
    // constructor waits on UIKit's launch, which waits on this constructor, until the launch watchdog kills MediaRemoteUI
    // and the lock screen has no player at all (0x8BADF00D, add-on build 17).
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([NSFileManager.defaultManager fileExistsAtPath:SGLockSharedLyricsPath()]) [lyricsView() takeFile:SGLockSharedLyricsPath()];
        uint64_t lastClock = 0;
        if (notify_get_state(clockToken, &lastClock) == NOTIFY_STATUS_OK && lastClock) [lyricsView() setClockState:lastClock];
    });
    // A MediaRemoteUI that went away with the lyrics up left their band in the notification's state, SpringBoard's catcher
    // over the list and Spotify's lock screen line on the artist: it says there are none.
    tellArea((SGLockGestureAreaState){NO, 0, 0});
    NSLog(@"[vitrine-addon] MediaRemoteUI ready for the lock screen's Canvas");
}
