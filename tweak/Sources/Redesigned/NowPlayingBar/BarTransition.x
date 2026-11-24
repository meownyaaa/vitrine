// The now playing bar and the tab bar keep their glass while the player opens and closes.
//
// Spotify does not move the real bars with the player: it hides them and moves stand-ins, made once at
// the start. -[SPTBarOverlayPresentationTransition setupTransitioningContext:] takes the bar's with
// -snapshotViewAfterScreenUpdates: when the player opens, but with -[CALayer renderInContext:] into a
// UIImageView when it closes, and the tab bar's that way too when it closes over a compact tab bar.
// renderInContext: cannot draw glass (UIVisualEffectView, UIKit's tab bar platters, and our own
// SGLegacyGlassView, a CABackdropLayer), so every close showed the bar's artwork and title and the tab
// bar's glyphs and white film floating on nothing, and the glass popped back in when the real bars
// returned. Checked in the simulator: a snapshot view keeps the glass, a rendered image loses all of it.
//
// A stand-in that is an image gets live glass behind it, copied pane by pane from the view it was
// taken of, with the image moved into a child on top, so it moves and fades with Spotify's own frame
// and alpha changes. Live glass at half alpha still renders (simulator). The tab bar's selection bubble
// is not copied.
//
// A stand-in that is a snapshot view (the open) cannot take children behind its own picture, and below
// iOS 26 a snapshot does not carry a CABackdropLayer either. There the copies live in a holder right under
// the stand-in, and a display link copies the stand-in's presentation layer onto the holder every frame, so
// the glass rides along with whatever Spotify animates. While the tab bar's stand-in is up the real tab bar
// is held at an alpha of kHiddenAlpha rather than hidden (a hidden view captures its backdrop afresh when it
// returns, and the close blinked for a frame); it comes back when the stand-in leaves its window, or after a
// failsafe. The player bar's real view is left alone: Spotify hides that one itself.
//
// MainUI_TabBarUIImpl.CompactOverlayTransition is a Swift animator with the same stand-ins
// (npbSnapshotView, tabBarSnapshotView); which of the two 9.1.78 runs is not known, so both are hooked
// and the log says which fired.
#import "Core/SGCore.h"
#import "Redesigned/NowPlayingBar/NowPlayingBar.h"

@interface SPTBarOverlayPresentationTransition : NSObject
- (UIView *)bottomBarView;
- (UIView *)tabBarView;
@end

// The panes to copy: glass views, our legacy glass below iOS 26, and UIKit's tab bar platters, whose
// glass is not a UIVisualEffectView. The source itself may be hidden: Spotify renders the closed bar and
// hides it again before handing the image over.
static void collectPanes(UIView *view, NSMutableArray<UIView *> *panes) {
    for (UIView *sub in view.subviews) {
        if (sub.hidden || sub.alpha < 0.01) continue;
        // A pane the bar has switched off (SGRShowGlass takes a blur's effect away rather than its alpha, as
        // the minimized bar does with its capsule) draws nothing, and its copy would stand there as a bar.
        if ([sub isKindOfClass:UIVisualEffectView.class] && !((UIVisualEffectView *)sub).effect) continue;
        if ([sub isKindOfClass:UIVisualEffectView.class] || [sub isKindOfClass:SGLegacyGlassView.class]
            || [NSStringFromClass(sub.class) hasSuffix:@"PlatterView"]) {
            [panes addObject:sub];
            continue;
        }
        collectPanes(sub, panes);
    }
}

static UIVisualEffectView *copyPane(UIView *pane) {
    BOOL platter = ![pane isKindOfClass:UIVisualEffectView.class];
    UIVisualEffect *effect = platter ? SGGlassEffect() : ((UIVisualEffectView *)pane).effect;
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:effect];
    glass.userInteractionEnabled = NO;
    // The effect does not carry the appearance the pane was drawn in, dark for both bars, and the stand-in
    // would give the copy the system's.
    glass.overrideUserInterfaceStyle = pane.traitCollection.userInterfaceStyle;
    if (platter) {
        SGShapeGlass(glass, pane.bounds.size.height / 2, YES);
    } else if ([pane respondsToSelector:@selector(cornerConfiguration)] && [glass respondsToSelector:@selector(setCornerConfiguration:)]) {
        [glass setCornerConfiguration:[(id)pane cornerConfiguration]];
    }
    glass.layer.cornerRadius = pane.layer.cornerRadius;
    glass.layer.cornerCurve = pane.layer.cornerCurve;
    glass.clipsToBounds = pane.clipsToBounds;
    return glass;
}

// One copy of a pane at `frame` (already in the stand-in's coordinates). A legacy pane is copied as a
// legacy pane with all of the original's settings, its shape, blur, lens and clearness; it builds its mesh for the
// copy's own size. With the corners alone it took the default blur and lens, so the tab bar's stand-in was another
// bar from the one it stood in for, and the real one came back looking different.
static UIView *copyGlass(UIView *pane, CGRect frame) {
    UIView *glass;
    if ([pane isKindOfClass:SGLegacyGlassView.class]) {
        SGLegacyGlassView *source = (SGLegacyGlassView *)pane;
        SGLegacyGlassView *legacy = [[SGLegacyGlassView alloc] initWithFrame:frame];
        legacy.userInteractionEnabled = NO;
        legacy.overrideUserInterfaceStyle = pane.traitCollection.userInterfaceStyle;
        legacy.capsule = source.capsule;
        legacy.cornerRadius = source.capsule ? pane.layer.cornerRadius : source.cornerRadius;
        // Clear first: it sets a blur of its own, which the original's then replaces.
        legacy.clear = source.clear;
        legacy.blurRadius = source.blurRadius;
        legacy.magnification = source.magnification;
        legacy.lensScale = source.lensScale;
        legacy.sharp = source.sharp;
        legacy.rimless = source.rimless;
        glass = legacy;
    } else {
        glass = copyPane(pane);
        glass.frame = frame;
    }
    glass.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleWidth
        | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleHeight;
    return glass;
}

static CGRect scaledFrame(UIView *pane, UIView *source, CGSize to) {
    CGSize from = source.bounds.size;
    CGFloat sx = from.width > 0 ? to.width / from.width : 1, sy = from.height > 0 ? to.height / from.height : 1;
    CGRect frame = [pane.superview convertRect:pane.frame toView:source];
    return CGRectMake(frame.origin.x * sx, frame.origin.y * sy, frame.size.width * sx, frame.size.height * sy);
}

#pragma mark - stand-in that is a snapshot view

@interface SGStandInGlass : NSObject
@property (nonatomic, weak) UIView *snapshot;
@property (nonatomic, weak) UIView *source;
@property (nonatomic, copy) NSArray<UIView *> *panes;
@property (nonatomic, copy) NSArray<UIView *> *hidden;   // the real views hidden while the stand-in is up
@property (nonatomic, strong) UIView *holder;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic) BOOL hideRealBar;                  // the real bar must not show under the stand-in
@property (nonatomic) BOOL watchOnly;                     // the glass already sits inside the stand-in
@property (nonatomic) BOOL seen;                          // the stand-in has been in a window
@property (nonatomic) NSUInteger waited;
@property (nonatomic) CFTimeInterval born;
@end

// Alive while the display link is: it retains its target, and stop breaks that.
static NSMutableSet<SGStandInGlass *> *sg_followers;

// Who has hidden which real view, and how many stand-ins are holding it hidden. Two stand-ins can overlap
// (letting go of a drag makes Spotify's transition hand over a fresh one while the first is still being
// taken down). With a plain hidden flag the second found the view already hidden and took no part in
// it, and the first one's restore then showed the real bar under the second stand-in.
// "Hidden" is an alpha of kHiddenAlpha, so the view's glass keeps drawing; the alpha it had comes back.
static const CGFloat kHiddenAlpha = 0.02;
static NSMapTable<UIView *, NSNumber *> *sg_hiddenCounts;
static NSMapTable<UIView *, NSNumber *> *sg_savedAlpha;

static BOOL hiddenByUs(UIView *view) {
    return [sg_hiddenCounts objectForKey:view] != nil;
}

static void hideCounted(UIView *view) {
    if (!sg_hiddenCounts) {
        sg_hiddenCounts = [NSMapTable weakToStrongObjectsMapTable];
        sg_savedAlpha = [NSMapTable weakToStrongObjectsMapTable];
    }
    NSUInteger count = [sg_hiddenCounts objectForKey:view].unsignedIntegerValue;
    [sg_hiddenCounts setObject:@(count + 1) forKey:view];
    if (count) return;
    // A bar already faded out when the stand-in takes it (Spotify fades the real bar itself as the player opens
    // or closes) must not have that faded alpha saved, or the restore would put back an invisible bar and the
    // tab bar would be gone after the player closes. A bar is only ever hidden by us to be shown whole again.
    CGFloat alpha = view.alpha;
    [sg_savedAlpha setObject:@(alpha > 0.5 ? alpha : 1) forKey:view];
    [UIView performWithoutAnimation:^{ view.alpha = kHiddenAlpha; }];
}

static void showCounted(UIView *view) {
    NSUInteger count = [sg_hiddenCounts objectForKey:view].unsignedIntegerValue;
    if (count > 1) {
        [sg_hiddenCounts setObject:@(count - 1) forKey:view];
        return;
    }
    CGFloat alpha = [sg_savedAlpha objectForKey:view] ? [sg_savedAlpha objectForKey:view].doubleValue : 1;
    [sg_hiddenCounts removeObjectForKey:view];
    [sg_savedAlpha removeObjectForKey:view];
    [UIView performWithoutAnimation:^{ view.alpha = alpha; }];
}

static void startWatch(void);

@implementation SGStandInGlass

- (void)start {
    if (!sg_followers) sg_followers = [NSMutableSet set];
    [sg_followers addObject:self];
    startWatch();
    self.born = CACurrentMediaTime();
    if (self.hideRealBar) [self hideReal];
    self.link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    // Uncapped, or the player's 120 Hz transitions are dragged down to 60 with it (AGENTS.md).
    self.link.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self tick:nil];
}

- (void)stop {
    [self.link invalidate];
    self.link = nil;
    [self.holder removeFromSuperview];
    [self restoreReal];
    [sg_followers removeObject:self];
}

// The stand-in has been on screen and is not any more. Also called from the pre-commit watch below, so
// it must not depend on the display link having ticked.
- (BOOL)gone {
    UIView *snapshot = self.snapshot;
    if (!snapshot) return YES;
    if (snapshot.window) self.seen = YES;
    return self.seen && !snapshot.window;
}

// The superview of each real glass pane holds the rest of that bar (icons, film, selection bubble), so
// hiding the pane alone would leave the bar's icons standing under the stand-in's.
- (void)hideReal {
    NSMutableArray<UIView *> *hid = [NSMutableArray array];
    for (UIView *pane in self.panes) {
        UIView *host = pane.superview;
        if (!host || [hid containsObject:host]) continue;
        // Hidden by someone else (Spotify): not ours to bring back. Hidden by another stand-in of ours:
        // join it, so the view stays hidden until the last of them is gone.
        if (host.hidden && !hiddenByUs(host)) continue;
        hideCounted(host);
        [hid addObject:host];
    }
    self.hidden = hid;
}

- (void)restoreReal {
    NSArray<UIView *> *hid = self.hidden;
    self.hidden = nil;
    for (UIView *v in hid) showCounted(v);
}

- (void)attachTo:(UIView *)parent below:(UIView *)snapshot {
    UIView *source = self.source;
    if (!self.holder) {
        self.holder = [UIView new];
        self.holder.userInteractionEnabled = NO;
        self.holder.backgroundColor = UIColor.clearColor;
        CGSize to = snapshot.bounds.size;
        for (UIView *pane in self.panes) {
            if (source) [self.holder addSubview:copyGlass(pane, scaledFrame(pane, source, to))];
        }
    }
    [parent insertSubview:self.holder belowSubview:snapshot];
}

- (void)tick:(CADisplayLink *)link {
    UIView *snapshot = self.snapshot;
    // 30 s is only a failsafe against a stand-in that is never taken down, so a real bar cannot stay hidden.
    if (!snapshot || CACurrentMediaTime() - self.born > 30) { [self stop]; return; }
    UIView *parent = snapshot.superview;
    if (snapshot.window) self.seen = YES;
    if (!parent || (!snapshot.window && self.seen)) {
        // Not added yet (the setter runs before Spotify adds it), or gone for good.
        if (self.seen || ++self.waited > 30) [self stop];
        return;
    }
    if (self.watchOnly) return;
    if (self.holder.superview != parent) [self attachTo:parent below:snapshot];
    // The presentation layer is where the stand-in is drawn right now, mid-animation included.
    CALayer *now = snapshot.layer.presentationLayer ?: snapshot.layer;
    CALayer *mine = self.holder.layer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    mine.anchorPoint = now.anchorPoint;
    mine.bounds = now.bounds;
    mine.position = now.position;
    mine.transform = now.transform;
    mine.opacity = now.opacity;
    mine.hidden = snapshot.layer.hidden;
    [CATransaction commit];
}

@end

// Runs at the end of every run loop turn, before Core Animation commits (its observer is at order 2000000).
// The stand-in is taken down by Spotify in some turn; the real bar has to be shown again in that same
// turn, or one frame goes out with neither (the display link only ticks at the next vsync).
static CFRunLoopObserverRef sg_watch;

static void startWatch(void) {
    if (sg_watch) return;
    sg_watch = CFRunLoopObserverCreateWithHandler(kCFAllocatorDefault, kCFRunLoopBeforeWaiting | kCFRunLoopExit, YES, 1000000,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            if (!sg_followers.count) return;
            for (SGStandInGlass *follower in [sg_followers allObjects]) {
                if ([follower gone]) [follower stop];
            }
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), sg_watch, kCFRunLoopCommonModes);
}

// A tab bar stand-in the player's morph has dropped (PlayerMorph.x): the real bar stays in view, so it is neither
// backed with glass nor does it hold the real bar hidden.
static char kDroppedKey;

void SGRTabBarStandInDropped(UIView *standIn) {
    if (!standIn) return;
    objc_setAssociatedObject(standIn, &kDroppedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // One that was taken up before the morph dropped it gives the real bar back now, in the same turn.
    for (SGStandInGlass *follower in [sg_followers allObjects]) {
        if (follower.snapshot == standIn) [follower stop];
    }
}

static void backWithGlass(UIView *snapshot, UIView *source, NSString *what, BOOL hideRealBar) {
    if (!snapshot || !source) return;
    if (objc_getAssociatedObject(snapshot, &kDroppedKey)) return;
    NSMutableArray<UIView *> *panes = [NSMutableArray array];
    collectPanes(source, panes);
    if (!panes.count) return;

    // The stand-in that follows the player and hides the real bar is for the legacy glass, whose backdrop a
    // snapshot loses. From iOS 26 the system's glass is kept by the snapshot, so nothing is done there.
    BOOL legacy = SGUseLegacyGlass();
    if (![snapshot isKindOfClass:UIImageView.class]) {
        if (!legacy) return;
        SGStandInGlass *follower = [SGStandInGlass new];
        follower.snapshot = snapshot;
        follower.source = source;
        follower.panes = panes;
        follower.hideRealBar = hideRealBar;
        [follower start];
        return;
    }

    UIImageView *image = (UIImageView *)snapshot;
    if (!image.image || image.subviews.count) return;
    for (UIView *pane in panes) {
        [image addSubview:copyGlass(pane, scaledFrame(pane, source, image.bounds.size))];
    }
    UIImageView *content = [[UIImageView alloc] initWithImage:image.image];
    content.frame = image.bounds;
    content.contentMode = image.contentMode;
    content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    image.image = nil;
    [image addSubview:content];

    // The glass is inside the stand-in now; all that is left is keeping the real bar out from under it.
    if (hideRealBar && legacy) {
        SGStandInGlass *watch = [SGStandInGlass new];
        watch.snapshot = snapshot;
        watch.source = source;
        watch.panes = panes;
        watch.hideRealBar = YES;
        watch.watchOnly = YES;
        [watch start];
    }

    static NSUInteger logged;
    if (logged++ < 4) SGLog(@"player transition: %@ stand-in got %lu glass panes", what, (unsigned long)panes.count);
}

%hook SPTBarOverlayPresentationTransition
- (void)setBarSnapshotView:(UIView *)view {
    backWithGlass(view, [self bottomBarView], @"bar", NO);
    %orig;
}
- (void)setTabBarSnapshotView:(UIView *)view {
    backWithGlass(view, [self tabBarView], @"tab bar", YES);
    %orig;
}
%end

static id ivarNamed(id object, const char *name) {
    Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
    return ivar ? object_getIvar(object, ivar) : nil;
}

%hook _TtC19MainUI_TabBarUIImpl24CompactOverlayTransition
- (void)animateTransition:(id)context {
    %orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ SGLog(@"player transition: CompactOverlayTransition animates, snapshots %@ / %@",
                                  [ivarNamed(self, "npbSnapshotView") class], [ivarNamed(self, "tabBarSnapshotView") class]); });
    backWithGlass(ivarNamed(self, "npbSnapshotView"), ivarNamed(self, "npbView"), @"bar", NO);
    backWithGlass(ivarNamed(self, "tabBarSnapshotView"), ivarNamed(self, "tabBarView"), @"tab bar", YES);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    %init;
    SGRequireClasses(@[
        @"SPTBarOverlayPresentationTransition",
        @"_TtC19MainUI_TabBarUIImpl24CompactOverlayTransition",
    ]);
}
