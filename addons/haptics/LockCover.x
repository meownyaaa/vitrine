// Vitrine Addon in SpringBoard, the lock screen's Canvas below iOS 26: SpringBoard's share of it. The lock screen's
// player and its large cover are drawn by MediaRemoteUI, which only shows in SpringBoard's lock screen as a scene of its
// own (the cover sheet has neither, MediaRemoteUI has both), so the clip is put in the
// large cover's place there (MediaRemoteUICanvas.x). Here:
//
//   the clip    Spotify's for the song (kSGRelayLockClip), read through the data container of the now playing app and
//               copied to the jailbreak's shared caches (SGLockSharedClipPath), where MediaRemoteUI, sandboxed, can read
//               it; MediaRemoteUI is told by kSGRelayLockClipShared. kSGRelayLockClipNone comes from Spotify to both.
//   the widgets the row under the clock (CSProminentEmptyElementView) hidden while
//               MediaRemoteUI shows the clip (kSGRelayLockShowing), and given back as it stops.
//   the lyrics  Spotify's lines for the song (kSGRelayLockLyrics), shared the same way (SGLockSharedLyricsPath,
//               kSGRelayLockLyricsShared); and the choice between them and the Canvas that MediaRemoteUI's button makes,
//               kept in the add-on's own preferences for the next song and the next boot, and told MediaRemoteUI again
//               as it asks (kSGRelayLockModeAsk) and as SpringBoard starts.
//   the touches the large cover takes none (MediaRemoteUI draws it behind the cover sheet), so while its lyrics show a
//               catcher lies over the notification list where they are (kSGRelayLockGestureArea) and hands the drags and
//               taps there to MediaRemoteUI: the lyrics scroll and seek, and the cover stays open. A touch on the player or
//               a notification, wherever the list has scrolled them, is theirs. With the lyrics off there is no catcher,
//               and the list has its touches as it always does.
//
// Nothing is walked or hooked on the lock screen's layout: the widgets' row is looked for only as it is to be hidden.
//
// Threading: the notifications and MediaRemote's answers come on the main queue.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <notify.h>
#import "../../tweak/Sources/Shared/Haptics/SGHapticRelay.h"

@interface CSCoverSheetViewController : UIViewController
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end

typedef void (*SGMRGetApp)(dispatch_queue_t queue, void (^handler)(CFStringRef bundle));

static const NSTimeInterval kFade = 0.35;

static SGMRGetApp sg_getApp;
static __weak UIView *sg_sheet;   // the cover sheet's view
static NSHashTable<UIView *> *sg_hidden;

// The widgets' row under the clock, wherever the cover sheet keeps it.
static void collectRows(UIView *root, NSMutableArray<UIView *> *rows, int depth) {
    if (depth > 30) return;
    for (UIView *sub in root.subviews) {
        if ([NSStringFromClass(sub.class) isEqualToString:@"CSProminentEmptyElementView"]) {
            [rows addObject:sub];
            continue;
        }
        collectRows(sub, rows, depth + 1);
    }
}

static void hideWidgets(BOOL away) {
    if (!sg_hidden) sg_hidden = [NSHashTable weakObjectsHashTable];
    NSArray<UIView *> *views = sg_hidden.allObjects;
    if (away) {
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        if (sg_sheet) collectRows(sg_sheet, rows, 0);
        for (UIView *row in rows) [sg_hidden addObject:row];
        views = rows;
    } else {
        [sg_hidden removeAllObjects];
    }
    for (UIView *view in views) {
        [UIView animateWithDuration:kFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ view.alpha = away ? 0 : 1; } completion:nil];
    }
}

// The largest files taken from Spotify: a Canvas is a few MB, an animated cover a little more; a song's lines with their
// words, translations and Latin letters a few hundred KB.
static const off_t kMostClipBytes = 50 * 1024 * 1024, kMostLyricsBytes = kSGLockLyricsMostBytes;

// Copies the regular file at `source` to `target`, opened once without following a link (O_NOFOLLOW) and checked on that
// descriptor (fstat), so what is checked is what is copied, and never more than `most` bytes of it. NO for a link, a
// directory, an empty or a larger file, or a failed write. On the share queue alone, which owns the buffer.
static BOOL copyRegularFile(NSURL *source, NSURL *target, off_t most) {
    int in = open(source.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (in < 0) return NO;
    struct stat info;
    if (fstat(in, &info) != 0 || !S_ISREG(info.st_mode) || info.st_size <= 0 || info.st_size > most) {
        close(in);
        return NO;
    }
    int out = open(target.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (out < 0) {
        close(in);
        return NO;
    }
    static char buffer[256 * 1024];
    off_t copied = 0;
    BOOL done = YES;
    for (;;) {
        ssize_t got = read(in, buffer, sizeof buffer);
        if (got == 0) break;
        if (got < 0 || copied + got > most) {
            done = NO;
            break;
        }
        for (ssize_t written = 0; written < got;) {
            ssize_t wrote = write(out, buffer + written, (size_t)(got - written));
            if (wrote <= 0) {
                done = NO;
                break;
            }
            written += wrote;
        }
        if (!done) break;
        copied += got;
    }
    close(in);
    if (close(out) != 0) done = NO;
    return done && copied > 0;
}

// Each new song's none: a copy that ends after it was posted is dropped, so a fast skip never shows the last song's
// clip or lyrics on the new one.
static atomic_uint sg_shareRun;

// A file of Spotify's caches into the jailbreak's shared caches, for MediaRemoteUI: copied beside it and moved over the
// last one, so a reader of the last one keeps its own file; `shared` posted once it is there. Any process can post the
// notification that starts it, so it is taken from Spotify alone (MediaRemoteUI's still cover is Spotify's alone too),
// off SpringBoard's main thread, as the copy crosses volumes, and only a regular file of at most `most` bytes.
static void share(NSString *name, NSString *sharedPath, const char *shared, off_t most) {
    if (!sg_getApp) return;
    unsigned run = atomic_load(&sg_shareRun);
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.vitrine.addon.share", DISPATCH_QUEUE_SERIAL); });
    sg_getApp(queue, ^(CFStringRef bundle) {
        NSString *identifier = (__bridge NSString *)bundle;
        if (![identifier isEqualToString:@"com.spotify.client"]) return;
        NSURL *container = [[NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:identifier] dataContainerURL];
        NSURL *source = [container URLByAppendingPathComponent:[@"Library/Caches/" stringByAppendingString:name]];
        if (!source) return;
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *target = [NSURL fileURLWithPath:sharedPath];
        [files createDirectoryAtURL:target.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSURL *staging = [target URLByAppendingPathExtension:@"part"];
        [files removeItemAtURL:staging error:nil];
        if (!copyRegularFile(source, staging, most)) {
            [files removeItemAtURL:staging error:nil];
            NSLog(@"[vitrine-addon] no %@ to take from Spotify", name);
            return;
        }
        if (atomic_load(&sg_shareRun) != run) {
            [files removeItemAtURL:staging error:nil];
            return;
        }
        NSError *error = nil;
        [files removeItemAtURL:target error:nil];
        if (![files moveItemAtURL:staging toURL:target error:&error]) {
            NSLog(@"[vitrine-addon] %@ not shared: %@", name, error.localizedDescription);
            return;
        }
        if (atomic_load(&sg_shareRun) == run) notify_post(shared);
    });
}

static NSString *const kLyricsPickedKey = @"lockLyricsPicked";

static BOOL sg_coverShowing;
static SGLockGestureAreaState sg_area;

// The catcher over the lyrics. Its window's points are the screen's, as the area's are.
@interface SGVLockTouchCatcher : UIView <UIGestureRecognizerDelegate>
@end

@implementation SGVLockTouchCatcher

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.backgroundColor = UIColor.clearColor;
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragged:)];
    pan.delegate = self;
    [self addGestureRecognizer:pan];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped:)]];
    return self;
}

// Only an up or down drag is the lyrics': a sideways one that starts in their band (to the camera, to the Today view)
// is left to the cover sheet.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (![recognizer isKindOfClass:UIPanGestureRecognizer.class]) return YES;
    UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)recognizer;
    CGPoint drag = [pan velocityInView:self];
    // A very slow drag can have no velocity on either axis: the distance it has moved says which way it goes.
    if (drag.x == 0 && drag.y == 0) drag = [pan translationInView:self];
    return fabs(drag.y) > fabs(drag.x);
}

// Whether the cover sheet's own views under the catcher have a player or a notification at `point`: the list scrolls
// them anywhere, the lyrics' band among them, and they keep their touches there.
- (BOOL)platterAt:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *sheet = self.superview;
    Class platter = NSClassFromString(@"PLPlatterView");
    for (UIView *sibling in sheet.subviews.reverseObjectEnumerator) {
        if (sibling == self || sibling.hidden || sibling.alpha < 0.01 || !sibling.userInteractionEnabled) continue;
        UIView *hit = [sibling hitTest:[self convertPoint:point toView:sibling] withEvent:event];
        if (!hit) continue;
        for (UIView *view = hit; view && view != sheet; view = view.superview) {
            if (platter && [view isKindOfClass:platter]) return YES;
        }
        return NO;
    }
    return NO;
}

// A player or a notification over the band is the list's.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return [super pointInside:point withEvent:event] && ![self platterAt:point withEvent:event];
}

// A drag or a tap's state for MediaRemoteUI, on a token kept for the name, since a drag sends one for every move.
static void tell(const char *name, int *token, uint64_t state) {
    if (!*token && notify_register_check(name, token) != NOTIFY_STATUS_OK) return;
    notify_set_state(*token, state);
    notify_post(name);
}

- (void)dragged:(UIPanGestureRecognizer *)pan {
    int phase = pan.state == UIGestureRecognizerStateBegan ? 0 : pan.state == UIGestureRecognizerStateChanged ? 1 : 2;
    if (phase == 2 && pan.state != UIGestureRecognizerStateEnded && pan.state != UIGestureRecognizerStateCancelled) return;
    static int token;
    tell(kSGRelayLockGesturePan, &token, SGLockGesturePan(phase, [pan translationInView:nil].y, [pan velocityInView:nil].y));
}

- (void)tapped:(UITapGestureRecognizer *)tap {
    static int token;
    tell(kSGRelayLockGestureTap, &token, SGLockGestureTap([tap locationInView:nil]));
}

@end

static SGVLockTouchCatcher *sg_catcher;

// The catcher where the lyrics are while MediaRemoteUI shows the large cover, gone when it does not.
static void placeCatcher(void) {
    UIView *sheet = sg_sheet;
    BOOL wanted = sg_coverShowing && sheet.window && sg_area.lyricsShown && sg_area.lyricsBottom > sg_area.lyricsTop;
    if (!wanted) {
        [sg_catcher removeFromSuperview];
        return;
    }
    if (!sg_catcher) sg_catcher = [[SGVLockTouchCatcher alloc] initWithFrame:CGRectZero];
    CGRect screen = CGRectMake(0, sg_area.lyricsTop, sheet.window.bounds.size.width, sg_area.lyricsBottom - sg_area.lyricsTop);
    if (sg_catcher.superview != sheet) [sheet addSubview:sg_catcher];
    else if (sheet.subviews.lastObject != sg_catcher) [sheet bringSubviewToFront:sg_catcher];
    CGRect frame = [sheet convertRect:screen fromView:nil];
    if (!CGRectEqualToRect(sg_catcher.frame, frame)) sg_catcher.frame = frame;
}

static NSUserDefaults *addonDefaults(void) {
    static NSUserDefaults *defaults;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ defaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.vitrine.addon"]; });
    return defaults;
}

static void tellPicked(void) {
    notify_post([addonDefaults() boolForKey:kLyricsPickedKey] ? kSGRelayLockModeLyrics : kSGRelayLockModeCanvas);
}

// The cover sheet lays itself out again as its list is dragged (the player, the clock or the notifications pulled), and
// its own views can come up over the catcher then: it goes back on top on every pass while the large cover is open.
%hook CSCoverSheetViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (sg_coverShowing) placeCatcher();
}
- (void)viewDidLoad {
    %orig;
    sg_sheet = ((UIViewController *)self).view;
}
%end

%ctor {
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.springboard"]) return;
    if (@available(iOS 26.0, *)) return;
    void *remote = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    sg_getApp = remote ? (SGMRGetApp)dlsym(remote, "MRMediaRemoteGetNowPlayingApplicationDisplayID") : NULL;
    %init;
    int clipToken, noneToken, showingToken, hiddenToken;
    notify_register_dispatch(kSGRelayLockClip, &clipToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockClipName, SGLockSharedClipPath(), kSGRelayLockClipShared, kMostClipBytes);
    });
    int lyricsToken, lyricsPickedToken, canvasPickedToken, askToken;
    notify_register_dispatch(kSGRelayLockLyrics, &lyricsToken, dispatch_get_main_queue(), ^(int t) {
        share(@kSGLockLyricsName, SGLockSharedLyricsPath(), kSGRelayLockLyricsShared, kMostLyricsBytes);
    });
    // The button's choice kept; a post of it here answers MediaRemoteUI, which hears its own the same way.
    notify_register_dispatch(kSGRelayLockModeLyrics, &lyricsPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:YES forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeCanvas, &canvasPickedToken, dispatch_get_main_queue(), ^(int t) {
        [addonDefaults() setBool:NO forKey:kLyricsPickedKey];
    });
    notify_register_dispatch(kSGRelayLockModeAsk, &askToken, dispatch_get_main_queue(), ^(int t) { tellPicked(); });
    tellPicked();
    notify_register_dispatch(kSGRelayLockClipNone, &noneToken, dispatch_get_main_queue(), ^(int t) {
        atomic_fetch_add(&sg_shareRun, 1);
        [NSFileManager.defaultManager removeItemAtPath:SGLockSharedClipPath() error:nil];
    });
    notify_register_dispatch(kSGRelayLockShowing, &showingToken, dispatch_get_main_queue(), ^(int t) {
        hideWidgets(YES);
        sg_coverShowing = YES;
        placeCatcher();
    });
    notify_register_dispatch(kSGRelayLockNotShowing, &hiddenToken, dispatch_get_main_queue(), ^(int t) {
        hideWidgets(NO);
        sg_coverShowing = NO;
        placeCatcher();
    });
    int areaToken;
    notify_register_dispatch(kSGRelayLockGestureArea, &areaToken, dispatch_get_main_queue(), ^(int t) {
        uint64_t state = 0;
        if (notify_get_state(t, &state) != NOTIFY_STATUS_OK) return;
        sg_area = SGLockGestureAreaRead(state);
        placeCatcher();
    });
}
