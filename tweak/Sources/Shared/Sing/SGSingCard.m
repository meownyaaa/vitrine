// The top of the Sing page (SingSettings.m): the song Spotify has (else the last one played, else Not Playing,
// Shared/Player/SGLastTrack.h), its title and artist gliding when too long, what Sing is doing in words, two lines
// that trace the loudness of the vocals and of the rest of the song as heard, play and pause, and a tall slider for
// the vocals' level; under the card, three stops for the level.
//
// The lines are read from the engine thirty times a second (SGSingReadLevels: a few atomic reads, measured on its
// worker), in every run loop mode so they move on while the page scrolls. They move as the engine's own tenths
// do, which come with its renders rather than on the wall clock's tenths: each time the tenths move on, the lines
// are drawn again and glide in from where they were on screen at a tenth's width per tenth of a second, on Core
// Animation alone, with no display link; while none come (a pause), they rest. With Sing off, loading or held they
// lie flat. Under Reduce Motion they do not scroll: they are redrawn in place every two seconds.
//
// Reading the lines is how Sing knows the page shows ("the lines" in its log are these two, not the lyrics' lines):
// at As sung with Spatial voice off, where Sing otherwise rests, it separates the playing song while they are read,
// so the lines move and the slider and the three stops are heard at once, and rests again a second after the last
// read. The timer stops with the page off screen (popped, or covered by another page) and while Spotify is in the
// background. At any other level Sing separates whether the page shows or not. Every other gate
// (the switch, the model, the heat, memory, Runs on, the model kept a minute after resting) stays Sing.x's.
//
// Threading: main thread.
#import "Core/SGCore.h"
#import "Core/SGGlass.h"
#import "Settings/SGMarquee.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import "Shared/Player/SGLastTrack.h"
#import "Sing.h"

enum { kHistory = 48 };                  // tenths of a second across the card
static const NSTimeInterval kTick = 0.1;
// How often the lines are read, and the most tenths a glide catches up by before the rest is jumped.
static const NSTimeInterval kPoll = 1.0 / 30;
static const int kMostBehind = 2;
static const float kLevelStep = 0.05f;   // the slider snaps to this, as the mic's does
static const CGFloat kCardHeight = 232, kInset = 16, kColumn = 64;

// Loudness as the lines draw it, 0 at -48 dB to 1 at -6 dB.
static CGFloat height(float rms) {
    return rms > 0 ? fmax(0, fmin(1, (20 * log10(rms) + 48) / 42)) : 0;
}

#pragma mark - the level's slider

// From gone at the bottom through as sung at the middle (a mark across it) to the vocals alone at the top.
@interface SGSingLevelColumn : UIControl
@property (nonatomic) float level;
@end

@implementation SGSingLevelColumn {
    UIView *_fill, *_mark;
    UIImageView *_glyph;
    UISelectionFeedbackGenerator *_feedback;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    // Glass over the card's flat gray shows little of itself, so a light wash gives the track its shape.
    UIVisualEffectView *glass = SGGlassFor(self, @selector(initWithFrame:));
    glass.userInteractionEnabled = NO;
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    _fill = [UIView new];
    _fill.backgroundColor = [UIColor colorWithWhite:0.94 alpha:1];
    _fill.userInteractionEnabled = NO;
    [self addSubview:_fill];
    _mark = [UIView new];
    _mark.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    _mark.userInteractionEnabled = NO;
    [self addSubview:_mark];
    _glyph = SGSymbolView(@"music.mic", 20, UIImageSymbolWeightSemibold, 28);
    [self addSubview:_glyph];
    self.clipsToBounds = YES;
    _feedback = [UISelectionFeedbackGenerator new];
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Vocals";
    self.accessibilityTraits = UIAccessibilityTraitAdjustable;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    SGShapeGlass(SGGlassFor(self, @selector(initWithFrame:)), size.width / 2, YES);
    self.layer.cornerRadius = size.width / 2;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    CGFloat filled = size.height * self.level / 2;
    _fill.frame = CGRectMake(0, size.height - filled, size.width, filled);
    _mark.frame = CGRectMake(size.width * 0.3, size.height / 2 - 0.5, size.width * 0.4, 1);
    _mark.backgroundColor = self.level > 1 ? [UIColor colorWithWhite:0 alpha:0.25] : [UIColor colorWithWhite:1 alpha:0.35];
    _glyph.center = CGPointMake(size.width / 2, size.height - size.width / 2);
    // Dark over the fill, light over the glass.
    _glyph.tintColor = filled > size.width / 2 + 12 ? UIColor.blackColor : UIColor.whiteColor;
}

- (void)setLevel:(float)level {
    _level = fmaxf(0, fminf(level, 2));
    self.accessibilityValue = SGSingLevelText(_level);
    [self setNeedsLayout];
}

- (void)setAndSend:(float)level {
    level = roundf(level / kLevelStep) * kLevelStep;
    if (level == _level) return;
    // A tick at each stop the segments below name.
    if (floorf(level) != floorf(_level) || level == 2) [_feedback selectionChanged];
    self.level = level;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

- (float)levelAt:(UITouch *)touch {
    CGFloat y = [touch locationInView:self].y;
    return (float)(2 * (1 - y / self.bounds.size.height));
}

- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [_feedback prepare];
    [self setAndSend:[self levelAt:touch]];
    return YES;
}

- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    [self setAndSend:[self levelAt:touch]];
    return YES;
}

- (void)accessibilityIncrement {
    [self setAndSend:self.level + 2 * kLevelStep];
}

- (void)accessibilityDecrement {
    [self setAndSend:self.level - 2 * kLevelStep];
}

@end

#pragma mark - the card

// The song and Sing's state, read as one; activated, it says more about the state where there is more to say.
@interface SGSingSongElement : UIAccessibilityElement
@property (nonatomic, copy) void (^activate)(void);
@end

@implementation SGSingSongElement
- (BOOL)accessibilityActivate {
    if (self.activate) self.activate();
    return self.activate != nil;
}
@end

@interface SGSingCard : UIView
@end

@implementation SGSingCard {
    UIView *_card;
    SGMarqueeLabel *_title, *_artist;
    UILabel *_state;
    UIView *_graph;
    CAShapeLayer *_rest, *_vocals;
    UIButton *_play;
    SGSingLevelColumn *_column;
    UISegmentedControl *_stops;
    SGSingSongElement *_song;
    NSTimer *_timer;
    float _drawnVocals[kHistory + 1], _drawnRest[kHistory + 1];   // the levels the lines show now
    BOOL _flat;
    int _ticks;
    SPTPlayerTrack *_track;   // the player's track the words were last read for
    SGShownTrack *_shown;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _card = [UIView new];
    _card.backgroundColor = SGCardBackground();
    _card.layer.cornerRadius = 26;
    _card.layer.cornerCurve = kCACornerCurveContinuous;
    _card.clipsToBounds = YES;
    [self addSubview:_card];

    _title = [SGMarqueeLabel new];
    _title.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold] maximumPointSize:26];
    _title.textColor = UIColor.whiteColor;
    _artist = [SGMarqueeLabel new];
    _artist.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:15] maximumPointSize:20];
    _artist.textColor = SGGrey();
    _state = [UILabel new];
    _state.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont systemFontOfSize:13 weight:UIFontWeightMedium] maximumPointSize:18];
    // The song element reads them out.
    for (UIView *label in @[_title, _artist, _state]) {
        label.isAccessibilityElement = NO;
        [_card addSubview:label];
    }

    _graph = [UIView new];
    _graph.userInteractionEnabled = NO;
    _graph.accessibilityElementsHidden = YES;
    _graph.layer.masksToBounds = YES;
    _rest = [CAShapeLayer layer];
    _rest.strokeColor = [UIColor colorWithWhite:1 alpha:0.38].CGColor;
    _vocals = [CAShapeLayer layer];
    _vocals.strokeColor = SGGreen().CGColor;
    _vocals.lineWidth = 2.5;
    _rest.lineWidth = 1.5;
    for (CAShapeLayer *line in @[_rest, _vocals]) {
        line.fillColor = nil;
        line.lineCap = line.lineJoin = kCALineCapRound;
        [_graph.layer addSublayer:line];
    }
    // The lines come in from nothing at the left and run under the column at the right.
    CAGradientLayer *ends = [CAGradientLayer layer];
    ends.startPoint = CGPointMake(0, 0.5);
    ends.endPoint = CGPointMake(1, 0.5);
    ends.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    ends.locations = @[@0, @0.18, @0.92, @1];
    _graph.layer.mask = ends;
    [_card addSubview:_graph];

    _play = [UIButton buttonWithType:UIButtonTypeSystem];
    _play.tintColor = UIColor.whiteColor;
    SGGlassFor(_play, @selector(addSubview:)).userInteractionEnabled = NO;
    _play.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    _play.layer.cornerRadius = 24;
    [_play addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:_play];

    _column = [SGSingLevelColumn new];
    [_column addTarget:self action:@selector(levelMoved) forControlEvents:UIControlEventValueChanged];
    [_card addSubview:_column];

    _stops = [[UISegmentedControl alloc] initWithItems:@[@"Sing along", @"Original", @"Vocals only"]];
    [_stops addTarget:self action:@selector(stopPicked) forControlEvents:UIControlEventValueChanged];
    [self addSubview:_stops];

    _song = [[SGSingSongElement alloc] initWithAccessibilityContainer:_card];
    __weak typeof(self) weakSelf = self;
    _song.activate = ^{ [weakSelf explainState]; };
    _card.accessibilityElements = @[_song, _play, _column];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(stateTapped:)];
    [_card addGestureRecognizer:tap];
    // Spotify in the background plays on, and tick reads nothing there: the timer goes with the app and comes back with it.
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(stopTimer) name:UIApplicationDidEnterBackgroundNotification object:nil];
    [center addObserver:self selector:@selector(startTimer) name:UIApplicationWillEnterForegroundNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_timer invalidate];
}

- (CGSize)sizeThatFits:(CGSize)size {
    CGFloat stops = MAX(36, [_stops sizeThatFits:CGSizeMake(size.width, 0)].height);
    CGFloat text = _title.font.lineHeight + _artist.font.lineHeight + _state.font.lineHeight;
    return CGSizeMake(size.width, 12 + MAX(kCardHeight, text + 168) + 12 + stops + 8);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat width = self.bounds.size.width, side = 16;
    CGFloat stopsHeight = MAX(36, [_stops sizeThatFits:CGSizeMake(width, 0)].height);
    CGFloat cardHeight = self.bounds.size.height - 12 - 12 - stopsHeight - 8;
    _card.frame = CGRectMake(side, 12, width - 2 * side, cardHeight);
    _stops.frame = CGRectMake(side, CGRectGetMaxY(_card.frame) + 12, width - 2 * side, stopsHeight);
    CGFloat inner = _card.bounds.size.width, textWidth = inner - 2 * kInset - kColumn - 12;
    _column.frame = CGRectMake(inner - kInset - kColumn, kInset, kColumn, cardHeight - 2 * kInset);
    CGFloat y = kInset + 2;
    for (UIView *label in @[_title, _artist, _state]) {
        CGFloat lineHeight = [(UIFont *)[label valueForKey:@"font"] lineHeight];
        label.frame = CGRectMake(kInset + 2, y, textWidth, lineHeight);
        y += lineHeight + (label == _artist ? 6 : 1);
    }
    _play.frame = CGRectMake(kInset, cardHeight - kInset - 48, 48, 48);
    SGShapeGlass(SGGlassFor(_play, @selector(addSubview:)), 24, YES);
    _graph.frame = CGRectMake(0, y + 8, inner - kInset - kColumn - 6, CGRectGetMinY(_play.frame) - y - 16);
    for (CAShapeLayer *line in @[_rest, _vocals]) line.frame = _graph.bounds;
    _graph.layer.mask.frame = _graph.bounds;
    [self drawLines:NO];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self stopTimer];
    if (!self.window) return;
    // Pushed while in the background, the timer waits for WillEnterForeground.
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) [self startTimer];
    _track = nil;
    [self refresh];
}

- (void)startTimer {
    if (_timer || !self.window) return;
    __weak typeof(self) weakSelf = self;
    // In the common modes, so the lines go on while the page is scrolled.
    _timer = [NSTimer timerWithTimeInterval:kPoll repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)stopTimer {
    [_timer invalidate];
    _timer = nil;
}

#pragma mark - what it shows

- (void)refresh {
    SPTPlayerState *player = SGPlayerState();
    // The track's words read again only when the player has another track (or none).
    if (!_shown || player.track != _track) {
        _track = player.track;
        _shown = SGShownTrackNow();
    }
    NSString *title = _shown.title ?: @"Not Playing";
    NSString *artist = _shown ? _shown.artist ?: @"" : @"Play a song to hear Karaoke";
    _title.text = title;
    _artist.text = artist;
    SGSingState state = SGSingCurrentState();
    NSString *words = SGSingStatusText();
    float stored = SGSingLevel();
    if (state == SGSingStateSinging) {
        words = stored > 0.001 && stored < 0.999 ? [NSString stringWithFormat:@"%@ · vocals at %@", words, SGSingLevelText(stored)]
                                                 : [NSString stringWithFormat:@"%@ · %@", words, SGSingLevelText(stored)];
    }
    if (SGSingStatusDetail()) words = [words stringByAppendingString:@"  ⓘ"];
    if (![_state.text isEqualToString:words]) _state.text = words;
    _state.textColor = state == SGSingStateSinging ? SGGreen() : state == SGSingStateFailed || state == SGSingStateHot ? UIColor.systemOrangeColor : SGGrey();

    BOOL playing = player && !player.isPaused;
    UIImage *glyph = [UIImage systemImageNamed:playing ? @"pause.fill" : @"play.fill"
                             withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightBold]];
    if (![_play imageForState:UIControlStateNormal] || _play.tag != playing) {
        _play.tag = playing;
        [_play setImage:glyph forState:UIControlStateNormal];
    }
    _play.enabled = player != nil;
    _play.accessibilityLabel = playing ? @"Pause" : @"Play";

    if (!_column.tracking) _column.level = SGSingLevel();
    float level = _column.level;
    NSInteger stop = level == 0 ? 0 : level == 1 ? 1 : level == 2 ? 2 : UISegmentedControlNoSegment;
    if (_stops.selectedSegmentIndex != stop) _stops.selectedSegmentIndex = stop;

    _song.accessibilityLabel = _shown.artist.length ? [NSString stringWithFormat:@"%@, %@", title, artist] : title;
    _song.accessibilityValue = [NSString stringWithFormat:@"Karaoke: %@. Vocals: %@", SGSingStatusText(), SGSingLevelText(level)];
    _song.accessibilityHint = SGSingStatusDetail() ? @"Double-tap for more about Karaoke's state." : nil;
    _song.accessibilityTraits = SGSingStatusDetail() ? UIAccessibilityTraitButton : UIAccessibilityTraitStaticText;
    _song.accessibilityFrameInContainerSpace = CGRectMake(0, 0, CGRectGetMinX(_column.frame), CGRectGetMinY(_play.frame));
}

- (void)tick {
    // A tick before the background notification stops the timer, or from a page put in a window there: no reads
    // then, so Sing rests as with the page gone.
    if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) return;
    // The words ten times a second, the lines at every read.
    if (_ticks++ % 3 == 0) [self refresh];
    [self drawLines:YES];
}

- (UIBezierPath *)pathFor:(const float *)levels count:(int)count step:(CGFloat)step {
    CGSize size = _graph.bounds.size;
    CGFloat low = size.height - 3, span = size.height - 8;
    UIBezierPath *path = [UIBezierPath bezierPath];
    CGPoint last = CGPointZero;
    for (int k = 0; k < count; k++) {
        CGPoint point = CGPointMake(k * step, low - span * height(levels[k]));
        if (k == 0) [path moveToPoint:point];
        // Through the midpoints, each sample a control point: a smooth line that stays within the samples.
        else [path addQuadCurveToPoint:CGPointMake((last.x + point.x) / 2, (last.y + point.y) / 2) controlPoint:last];
        last = point;
    }
    [path addLineToPoint:last];
    return path;
}

// How many tenths the levels read now have moved on from the ones drawn, up to kMostBehind + 1, or -1 when they are
// not the drawn ones moved on (a seek, the level changed, the first read). The engine hands back the very floats it
// stored, so the drawn ones moved on compare equal.
- (int)movedOnVocals:(const float *)vocals rest:(const float *)rest {
    for (int moved = 0; moved <= kMostBehind + 1; moved++) {
        BOOL same = YES;
        for (int k = 0; k + moved <= kHistory && same; k++) same = vocals[k] == _drawnVocals[k + moved] && rest[k] == _drawnRest[k + moved];
        if (same) return moved;
    }
    return -1;
}

// `live`: from the timer, the lines may glide; otherwise (a layout) they are put where they are, at once. At rest
// the lines sit a tenth to the left, so the newest tenth ends at the graph's right edge, under the column.
- (void)drawLines:(BOOL)live {
    if (CGRectIsEmpty(_graph.bounds)) return;
    float vocals[kHistory + 1] = {0}, rest[kHistory + 1] = {0};
    BOOL heard = SGSingReadLevels(vocals, rest, kHistory + 1);
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    // Flat, and still nothing to trace.
    if (live && !heard && _flat) return;
    int moved = heard && !_flat ? [self movedOnVocals:vocals rest:rest] : -1;
    // Nothing new: the glide runs on, or the lines rest. Under Reduce Motion, in place every two seconds.
    if (live && moved == 0) return;
    if (live && heard && !_flat && still && _ticks % 60) return;
    CGFloat step = _graph.bounds.size.width / (kHistory - 1), atRest = -step;
    // From where the lines are on screen now, moved back by the tenths that came in, at most kMostBehind behind.
    BOOL glide = live && heard && !still && moved > 0;
    NSNumber *shown = [_vocals.presentationLayer valueForKeyPath:@"transform.translation.x"];
    CGFloat from = glide ? fmin((shown ? shown.doubleValue : atRest) + moved * step, atRest + kMostBehind * step) : atRest;
    // Calm: flat lines, eased there once.
    BOOL settle = live && !heard && !_flat;
    _flat = !heard;
    memcpy(_drawnVocals, vocals, sizeof vocals);
    memcpy(_drawnRest, rest, sizeof rest);
    [CATransaction begin];
    [CATransaction setDisableActions:!settle];
    if (settle) [CATransaction setAnimationDuration:0.4];
    // Calm also in color: the vocals' line dims while there is nothing to trace.
    _vocals.strokeColor = [SGGreen() colorWithAlphaComponent:heard ? 1 : 0.35].CGColor;
    _vocals.path = [self pathFor:vocals count:kHistory + 1 step:step].CGPath;
    _rest.path = [self pathFor:rest count:kHistory + 1 step:step].CGPath;
    for (CAShapeLayer *line in @[_rest, _vocals]) line.transform = CATransform3DMakeTranslation(atRest, 0, 0);
    [CATransaction commit];
    for (CAShapeLayer *line in @[_rest, _vocals]) {
        [line removeAnimationForKey:@"scroll"];
        if (!glide || from <= atRest) continue;
        // A tenth's width in a tenth of a second, whatever the distance, so the pace never changes.
        CABasicAnimation *slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
        slide.fromValue = @(from);
        slide.toValue = @(atRest);
        slide.duration = (from - atRest) / step * kTick;
        [line addAnimation:slide forKey:@"scroll"];
    }
}

#pragma mark - what it does

- (void)playTapped {
    id<SPTPlayer> player = SGKaraokePlayer();
    SPTPlayerState *state = SGPlayerState();
    if (!player || !state) return;
    if (state.isPaused) [player resume:nil];
    else [player pause:nil];
}

- (void)levelMoved {
    SGSetSingLevel(_column.level);
    [self refresh];
}

- (void)stopPicked {
    if (_stops.selectedSegmentIndex == UISegmentedControlNoSegment) return;
    SGSetSingLevel((float)_stops.selectedSegmentIndex);
    _column.level = (float)_stops.selectedSegmentIndex;
    [self refresh];
}

- (void)stateTapped:(UITapGestureRecognizer *)tap {
    CGPoint at = [tap locationInView:_card];
    if (at.y > CGRectGetMaxY(_state.frame) + 8 || at.x > CGRectGetMinX(_column.frame)) return;
    [self explainState];
}

- (void)explainState {
    NSString *detail = SGSingStatusDetail();
    if (!detail) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Karaoke" message:detail preferredStyle:UIAlertControllerStyleAlert];
    if (SGSingCurrentState() == SGSingStateFailed) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Try again" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            SGSetSingOn(NO);
            SGSetSingOn(YES);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:SGSingCurrentState() == SGSingStateFailed ? @"Cancel" : @"OK" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

@end

UIView *SGSingCardView(void) {
    return [SGSingCard new];
}
