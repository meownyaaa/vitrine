// A local file's own cover where the native player shows Spotify's placeholder (Shared/LocalFiles/
// LocalCover.m finds it). Spotify's player keeps a list of covers scrolled sideways, a cell per track in
// the queue (Native/Player/Player.x), and the cell under the list's middle is the one playing; the cover
// is the largest image view in it, 354pt across, with a 64pt glyph standing in while it has no picture.
// The cover is put into that image view only while it has none. A cover-tilt view outside the list (the
// cover inspected full screen) gets the same.
//
// A picture of the mod's is remembered with the track it was put in for, so a cell reused for another
// track loses it, and Spotify's own picture, once it comes, is never replaced.
#import "Core/SGCore.h"
#import "Headers/SPTPlayer.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Shared/Player/PlayerState.h"

static const CGFloat kCoverMinWidth = 200;
static char kImageKey, kTrackKey;
static __weak UIScrollView *sg_list;
// The image views holding a picture of the mod's, weakly.
static NSHashTable<UIImageView *> *sg_filled;

static BOOL isCoverCell(UIView *view) {
    static Class cell, legacy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cell = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl");
        legacy = NSClassFromString(@"_TtC28NowPlaying_ContentLayersImpl22LegacyCoverArtCellImpl");
    });
    return (cell && [view isKindOfClass:cell]) || (legacy && [view isKindOfClass:legacy]);
}

static UIImageView *largestImageIn(UIView *root) {
    __block UIImageView *largest = nil;
    __block CGFloat widest = kCoverMinWidth;
    SGForEachView(root, ^(UIView *view) {
        if (![view isKindOfClass:UIImageView.class] || view.bounds.size.width < widest) return;
        widest = view.bounds.size.width;
        largest = (UIImageView *)view;
    });
    return largest;
}

static void fill(UIImageView *view) {
    if (!view) return;
    BOOL ours = view.image && view.image == objc_getAssociatedObject(view, &kImageKey);
    if (view.image && !ours) return;
    SPTPlayerTrack *track = SGPlayerState().track;
    NSString *uri = SGURIString(track.URI);
    if (ours && [uri isEqualToString:objc_getAssociatedObject(view, &kTrackKey)]) return;
    UIImage *cover = SGLocalFileFallbackCover(track);
    if (!cover && !ours) return;
    view.image = cover;
    objc_setAssociatedObject(view, &kImageKey, cover, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kTrackKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!sg_filled) sg_filled = [NSHashTable weakObjectsHashTable];
    if (cover) [sg_filled addObject:view]; else [sg_filled removeObject:view];
}

// With no picture of the mod's on screen and no local file playing, fill changes nothing (no view is
// ours, and SGLocalFileFallbackCover answers nil for any other track before doing anything), so the
// walk for the image view is spared on every layout of the list.
static BOOL nothingToFill(void) {
    // A weak table's count can still include freed views; enumeration skips them.
    for (__unused UIView *view in sg_filled) return NO;
    return !SGLocalFileIs(SGURIString(SGPlayerState().track.URI));
}

static void fillFront(UIScrollView *list) {
    CGFloat middle = list.contentOffset.x + list.bounds.size.width / 2;
    BOOL idle = nothingToFill();
    for (UIView *cell in list.subviews) {
        if (!isCoverCell(cell) || middle < CGRectGetMinX(cell.frame) || middle > CGRectGetMaxX(cell.frame)) continue;
        sg_list = list;
        if (!idle) fill(largestImageIn(cell));
    }
}

// The track changing, or the now playing info catching up with it a moment later, lays nothing out.
@interface SGLocalCoverWatcher : NSObject <SGPlayerStateObserver>
@end

@implementation SGLocalCoverWatcher
- (void)playerStateDidChange:(SPTPlayerState *)state {
    for (NSNumber *delay in @[@0, @1.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UIScrollView *list = sg_list;
            if (list.window) fillFront(list);
        });
    }
}
@end

%hook _TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView
- (void)layoutSubviews {
    %orig;
    fillFront((UIScrollView *)self);
}
%end

%hook _TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView
- (void)layoutSubviews {
    %orig;
    UIView *tilt = (UIView *)self;
    if (tilt.bounds.size.width < kCoverMinWidth) return;
    // In the list the front cell is the list's to fill; elsewhere, only inside the player, since album
    // pages show their covers in the same view.
    BOOL player = NO;
    for (UIView *view = tilt.superview; view; view = view.superview) {
        if (isCoverCell(view)) return;
        player = player || SGClassNamed(view.class, @"NowPlaying");
    }
    if (player && !nothingToFill()) fill(largestImageIn(tilt));
}
%end

%ctor {
    if (!SGNativeUI()) return;
    %init;
    static SGLocalCoverWatcher *watcher;
    watcher = [SGLocalCoverWatcher new];
    SGAddPlayerStateObserver(watcher);
    SGRequireClasses(@[
        @"_TtC35NowPlaying_ContentLayerPlatformImpl24AccessibleCollectionView",
        @"_TtC35CreativeWorkCommons_CoverArtTiltKit16CoverArtTiltView",
        @"_TtC28NowPlaying_ContentLayersImpl16CoverArtCellImpl",
    ]);
}
