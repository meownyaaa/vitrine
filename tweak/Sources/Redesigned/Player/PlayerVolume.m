// Player redesign: a volume slider under the controls, as the Music app has. The row draws its own pill: it grows while
// held, its glyphs move out, a drag anywhere on the row moves the volume by the finger's travel, and VoiceOver steps it.
// Under it sits a hidden MPVolumeView whose slider the row reads and moves, so it is the system's volume: the hardware
// buttons move it. A Connect device's own volume reaches Spotify, not iOS, so the row does not show it. No route
// button: the footer's Connect glyph is the route.
//
// It sits in Spotify's bottom stack, outside its arranged views, between the controls and the footer row, so the
// lyrics fade it with the rest of the stack (PlayerLyrics.x) and its touches stay inside the stack. The footer's
// lowerRow (PlayerFooter.x) places it after the moves, and keeps the controls where Spotify put them to make the room.
// The stack's own layout runs that pass again (SGRObserveLayout): the stack moves its arranged views around with no pass
// of the footer (the lyrics, a track whose title wraps, a row that comes or goes), and the row stayed where the stack
// once had them, over the controls (continuous/1.txt: the row at 188 of a stack whose controls end at 212).
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Player.h"

// The row's height (the touch area) and the glyphs' point size and gap to the track.
static const CGFloat kRowHeight = 32, kGlyphSize = 13, kGlyphGap = 10;
// Half the footer glyphs' height: the row stops this far above their middle.
static const CGFloat kGlyphsHalf = 14;
// The track's height at rest and held, how far it grows past each end, how far the glyphs move out and by how much they
// scale (each clamped to the room the row has on that side). Music's own held numbers are 18, 7, 9 and 1.08.
static const CGFloat kTrackRest = 7, kTrackHeld = 12, kStretch = 5, kGlyphShift = 6, kGlyphHeldScale = 1.02;
// White's opacity: the fill at rest and held, the empty part, the glyphs at rest (held they are full white).
static const CGFloat kFillRest = 0.65, kFillHeld = 1, kEmpty = 0.24, kGlyphRest = 0.68;

static char kSessionContext;

static UIImageView *glyph(NSString *symbol) {
    UIImageSymbolConfiguration *configuration =
        [UIImageSymbolConfiguration configurationWithPointSize:kGlyphSize weight:UIImageSymbolWeightSemibold];
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:symbol withConfiguration:configuration]];
    view.tintColor = UIColor.whiteColor;
    view.alpha = kGlyphRest;
    view.contentMode = UIViewContentModeCenter;
    view.isAccessibilityElement = NO;
    return view;
}

@interface SGRVolumeRow : UIControl
// The footer row it was last placed against, for the stack's layout. Weak: the stack owns it.
@property (nonatomic, weak) UIView *footer;
- (UISlider *)systemSlider;
- (void)systemSliderSet;
@end

// MPVolumeView makes its slider when it lays out and may make another later, for example after a route change, so the
// row looks for it again after each of its layouts.
@interface SGRVolumeView : MPVolumeView
@end

@implementation SGRVolumeView

- (void)layoutSubviews {
    [super layoutSubviews];
    [(SGRVolumeRow *)self.superview systemSlider];
}

@end

@implementation SGRVolumeRow {
    MPVolumeView *_system;
    UISlider *_systemSlider;
    UIView *_track, *_fill;
    UIImageView *_quiet, *_loud;
    CGFloat _value, _startValue, _startX, _trackMin, _trackMax;
    BOOL _held;
    CFTimeInterval _lastPush;
    NSHashTable<UIGestureRecognizer *> *_suspended;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // Only plumbing: the slider inside moves the system's volume, nobody sees or touches the view.
    _system = [SGRVolumeView new];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    _system.showsRouteButton = NO;
#pragma clang diagnostic pop
    _system.alpha = 0.01;
    _system.userInteractionEnabled = NO;
    [self addSubview:_system];

    _track = [UIView new];
    _track.clipsToBounds = YES;
    _track.userInteractionEnabled = NO;
    _track.layer.cornerCurve = kCACornerCurveContinuous;
    _track.backgroundColor = [UIColor colorWithWhite:1 alpha:kEmpty];
    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    [_track addSubview:_fill];
    [self addSubview:_track];

    _quiet = glyph(@"speaker.fill");
    _loud = glyph(@"speaker.wave.3.fill");
    [self addSubview:_quiet];
    [self addSubview:_loud];

    _value = AVAudioSession.sharedInstance.outputVolume;
    [AVAudioSession.sharedInstance addObserver:self forKeyPath:@"outputVolume" options:NSKeyValueObservingOptionNew
                                       context:&kSessionContext];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refreshFromSystem)
                                               name:UIApplicationDidBecomeActiveNotification object:nil];

    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Volume";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}

- (void)dealloc {
    [self restoreAncestorGestures];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [AVAudioSession.sharedInstance removeObserver:self forKeyPath:@"outputVolume" context:&kSessionContext];
}

// The volume view builds its slider itself and may replace it, so the one it has now is looked for each time.
- (UISlider *)systemSlider {
    UISlider *current = nil;
    for (UIView *view in _system.subviews) {
        if (![view isKindOfClass:UISlider.class]) continue;
        current = (UISlider *)view;
        break;
    }
    if (current == _systemSlider) return current;

    _systemSlider = current;
    // Hide the system slider's visible artwork.
    current.thumbTintColor = UIColor.clearColor;
    current.minimumTrackTintColor = UIColor.clearColor;
    current.maximumTrackTintColor = UIColor.clearColor;
    return current;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != &kSessionContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self refreshFromSystem]; });
}

// Our own pushVolume sets the slider too, and refreshFromSystem skips that echo.
- (void)systemSliderSet {
    [self refreshFromSystem];
}

- (void)refreshFromSystem {
    // Not while the finger is on it, nor just after it let go: the system settles on its own steps a moment later.
    if (_held || CACurrentMediaTime() - _lastPush < 0.6) return;
    UISlider *slider = [self systemSlider];
    CGFloat system = slider ? slider.value : AVAudioSession.sharedInstance.outputVolume;
    if (fabs(system - _value) > 0.002) [self setValue:system fromUser:NO];
}

// The KVO the system sends as it settles falls inside the guard above, so the row reads it once the guard has passed.
- (void)refreshAfterPush {
    __weak SGRVolumeRow *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.65 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf refreshFromSystem];
    });
}

- (void)pushVolume {
    UISlider *slider = [self systemSlider];
    if (!slider) return;
    _lastPush = CACurrentMediaTime();
    [slider setValue:_value animated:NO];
    [slider sendActionsForControlEvents:UIControlEventValueChanged];
}

// The room the row has to either side inside its stack: what the held track and glyphs may grow into.
- (CGFloat)roomLeft { return MAX(0, CGRectGetMinX(self.frame)); }

- (CGFloat)roomRight {
    UIView *stack = self.superview;
    return stack ? MAX(0, stack.bounds.size.width - CGRectGetMaxX(self.frame)) : 0;
}

// The track's frame for the state it is in: it grows past both ends while held.
- (void)syncTrack {
    CGFloat height = _held ? kTrackHeld : kTrackRest;
    CGFloat left = _held ? MIN(kStretch, [self roomLeft]) : 0, right = _held ? MIN(kStretch, [self roomRight]) : 0;
    CGFloat scale = self.traitCollection.displayScale ?: 3;
    CGFloat top = round((CGRectGetMidY(self.bounds) - height / 2) * scale) / scale;
    _track.frame = CGRectMake(_trackMin - left, top, MAX(0, _trackMax - _trackMin) + left + right, height);
    _track.layer.cornerRadius = height / 2;
    [self syncFill];
}

// The fill is a plain rectangle the pill's clipping rounds, so its right edge stays straight, as in Music.
- (void)syncFill {
    CGSize size = _track.bounds.size;
    _fill.frame = CGRectMake(0, 0, size.width * _value, size.height);
}

- (void)syncStyle {
    _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:_held ? kFillHeld : kFillRest];
    CGFloat scale = _held ? kGlyphHeldScale : 1;
    CGFloat left = _held ? MIN(kGlyphShift, [self roomLeft]) : 0, right = _held ? MIN(kGlyphShift, [self roomRight]) : 0;
    CGAffineTransform grown = CGAffineTransformMakeScale(scale, scale);
    _quiet.transform = CGAffineTransformConcat(grown, CGAffineTransformMakeTranslation(-left, 0));
    _loud.transform = CGAffineTransformConcat(grown, CGAffineTransformMakeTranslation(right, 0));
    _quiet.alpha = _loud.alpha = _held ? 1 : kGlyphRest;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect bounds = self.bounds;
    CGFloat side = kRowHeight, middle = CGRectGetMidY(bounds), glyphWidth = side / 2 + kGlyphSize / 2;
    _system.frame = CGRectMake(0, 0, MAX(140, bounds.size.width), side);
    [_system layoutIfNeeded];
    [self systemSlider];
    CGFloat loudMin = CGRectGetMaxX(bounds) - side / 2 - kGlyphSize;
    _quiet.bounds = CGRectMake(0, 0, glyphWidth, side);
    _loud.bounds = CGRectMake(0, 0, glyphWidth, side);
    _quiet.center = CGPointMake(glyphWidth / 2, middle);
    _loud.center = CGPointMake(loudMin + glyphWidth / 2, middle);
    _trackMin = glyphWidth + kGlyphGap;
    _trackMax = loudMin - kGlyphGap;
    [self syncTrack];
    [self syncStyle];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        // A lock or a call can take the row off screen mid-drag, and then end or cancel tracking may not come.
        [self setHeld:NO];
        return;
    }
    [self systemSlider];
    [self refreshFromSystem];
}

// Prevent the player from stealing volume swipe gesture.
- (void)suspendAncestorGestures {
    if (_suspended) return;
    _suspended = [NSHashTable weakObjectsHashTable];
    for (UIView *view = self.superview; view; view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers) {
            BOOL pan = [recognizer isKindOfClass:UIPanGestureRecognizer.class];
            if (!pan || [recognizer isKindOfClass:UIScreenEdgePanGestureRecognizer.class] || !recognizer.enabled) continue;
            recognizer.enabled = NO;
            [_suspended addObject:recognizer];
        }
    }
}

- (void)restoreAncestorGestures {
    for (UIGestureRecognizer *recognizer in _suspended) recognizer.enabled = YES;
    _suspended = nil;
}

- (void)setValue:(CGFloat)value fromUser:(BOOL)fromUser {
    value = MIN(1, MAX(0, value));
    _value = value;
    if (!fromUser && !_held && self.window) {
        UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction |
                                         UIViewAnimationOptionCurveEaseOut;
        [UIView animateWithDuration:0.15 delay:0 options:options animations:^{ [self syncFill]; } completion:nil];
    } else {
        [self syncFill];
    }
    if (fromUser) [self pushVolume];
}

- (void)setHeld:(BOOL)held {
    if (_held == held) return;
    _held = held;
    if (held) {
        [self suspendAncestorGestures];
    } else {
        [self restoreAncestorGestures];
        [self refreshAfterPush];
    }
    void (^apply)(void) = ^{ [self syncTrack]; [self syncStyle]; };
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    if (held) {
        [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:options
                         animations:apply completion:nil];
    } else {
        [UIView animateWithDuration:0.16 delay:0 options:options | UIViewAnimationOptionCurveEaseOut
                         animations:apply completion:nil];
    }
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    _startX = [touch locationInView:self].x;
    _startValue = _value;
    [self setHeld:YES];
    return YES;
}

// Relative to where the finger came down: the value moves by the finger's travel over the track's length.
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    CGFloat span = MAX(1, _trackMax - _trackMin);
    [self setValue:_startValue + ([touch locationInView:self].x - _startX) / span fromUser:YES];
    return YES;
}

- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { [self setHeld:NO]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { [self setHeld:NO]; }

- (NSString *)accessibilityValue { return [NSString stringWithFormat:@"%d%%", (int)round(_value * 100)]; }
- (void)accessibilityIncrement {
    [self setValue:_value + 0.0625 fromUser:YES];
    [self refreshAfterPush];
}

- (void)accessibilityDecrement {
    [self setValue:_value - 0.0625 fromUser:YES];
    [self refreshAfterPush];
}

@end

static char kVolumeKey, kPlayKey, kSettleKey;
// Passes the footer's layout is asked for again while the row's place keeps changing, at most.
static const NSUInteger kSettlePasses = 6;

// Read at launch, as the player's other switches are: the footer asks on every layout pass.
BOOL SGRPlayerVolumeOn(void) {
    static BOOL on;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ on = SGEnabled(SGRKeyPlayerVolume); });
    return on;
}

// The footer lays out before Spotify's bottom stack has arranged its views the first time the player opens (the
// controls then stand near the stack's top), and nothing lays the footer out again once the stack has: the row was
// placed against the controls' old place and stayed there, over their buttons. A row that moved asks the footer's
// layout once more on the next turn of the run loop, which finds the settled places; one that did not move ends it.
static void settle(UIView *stack, UIView *row, BOOL moved, CGRect frame) {
    NSUInteger passes = [objc_getAssociatedObject(stack, &kSettleKey) unsignedIntegerValue];
    if (!moved) {
        if (passes) objc_setAssociatedObject(stack, &kSettleKey, @0, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    if (passes >= kSettlePasses) return;
    objc_setAssociatedObject(stack, &kSettleKey, @(passes + 1), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (passes > 0) SGLog(@"redesign player: volume row placed again at %.0f (pass %lu)", frame.origin.y, (unsigned long)passes + 1);
    __weak UIView *weakStack = stack, *weakRow = row;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *settledStack = weakStack, *settledRow = weakRow;
        if (!settledStack.window || !settledRow.window) return;
        [settledStack layoutIfNeeded];
        SGRPlayerLowerRow(settledRow);
    });
}

BOOL SGRPlayerPlaceVolume(UIView *stack, UIView *controls, UIView *row, CGFloat margin) {
    SGRVolumeRow *volume = objc_getAssociatedObject(stack, &kVolumeKey);
    if (!SGRPlayerVolumeOn() || !controls) {
        if (volume) volume.alpha = 0;
        return NO;
    }
    if (!volume) {
        volume = [SGRVolumeRow new];
        objc_setAssociatedObject(stack, &kVolumeKey, volume, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        SGRObserveLayout(stack, ^(UIView *laidOut) {
            SGRVolumeRow *placed = objc_getAssociatedObject(laidOut, &kVolumeKey);
            UIView *footer = placed.footer;
            if (footer.superview == laidOut) SGRPlayerLowerRow(footer);
        });
    }
    if (volume.superview != stack) [stack addSubview:volume];
    volume.footer = row;
    // Halfway between the play button's bottom and the footer glyphs' top, each where it is drawn (convertRect: takes
    // the moves' transforms in). Without the button there is nothing to stand under: a guess from the controls' unit
    // put the row across the buttons on an iPhone 13 Pro with iOS 17 (issue #32) and took their taps, so no row.
    UIView *play = SGRFindByIdentifier(controls, @"SPTNowPlayingPlayButton", &kPlayKey);
    if (!play) {
        static BOOL logged;
        if (!logged) {
            logged = YES;
            SGLog(@"redesign player: no play button in %@, so no volume row", NSStringFromClass(controls.class));
        }
        volume.alpha = 0;
        return NO;
    }
    CGFloat above = CGRectGetMaxY([play convertRect:play.bounds toView:stack]);
    CGFloat below = [row convertPoint:CGPointMake(CGRectGetMidX(row.bounds), CGRectGetMidY(row.bounds)) toView:stack].y - kGlyphsHalf;
    CGFloat height = kRowHeight, room = below - above;
    CGRect frame = CGRectMake(margin, round((above + below - height) / 2), MAX(0, stack.bounds.size.width - 2 * margin), height);
    BOOL moved = !CGRectEqualToRect(volume.frame, frame);
    if (moved) volume.frame = frame;
    settle(stack, row, moved, frame);
    // The lyrics fade the stack's views by their alpha and bring back only the ones they faded.
    // The track is 7pt of the row's 32: it fits with the glyphs' and buttons' own clearance around it.
    BOOL fits = room >= height * 0.6;
    if (!fits) volume.alpha = 0;
    else if (volume.alpha < 0.01 && controls.alpha > 0.99) volume.alpha = 1;
    return fits;
}

// MPVolumeSlider takes an outside change (AirPlay, Connect) through super's setValue:animated:, which sends no KVO, and
// sends ValueChanged only when the change shows the system's HUD, which Spotify's own Connect HUD turns off.
void SGRPlayerVolumeSliderSet(UISlider *slider) {
    UIView *row = slider.superview.superview;
    if (![slider.superview isKindOfClass:SGRVolumeView.class] || ![row isKindOfClass:SGRVolumeRow.class]) return;
    if (slider != ((SGRVolumeRow *)row).systemSlider) return;
    dispatch_async(dispatch_get_main_queue(), ^{ [(SGRVolumeRow *)row systemSliderSet]; });
}
