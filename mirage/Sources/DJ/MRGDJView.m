#import "MRGDJView.h"
#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGSpotifyWeb.h"
#import "MRGBackgroundView.h"
#import "MRGPrefs.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import "MRGDJLog.h"

#pragma mark - shared bits

static UIVisualEffect *glassEffect(BOOL interactive) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        g.interactive = interactive;
        return g;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

// One accent for every DJ surface: Vitrine's accent color when one is set, Spotify's green otherwise (MRGDJLog.h).
static UIColor *kGreen(void) { return MRGAccent(); }

// Glass in a capsule or with round corners: iOS 26 glass takes its shape from a corner configuration (a layer corner
// radius leaves it a rounded rectangle), older materials from the layer.
static void shapeGlass(UIView *glass, CGFloat radius, BOOL capsule) {
    Class config = NSClassFromString(@"UICornerConfiguration"), corner = NSClassFromString(@"UICornerRadius");
    id shape = nil;
    if (config && [glass respondsToSelector:NSSelectorFromString(@"setCornerConfiguration:")]) {
        if (capsule && [config respondsToSelector:NSSelectorFromString(@"capsuleConfiguration")])
            shape = ((id (*)(id, SEL))objc_msgSend)(config, NSSelectorFromString(@"capsuleConfiguration"));
        else if ([config respondsToSelector:NSSelectorFromString(@"configurationWithUniformRadius:")] && [corner respondsToSelector:NSSelectorFromString(@"fixedRadius:")]) {
            id r = ((id (*)(id, SEL, double))objc_msgSend)(corner, NSSelectorFromString(@"fixedRadius:"), radius);
            shape = ((id (*)(id, SEL, id))objc_msgSend)(config, NSSelectorFromString(@"configurationWithUniformRadius:"), r);
        }
    }
    if (shape) {
        ((void (*)(id, SEL, id))objc_msgSend)(glass, NSSelectorFromString(@"setCornerConfiguration:"), shape);
        glass.clipsToBounds = NO;
    } else {
        glass.layer.cornerRadius = capsule ? glass.bounds.size.height / 2 : radius;
        glass.layer.cornerCurve = kCACornerCurveContinuous;
        glass.clipsToBounds = YES;
    }
}

// A label with its own padding: sized by its text plus symmetric insets, drawn centered in them, so a chip around a
// word is exactly as tall as the word needs and the word sits in its middle.
@interface MRGPaddedLabel : UILabel
@property (nonatomic) UIEdgeInsets insets;
@end
@implementation MRGPaddedLabel
- (CGSize)intrinsicContentSize {
    if (!self.text.length) return CGSizeZero;
    CGSize s = [super intrinsicContentSize];
    return CGSizeMake(ceil(s.width + _insets.left + _insets.right), ceil(s.height + _insets.top + _insets.bottom));
}
- (CGSize)sizeThatFits:(CGSize)size { return self.intrinsicContentSize; }
- (void)drawTextInRect:(CGRect)rect { [super drawTextInRect:UIEdgeInsetsInsetRect(rect, _insets)]; }
- (void)layoutSubviews { [super layoutSubviews]; self.layer.cornerRadius = self.bounds.size.height / 2; }
@end
static UIColor *kSecondary(void) { return [UIColor colorWithWhite:1 alpha:0.62]; }

static BOOL djActive(void) { return MRGDJ.shared.state != MRGDJIdle; }

static BOOL classNamed(id obj, NSString *part) { return [NSStringFromClass([obj class]) containsString:part]; }

static void forEachView(UIView *root, void (^block)(UIView *v, BOOL *stop)) {
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    BOOL stop = NO;
    while (queue.count && !stop) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        block(v, &stop);
        [queue addObjectsFromArray:v.subviews];
    }
}

static UIView *findView(UIView *root, BOOL (^match)(UIView *v)) {
    if (!root) return nil;
    __block UIView *found = nil;
    forEachView(root, ^(UIView *v, BOOL *stop) { if (match(v)) { found = v; *stop = YES; } });
    return found;
}

// Shown on screen: neither it nor anything over it hidden or faded out.
static BOOL visibleOnScreen(UIView *v) {
    if (!v.window) return NO;
    for (UIView *p = v; p && p != v.window; p = p.superview) if (p.hidden || p.alpha < 0.02) return NO;
    return YES;
}

static UIViewController *controllerOf(UIView *v) {
    for (UIResponder *r = v; r; r = r.nextResponder) if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    return v.window.rootViewController;
}

// Covers, cached for the session; a reused image view only takes the image it last asked for.
static char kImageURLKey;
static void loadImage(UIImageView *view, NSString *url, UIImage *placeholder) {
    static NSCache<NSString *, UIImage *> *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 120; }
    if ([objc_getAssociatedObject(view, &kImageURLKey) isEqualToString:url ?: @""] && view.image) return;
    objc_setAssociatedObject(view, &kImageURLKey, url ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIImage *hit = url ? [cache objectForKey:url] : nil;
    view.image = hit ?: placeholder;
    view.contentMode = hit ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter;
    if (hit || !url.length) return;
    NSURL *u = [NSURL URLWithString:url];
    if (!u) return;
    [[NSURLSession.sharedSession dataTaskWithURL:u completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (!image) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [cache setObject:image forKey:url];
            if (![objc_getAssociatedObject(view, &kImageURLKey) isEqualToString:url]) return;
            [UIView transitionWithView:view duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                view.image = image;
                view.contentMode = UIViewContentModeScaleAspectFill;
            } completion:nil];
        });
    }] resume];
}

static UIImage *notePlaceholder(CGFloat pt) {
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:pt weight:UIImageSymbolWeightMedium];
    return [[UIImage systemImageNamed:@"music.note" withConfiguration:c] imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.45] renderingMode:UIImageRenderingModeAlwaysOriginal];
}

static UIImageView *artworkView(CGFloat radius) {
    UIImageView *iv = [UIImageView new];
    iv.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    iv.layer.cornerRadius = radius;
    iv.layer.cornerCurve = kCACornerCurveContinuous;
    iv.clipsToBounds = YES;
    iv.contentMode = UIViewContentModeCenter;
    return iv;
}

// A capsule of glass holding a label and a symbol.
static UIButton *glassButton(NSString *title, NSString *symbol, BOOL prominent) {
    UIButtonConfiguration *c;
    if (@available(iOS 26.0, *)) c = prominent ? [UIButtonConfiguration prominentGlassButtonConfiguration] : [UIButtonConfiguration glassButtonConfiguration];
    else c = prominent ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    c.title = title;
    c.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    c.imagePadding = 6;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseForegroundColor = prominent ? MRGOnAccent() : UIColor.whiteColor;
    if (prominent) c.baseBackgroundColor = kGreen();
    c.contentInsets = NSDirectionalEdgeInsetsMake(13, 18, 13, 18);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        return m;
    };
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    b.tintColor = prominent ? kGreen() : UIColor.whiteColor;
    return b;
}

static UILabel *makeLabel(CGFloat size, UIFontWeight w, UIColor *color, NSInteger lines) {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = color;
    l.numberOfLines = lines;
    return l;
}

#pragma mark - equalizer (the playing row's mark)

@interface MRGDJEqualizer : UIView
@end
@implementation MRGDJEqualizer {
    NSArray<CALayer *> *_bars;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    NSMutableArray *bars = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        CALayer *b = [CALayer layer];
        b.backgroundColor = kGreen().CGColor;
        b.cornerRadius = 1;
        b.anchorPoint = CGPointMake(0.5, 1);
        [self.layer addSublayer:b];
        [bars addObject:b];
    }
    _bars = bars;
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(14, 14); }
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = 3, gap = 2.5, h = self.bounds.size.height;
    CGFloat x0 = (self.bounds.size.width - (w * 3 + gap * 2)) / 2;
    for (NSUInteger i = 0; i < _bars.count; i++) {
        _bars[i].bounds = CGRectMake(0, 0, w, h);
        _bars[i].position = CGPointMake(x0 + i * (w + gap) + w / 2, h);
    }
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    const double durations[3] = {0.55, 0.42, 0.66};
    for (NSUInteger i = 0; i < _bars.count; i++) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        a.fromValue = @(0.25);
        a.toValue = @(1.0);
        a.duration = durations[i];
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [_bars[i] addAnimation:a forKey:@"eq"];
    }
}
@end

#pragma mark - a row of the set

@interface MRGDJRow : UIControl
@property (nonatomic) NSInteger index;
- (void)showTrack:(MRGDJTrack *)t;
- (void)setPlaying:(BOOL)playing past:(BOOL)past;
@end

@implementation MRGDJRow {
    UIImageView *_art;
    UILabel *_title, *_artist;
    MRGPaddedLabel *_whyPill;
    MRGDJEqualizer *_eq;
    UIView *_highlight;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _highlight = [UIView new];
    _highlight.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
    _highlight.layer.cornerRadius = 14;
    _highlight.layer.cornerCurve = kCACornerCurveContinuous;
    _highlight.userInteractionEnabled = NO;
    _highlight.alpha = 0;
    _highlight.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_highlight];

    _art = artworkView(8);
    _art.translatesAutoresizingMaskIntoConstraints = NO;
    _title = makeLabel(15, UIFontWeightSemibold, UIColor.whiteColor, 1);
    _artist = makeLabel(13, UIFontWeightRegular, kSecondary(), 1);
    UIStackView *texts = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _artist]];
    texts.axis = UILayoutConstraintAxisVertical;
    texts.spacing = 2;
    texts.userInteractionEnabled = NO;
    texts.translatesAutoresizingMaskIntoConstraints = NO;

    // The reason chip: the label is the chip (its own insets and capsule), so the word is centered in it whatever the font.
    _whyPill = [MRGPaddedLabel new];
    _whyPill.insets = UIEdgeInsetsMake(3, 8, 3, 8);
    _whyPill.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    _whyPill.textColor = [UIColor colorWithWhite:1 alpha:0.75];
    _whyPill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    _whyPill.textAlignment = NSTextAlignmentCenter;
    _whyPill.clipsToBounds = YES;
    _whyPill.userInteractionEnabled = NO;
    _whyPill.translatesAutoresizingMaskIntoConstraints = NO;
    [_whyPill setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_whyPill setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];

    _eq = [MRGDJEqualizer new];
    _eq.translatesAutoresizingMaskIntoConstraints = NO;
    _eq.hidden = YES;

    for (UIView *v in @[_art, texts, _whyPill, _eq]) [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
        [_highlight.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:-8],
        [_highlight.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:8],
        [_highlight.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_highlight.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [self.heightAnchor constraintEqualToConstant:60],
        [_art.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_art.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_art.widthAnchor constraintEqualToConstant:46],
        [_art.heightAnchor constraintEqualToConstant:46],
        [texts.leadingAnchor constraintEqualToAnchor:_art.trailingAnchor constant:12],
        [texts.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_whyPill.leadingAnchor constraintGreaterThanOrEqualToAnchor:texts.trailingAnchor constant:8],
        [_whyPill.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_eq.leadingAnchor constraintEqualToAnchor:_whyPill.trailingAnchor constant:10],
        [_eq.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_eq.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_eq.widthAnchor constraintEqualToConstant:14],
        [_eq.heightAnchor constraintEqualToConstant:14],
    ]];
    [self addTarget:self action:@selector(down) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [self addTarget:self action:@selector(up) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit | UIControlEventTouchCancel];
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    return self;
}

- (void)down { [UIView animateWithDuration:0.12 animations:^{ self->_highlight.alpha = 1; self.transform = CGAffineTransformMakeScale(0.98, 0.98); }]; }
- (void)up { [UIView animateWithDuration:0.25 animations:^{ self->_highlight.alpha = self->_eq.hidden ? 0 : 1; self.transform = CGAffineTransformIdentity; }]; }

- (void)showTrack:(MRGDJTrack *)t {
    _title.text = t.title;
    _artist.text = t.artist;
    _whyPill.text = t.why;
    _whyPill.hidden = !t.why.length;
    [_whyPill invalidateIntrinsicContentSize];
    loadImage(_art, t.image, notePlaceholder(16));
    self.accessibilityLabel = [NSString stringWithFormat:@"%@, %@", t.title ?: @"", t.artist ?: @""];
}

- (void)setPlaying:(BOOL)playing past:(BOOL)past {
    _eq.hidden = !playing;
    _title.textColor = playing ? kGreen() : UIColor.whiteColor;
    _highlight.alpha = playing ? 1 : 0;
    self.alpha = past ? 0.45 : 1;
    self.accessibilityValue = playing ? @"Playing" : nil;
}

@end

#pragma mark - sheet

@interface MRGDJSheet : UIViewController <UITextFieldDelegate>
@end

@implementation MRGDJSheet {
    UILabel *_line, *_status, *_nowTitle, *_nowArtist, *_nowCaption, *_error, *_privacy, *_listTitle;
    UIImageView *_nowArt;
    UIButton *_go, *_stop;
    UITextField *_field;
    UIButton *_send;
    UIActivityIndicatorView *_spinner;
    UIScrollView *_scroll;
    UIStackView *_list;
    UIView *_empty;
    NSArray<MRGDJTrack *> *_shownSet;
    NSArray<MRGDJRow *> *_rows;
    NSString *_nowURI;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = UIColor.clearColor;
    // The Mirage background under a glass pane, so the sheet matches the screens around it.
    MRGBackgroundView *bg = [[MRGBackgroundView alloc] initWithFrame:self.view.bounds];
    bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bg.extraDim = 0.25;
    [self.view addSubview:bg];
    UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    glass.frame = self.view.bounds;
    glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:glass];

    _scroll = [UIScrollView new];
    _scroll.translatesAutoresizingMaskIntoConstraints = NO;
    _scroll.alwaysBounceVertical = YES;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_scroll];

    // Title row.
    UILabel *title = makeLabel(26, UIFontWeightBold, UIColor.whiteColor, 1);
    title.text = @"Mirage DJ";
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"sparkles"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightSemibold]]];
    mark.tintColor = kGreen();
    [mark setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[mark, title, [UIView new], _spinner]];
    head.spacing = 8;
    head.alignment = UIStackViewAlignmentCenter;

    // The card: what's playing (artwork, title, artist), then the line and a status line of fixed height.
    _nowArt = artworkView(10);
    [NSLayoutConstraint activateConstraints:@[[_nowArt.widthAnchor constraintEqualToConstant:64], [_nowArt.heightAnchor constraintEqualToConstant:64]]];
    _nowCaption = makeLabel(11, UIFontWeightBold, kGreen(), 1);
    _nowTitle = makeLabel(17, UIFontWeightSemibold, UIColor.whiteColor, 1);
    _nowArtist = makeLabel(14, UIFontWeightRegular, kSecondary(), 1);
    UIStackView *nowTexts = [[UIStackView alloc] initWithArrangedSubviews:@[_nowCaption, _nowTitle, _nowArtist]];
    nowTexts.axis = UILayoutConstraintAxisVertical;
    nowTexts.spacing = 2;
    [nowTexts setCustomSpacing:4 afterView:_nowCaption];
    UIStackView *nowRow = [[UIStackView alloc] initWithArrangedSubviews:@[_nowArt, nowTexts]];
    nowRow.spacing = 14;
    nowRow.alignment = UIStackViewAlignmentCenter;

    UIView *divider = [UIView new];
    divider.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
    [divider.heightAnchor constraintEqualToConstant:1.0 / UIScreen.mainScreen.scale].active = YES;

    _line = makeLabel(19, UIFontWeightSemibold, UIColor.whiteColor, 0);
    // Two lines held even when it says less, so the card doesn't jump as lines come and go.
    [_line.heightAnchor constraintGreaterThanOrEqualToConstant:ceil(_line.font.lineHeight * 2)].active = YES;
    _status = makeLabel(14, UIFontWeightMedium, kGreen(), 1);
    _status.adjustsFontSizeToFitWidth = YES;
    _status.minimumScaleFactor = 0.8;
    [_status.heightAnchor constraintEqualToConstant:18].active = YES;

    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[nowRow, divider, _line, _status]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 14;
    [cardStack setCustomSpacing:6 afterView:_line];
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:glassEffect(NO)];
    card.layer.cornerRadius = 24;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    [card.contentView addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
        [cardStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:16],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-14],
    ]];

    _go = glassButton(@"Start", @"sparkles", YES);
    [_go addTarget:self action:@selector(go) forControlEvents:UIControlEventTouchUpInside];
    _stop = glassButton(@"Stop", @"stop.fill", NO);
    [_stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [_stop setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_go, _stop]];
    buttons.spacing = 10;

    // The request field: a glass capsule, the text clear of the send button at its trailing end.
    UIVisualEffectView *fieldGlass = [[UIVisualEffectView alloc] initWithEffect:glassEffect(YES)];
    fieldGlass.layer.cornerRadius = 24;
    fieldGlass.layer.cornerCurve = kCACornerCurveContinuous;
    fieldGlass.clipsToBounds = YES;
    _field = [UITextField new];
    _field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Ask for a vibe…"
        attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.45]}];
    _field.font = [UIFont systemFontOfSize:16];
    _field.textColor = UIColor.whiteColor;
    _field.tintColor = kGreen();
    _field.returnKeyType = UIReturnKeySend;
    _field.enablesReturnKeyAutomatically = YES;
    _field.delegate = self;
    _field.translatesAutoresizingMaskIntoConstraints = NO;
    _send = [UIButton systemButtonWithImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightSemibold]] target:self action:@selector(sendRequest)];
    _send.tintColor = kGreen();
    _send.accessibilityLabel = @"Send request";
    _send.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldGlass.contentView addSubview:_field];
    [fieldGlass.contentView addSubview:_send];
    [NSLayoutConstraint activateConstraints:@[
        [fieldGlass.heightAnchor constraintEqualToConstant:50],
        [_field.leadingAnchor constraintEqualToAnchor:fieldGlass.contentView.leadingAnchor constant:20],
        [_field.trailingAnchor constraintEqualToAnchor:_send.leadingAnchor constant:-10],
        [_field.topAnchor constraintEqualToAnchor:fieldGlass.contentView.topAnchor],
        [_field.bottomAnchor constraintEqualToAnchor:fieldGlass.contentView.bottomAnchor],
        [_send.trailingAnchor constraintEqualToAnchor:fieldGlass.contentView.trailingAnchor constant:-8],
        [_send.centerYAnchor constraintEqualToAnchor:fieldGlass.contentView.centerYAnchor],
        [_send.widthAnchor constraintEqualToConstant:36],
        [_send.heightAnchor constraintEqualToConstant:36],
    ]];

    _error = makeLabel(13, UIFontWeightMedium, [UIColor colorWithRed:1 green:0.45 blue:0.45 alpha:1], 0);

    _listTitle = makeLabel(20, UIFontWeightBold, UIColor.whiteColor, 1);
    _list = [UIStackView new];
    _list.axis = UILayoutConstraintAxisVertical;
    _list.spacing = 4;
    _empty = [self emptyState];

    _privacy = makeLabel(12, UIFontWeightRegular, [UIColor colorWithWhite:1 alpha:0.4], 0);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, card, buttons, fieldGlass, _error, _listTitle, _list, _empty, _privacy]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    [stack setCustomSpacing:18 afterView:head];
    [stack setCustomSpacing:26 afterView:fieldGlass];
    [stack setCustomSpacing:26 afterView:_error];
    [stack setCustomSpacing:8 afterView:_listTitle];
    [stack setCustomSpacing:24 afterView:_list];
    [stack setCustomSpacing:24 afterView:_empty];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:26],
        [stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGPlayerTrackChangedNotification object:nil];
    [self refresh];
}

- (UIView *)emptyState {
    UIView *box = [UIView new];
    box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.05];
    box.layer.cornerRadius = 20;
    box.layer.cornerCurve = kCACornerCurveContinuous;
    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"music.note.list"
        withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:26 weight:UIImageSymbolWeightMedium]]];
    icon.tintColor = [UIColor colorWithWhite:1 alpha:0.5];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    UILabel *t = makeLabel(15, UIFontWeightSemibold, UIColor.whiteColor, 1);
    t.text = @"Your set shows up here";
    t.textAlignment = NSTextAlignmentCenter;
    UILabel *s = makeLabel(13, UIFontWeightRegular, kSecondary(), 0);
    s.text = @"Tap Start or ask for a vibe, and I'll line up 8–10 songs with a word before each.";
    s.textAlignment = NSTextAlignmentCenter;
    UIStackView *st = [[UIStackView alloc] initWithArrangedSubviews:@[icon, t, s]];
    st.axis = UILayoutConstraintAxisVertical;
    st.alignment = UIStackViewAlignmentCenter;
    st.spacing = 6;
    [st setCustomSpacing:10 afterView:icon];
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:st];
    [NSLayoutConstraint activateConstraints:@[
        [st.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:24],
        [st.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-24],
        [st.topAnchor constraintEqualToAnchor:box.topAnchor constant:24],
        [st.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-24],
    ]];
    return box;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

// The last line clear of the home indicator at every detent: the window's bottom inset, whatever the sheet reports.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat bottom = MAX(MAX(self.view.safeAreaInsets.bottom, self.view.window.safeAreaInsets.bottom), 20) + 12;
    if (fabs(_scroll.contentInset.bottom - bottom) > 0.5) {
        UIEdgeInsets in = _scroll.contentInset;
        in.bottom = bottom;
        _scroll.contentInset = in;
        UIEdgeInsets ind = _scroll.verticalScrollIndicatorInsets;
        ind.bottom = bottom;
        _scroll.verticalScrollIndicatorInsets = ind;
    }
}

- (void)setStatusText:(NSString *)text {
    if ([_status.text isEqualToString:text ?: @""] || (!text.length && !_status.text.length)) return;
    // Crossfaded in place; the line keeps its height whether there is a status or not.
    [UIView transitionWithView:_status duration:0.2 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
        self->_status.text = text ?: @"";
    } completion:nil];
}

- (void)rebuildRows:(NSArray<MRGDJTrack *> *)set {
    for (UIView *v in _list.arrangedSubviews) [v removeFromSuperview];
    NSMutableArray *rows = [NSMutableArray array];
    for (NSUInteger i = 0; i < set.count; i++) {
        MRGDJRow *row = [MRGDJRow new];
        row.index = i;
        [row showTrack:set[i]];
        [row addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_list addArrangedSubview:row];
        [rows addObject:row];
    }
    _rows = rows;
    _shownSet = set;
}

- (void)refresh {
    MRGDJ *dj = MRGDJ.shared;
    BOOL hasKey = MRGAIProvider() != MRGProviderNone;
    BOOL thinking = dj.state == MRGDJThinking, playing = dj.state == MRGDJPlaying;
    if (thinking) [_spinner startAnimating]; else [_spinner stopAnimating];

    // What's playing, with its cover: the player's own image, the set's, or the Web API's.
    NSDictionary *now = MRGNowPlaying();
    _nowCaption.text = playing && dj.currentIndex >= 0 ? @"ON MIRAGE DJ" : @"NOW PLAYING";
    _nowTitle.text = now ? now[@"title"] : @"Nothing playing";
    _nowArtist.text = now ? (now[@"artist"] ?: @"") : @"Start a set and I'll pick the music.";
    NSString *uri = now[@"uri"];
    NSString *image = now[@"image"];
    if (!image && dj.currentIndex >= 0 && dj.currentIndex < (NSInteger)dj.set.count) image = dj.set[dj.currentIndex].image;
    if (image || !uri) {
        loadImage(_nowArt, image, notePlaceholder(22));
    } else if (![_nowURI isEqualToString:uri]) {
        loadImage(_nowArt, nil, notePlaceholder(22));
        __weak typeof(self) weak = self;
        MRGWebTrackImage(uri, ^(NSString *url) {
            typeof(self) s = weak;
            if (s && url && [MRGNowPlaying()[@"uri"] isEqualToString:uri]) loadImage(s->_nowArt, url, notePlaceholder(22));
        });
    }
    _nowURI = uri;

    _line.text = dj.currentLine.length ? [NSString stringWithFormat:@"“%@”", dj.currentLine]
               : hasKey ? @"Tap Start and I'll take it from here."
               : @"Add your AI provider's key in Mirage settings → AI DJ, and I'm on.";
    _line.textColor = dj.currentLine.length ? UIColor.whiteColor : kSecondary();
    [self setStatusText:dj.status];

    _error.text = dj.error.length ? [dj.error stringByAppendingString:@"\nDetails: Mirage settings → AI DJ → DJ debug log."] : nil;
    _error.hidden = !dj.error.length;

    if (dj.set != _shownSet && ![dj.set isEqualToArray:_shownSet ?: @[]]) [self rebuildRows:dj.set];
    for (MRGDJRow *row in _rows) [row setPlaying:row.index == dj.currentIndex past:dj.currentIndex >= 0 && row.index < dj.currentIndex];
    BOOL hasSet = dj.set.count > 0;
    _list.hidden = !hasSet;
    _empty.hidden = hasSet;
    _listTitle.text = hasSet ? @"This set" : @"Up next";

    UIButtonConfiguration *c = _go.configuration;
    c.title = playing || hasSet ? @"Switch it up" : @"Start";
    c.image = [UIImage systemImageNamed:playing ? @"shuffle" : @"sparkles"];
    _go.configuration = c;
    _go.enabled = hasKey && !thinking;
    _stop.hidden = !(playing || thinking);
    _field.enabled = hasKey;
    _send.enabled = hasKey;
    NSString *provider = hasKey ? MRGProviderName(MRGAIProvider()) : @"your AI provider";
    _privacy.text = [NSString stringWithFormat:@"Only track and artist names and what you type here go to %@. Playback is Spotify's own.%@", provider,
                     [dj.playbackMode isEqualToString:@"playlist"] ? @" This set plays from your private “Mirage DJ” playlist (Spotify Free shuffles it)." : @""];
}

- (void)rowTapped:(MRGDJRow *)row {
    [[UISelectionFeedbackGenerator new] selectionChanged];
    [MRGDJ.shared playFromIndex:row.index];
}

- (void)go { [self.view endEditing:YES]; [MRGDJ.shared startWithRequest:nil]; }
- (void)stop { [MRGDJ.shared stop]; }

- (void)sendRequest {
    NSString *text = [_field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!text.length) return;
    _field.text = nil;
    [self.view endEditing:YES];
    [MRGDJ.shared startWithRequest:text];
}

- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self sendRequest]; return YES; }

@end

void MRGShowDJ(UIViewController *from) {
    UIViewController *top = from;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:MRGDJSheet.class]) return;
    MRGDJSheet *sheet = [MRGDJSheet new];
    sheet.modalPresentationStyle = UIModalPresentationPageSheet;
    UISheetPresentationController *p = sheet.sheetPresentationController;
    p.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
    p.prefersGrabberVisible = YES;
    p.preferredCornerRadius = 32;
    p.prefersScrollingExpandsWhenScrolledToEdge = NO;
    [top presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - Home: the DJ chip

// Styled from one of Spotify's chips when there is one (its height, label font, material or fill and corners), a
// capsule of glass otherwise. Active (a set on or coming): Spotify's selected look, green with dark text.
@interface MRGDJChip : UIControl
@property (nonatomic) BOOL glassStyle;
@property (nonatomic) CGFloat matchHeight;   // the height of what it sits beside (the redesign's 44pt pill), 0 for its own
- (void)styleFrom:(UIView *)spotifyChip;
@end

@implementation MRGDJChip {
    UIVisualEffectView *_material;
    UIView *_fill;
    UIImageView *_icon;
    UILabel *_label;
    CGFloat _height;
    UIColor *_idleFill;
    BOOL _styled;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _height = 32;
    _idleFill = [UIColor colorWithWhite:1 alpha:0.14];
    self.accessibilityIdentifier = @"mirage.djchip";
    self.accessibilityLabel = @"Mirage DJ";
    self.isAccessibilityElement = YES;
    self.accessibilityTraits = UIAccessibilityTraitButton;
    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    [self addSubview:_fill];
    _icon = [UIImageView new];
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _label = [UILabel new];
    _label.text = @"DJ";
    _label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    [self addSubview:_icon];
    [self addSubview:_label];
    [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [self addTarget:self action:@selector(pressed) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [self addTarget:self action:@selector(released) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit | UIControlEventTouchCancel];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)setGlassStyle:(BOOL)glass {
    if (_glassStyle == glass && (_material != nil) == glass) return;
    _glassStyle = glass;
    [_material removeFromSuperview];
    _material = nil;
    _label.font = [UIFont systemFontOfSize:glass ? 15 : 14 weight:glass ? UIFontWeightSemibold : UIFontWeightMedium];
    if (glass) {
        _height = self.matchHeight > 0 ? self.matchHeight : 36;
        _material = [[UIVisualEffectView alloc] initWithEffect:glassEffect(YES)];
        _material.userInteractionEnabled = NO;
        _material.clipsToBounds = YES;
        [self insertSubview:_material atIndex:0];
    }
    [self refresh];
}

- (void)styleFrom:(UIView *)chip {
    if (_styled || !chip || chip.bounds.size.height < 20) return;
    _styled = YES;
    _height = round(chip.bounds.size.height);
    UILabel *label = (UILabel *)findView(chip, ^BOOL(UIView *v) { return [v isKindOfClass:UILabel.class] && ((UILabel *)v).text.length; });
    if (label.font) _label.font = label.font;
    UIVisualEffectView *fx = (UIVisualEffectView *)findView(chip, ^BOOL(UIView *v) { return [v isKindOfClass:UIVisualEffectView.class] && ((UIVisualEffectView *)v).effect; });
    if (fx) {
        [_material removeFromSuperview];
        _material = [[UIVisualEffectView alloc] initWithEffect:[fx.effect copy]];
        _material.userInteractionEnabled = NO;
        _material.clipsToBounds = YES;
        [self insertSubview:_material atIndex:0];
    } else {
        UIView *filled = findView(chip, ^BOOL(UIView *v) {
            CGFloat a = 0;
            return v.backgroundColor && [v.backgroundColor getWhite:NULL alpha:&a] && a > 0.02 && v.bounds.size.height >= chip.bounds.size.height - 2;
        });
        if (filled.backgroundColor) _idleFill = filled.backgroundColor;
    }
    [self refresh];
    [self setNeedsLayout];
}

- (void)refresh {
    BOOL active = djActive();
    UIColor *fg = active ? MRGOnAccent() : UIColor.whiteColor;
    _label.textColor = fg;
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:_label.font.pointSize - 1 weight:UIImageSymbolWeightSemibold];
    _icon.image = [UIImage systemImageNamed:@"sparkles" withConfiguration:c];
    _icon.tintColor = active ? MRGOnAccent() : kGreen();
    _fill.backgroundColor = active ? kGreen() : (_material ? UIColor.clearColor : _idleFill);
    self.accessibilityValue = active ? @"On" : nil;
    [self setNeedsLayout];
}

- (CGSize)sizeThatFits:(CGSize)size {
    [_label sizeToFit];
    CGFloat icon = _label.font.pointSize;
    CGFloat h = _glassStyle && self.matchHeight > 0 ? self.matchHeight : _height;
    CGFloat pad = h >= 40 ? 16 : 14;
    return CGSizeMake(ceil(pad + icon + 5 + _label.bounds.size.width + pad), h);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat r = b.size.height / 2;
    _fill.frame = b;
    _fill.layer.cornerRadius = r;
    _material.frame = b;
    shapeGlass(_material, r, YES);
    [_label sizeToFit];
    CGFloat icon = _label.font.pointSize;
    CGFloat pad = b.size.height >= 40 ? 16 : 14;
    _icon.frame = CGRectMake(pad, round((b.size.height - icon) / 2), icon, icon);
    _label.frame = CGRectMake(CGRectGetMaxX(_icon.frame) + 5, round((b.size.height - _label.bounds.size.height) / 2), _label.bounds.size.width, _label.bounds.size.height);
}

- (void)pressed { [UIView animateWithDuration:0.12 animations:^{ self.transform = CGAffineTransformMakeScale(0.94, 0.94); }]; }
- (void)released { [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0 options:0 animations:^{ self.transform = CGAffineTransformIdentity; } completion:nil]; }
- (void)tapped { [[UISelectionFeedbackGenerator new] selectionChanged]; MRGShowDJ(controllerOf(self)); }

@end

static char kPillsChipKey, kPillsInsetKey, kHeaderChipKey, kPageHeaderKey;

static UIScrollView *chipScroll(UIView *pills) {
    return (UIScrollView *)findView(pills, ^BOOL(UIView *v) { return v != pills && [v isKindOfClass:UIScrollView.class]; });
}

// The trailing inset Spotify set plus the room for the chip. If Spotify set its own inset since (the value is not the one
// last written here), that value is the new base.
static char kPillsInsetSetKey;
static void setAddedInset(UIScrollView *scroll, CGFloat added) {
    CGFloat old = [objc_getAssociatedObject(scroll, &kPillsInsetKey) doubleValue];
    NSNumber *lastSet = objc_getAssociatedObject(scroll, &kPillsInsetSetKey);
    UIEdgeInsets in = scroll.contentInset;
    CGFloat base = lastSet && fabs(in.right - lastSet.doubleValue) < 0.5 ? in.right - old : in.right;
    CGFloat right = MAX(0, base + added);
    objc_setAssociatedObject(scroll, &kPillsInsetKey, @(added), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(scroll, &kPillsInsetSetKey, @(right), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (fabs(in.right - right) < 0.5) return;
    in.right = right;
    scroll.contentInset = in;
}

static void removePillsChip(UIView *pills) {
    MRGDJChip *chip = objc_getAssociatedObject(pills, &kPillsChipKey);
    UIScrollView *scroll = (UIScrollView *)chip.superview;
    [chip removeFromSuperview];
    if ([scroll isKindOfClass:UIScrollView.class]) setAddedInset(scroll, 0);
}

void MRGDJPlaceChipInPills(UIView *pills) {
    if (!pills) return;
    UIScrollView *scroll = chipScroll(pills);
    if (!MRGDJShowsPill() || !scroll || !visibleOnScreen(pills)) { removePillsChip(pills); return; }
    // Spotify's chips: the top-level drawers (each holds a chip and, opened, its sub-chips) that are showing.
    NSMutableArray<UIView *> *drawers = [NSMutableArray array];
    forEachView(scroll, ^(UIView *v, BOOL *stop) {
        if (!classNamed(v, @"PillDrawerView")) return;
        for (UIView *p = v.superview; p && p != scroll; p = p.superview) if (classNamed(p, @"PillDrawerView")) return;
        if (v.hidden || v.alpha < 0.02 || v.bounds.size.width < 4) return;
        [drawers addObject:v];
    });
    if (!drawers.count) { removePillsChip(pills); return; }
    [drawers sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        return [@(CGRectGetMinX([a convertRect:a.bounds toView:scroll])) compare:@(CGRectGetMinX([b convertRect:b.bounds toView:scroll]))];
    }];
    UIView *last = drawers.lastObject;
    CGRect lastFrame = [last convertRect:last.bounds toView:scroll];
    CGFloat gap = 8;
    if (drawers.count >= 2) {
        CGRect a = [drawers[0] convertRect:drawers[0].bounds toView:scroll], b = [drawers[1] convertRect:drawers[1].bounds toView:scroll];
        gap = MIN(16, MAX(4, CGRectGetMinX(b) - CGRectGetMaxX(a)));
    }
    UIView *ref = findView(drawers.firstObject, ^BOOL(UIView *v) { return classNamed(v, @"PillUIKit8PillView"); }) ?: drawers.firstObject;
    CGRect refFrame = [ref convertRect:ref.bounds toView:scroll];

    MRGDJChip *chip = objc_getAssociatedObject(pills, &kPillsChipKey);
    if (!chip) {
        chip = [MRGDJChip new];
        objc_setAssociatedObject(pills, &kPillsChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [chip styleFrom:ref];
    if (chip.superview != scroll) [scroll addSubview:chip];
    CGSize s = [chip sizeThatFits:CGSizeZero];
    CGFloat midY = refFrame.size.height > 0 ? CGRectGetMidY(refFrame) : CGRectGetMidY(lastFrame);
    CGRect frame = CGRectMake(round(CGRectGetMaxX(lastFrame) + gap), round(midY - s.height / 2), s.width, s.height);
    if (!CGRectEqualToRect(chip.frame, frame)) chip.frame = frame;
    // Room for it past Spotify's content, without touching the constraints that size that content.
    CGFloat contentEnd = scroll.contentSize.width;
    CGFloat need = CGRectGetMaxX(frame) + MAX(0, contentEnd - CGRectGetMaxX(lastFrame)) - contentEnd;
    setAddedInset(scroll, MAX(0, ceil(need)));
}

UIView *MRGDJChipHit(UIView *pills, CGPoint point, UIEvent *event) {
    MRGDJChip *chip = objc_getAssociatedObject(pills, &kPillsChipKey);
    if (!chip.superview || chip.hidden) return nil;
    CGPoint p = [pills convertPoint:point toView:chip];
    return [chip pointInside:p withEvent:event] ? chip : nil;
}

static UIView *headerChipHost(UIView *page) {
    UIView *cached = objc_getAssociatedObject(page, &kPageHeaderKey);
    if (cached.window == page.window && [cached isDescendantOfView:page]) return cached;
    UIView *header = findView(page, ^BOOL(UIView *v) { return classNamed(v, @"HomeHeaderView"); });
    objc_setAssociatedObject(page, &kPageHeaderKey, header, OBJC_ASSOCIATION_ASSIGN);
    return header;
}

void MRGDJPlaceHomeEntry(UIView *page) {
    if (!page) return;
    UIView *pills = findView(page, ^BOOL(UIView *v) { return classNamed(v, @"PillScrollView"); });
    if (pills) MRGDJPlaceChipInPills(pills);
    UIView *redesign = findView(page, ^BOOL(UIView *v) { return classNamed(v, @"SGRHomePillButtons"); });
    UIView *host = redesign.superview ?: headerChipHost(page).superview;
    MRGDJChip *chip = objc_getAssociatedObject(page, &kHeaderChipKey);
    BOOL pillsShown = pills && objc_getAssociatedObject(pills, &kPillsChipKey) && [objc_getAssociatedObject(pills, &kPillsChipKey) superview];
    BOOL redesignShown = redesign && visibleOnScreen(redesign.superview);
    // Without the redesign's pill, only chips hidden by a setting (the chip row itself hidden) leave a place for it;
    // chips faded out by something else leave none that is known to be free.
    BOOL pillsHiddenBySetting = pills && pills.hidden && pills.window;
    if (!MRGDJShowsPill() || pillsShown || !host || !(redesignShown || pillsHiddenBySetting)) { [chip removeFromSuperview]; return; }
    if (!chip) {
        chip = [MRGDJChip new];
        objc_setAssociatedObject(page, &kHeaderChipKey, chip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (chip.superview != host) [host addSubview:chip];
    else if (host.subviews.lastObject != chip) [host bringSubviewToFront:chip];
    CGRect frame;
    if (redesignShown) {
        // Vitrine's redesign: the title row's glass pill (filter, avatar) at the trailing edge; the chip goes just before it,
        // as glass too, and rises and fades with it.
        // As tall as the pill (44pt, the avatar's row), centered on it.
        chip.matchHeight = round(redesign.bounds.size.height) ?: 44;
        chip.glassStyle = YES;
        CGSize s = [chip sizeThatFits:CGSizeZero];
        CGRect pill = CGRectMake(redesign.center.x - redesign.bounds.size.width / 2, redesign.center.y - redesign.bounds.size.height / 2,
                                 redesign.bounds.size.width, redesign.bounds.size.height);
        frame = CGRectMake(round(CGRectGetMinX(pill) - 8 - s.width), round(CGRectGetMidY(pill) - s.height / 2), s.width, s.height);
        objc_setAssociatedObject(redesign, &kHeaderChipKey, chip, OBJC_ASSOCIATION_ASSIGN);
        chip.transform = redesign.transform;
        chip.alpha = redesign.alpha;
    } else {
        // The chips hidden by a setting: where they would start, next to the avatar.
        chip.glassStyle = NO;
        CGSize s = [chip sizeThatFits:CGSizeZero];
        CGRect where = [pills convertRect:pills.bounds toView:host];
        frame = CGRectMake(round(CGRectGetMinX(where) + 8), round(CGRectGetMidY(where) - s.height / 2), s.width, s.height);
        chip.transform = CGAffineTransformIdentity;
        chip.alpha = 1;
    }
    chip.bounds = (CGRect){CGPointZero, frame.size};
    chip.center = CGPointMake(CGRectGetMidX(frame), CGRectGetMidY(frame));
}

void MRGDJFollowHeaderButtons(UIView *buttons) {
    UIView *chip = objc_getAssociatedObject(buttons, &kHeaderChipKey);
    if (!chip.superview) return;
    if (!CGAffineTransformEqualToTransform(chip.transform, buttons.transform)) chip.transform = buttons.transform;
    if (chip.alpha != buttons.alpha) chip.alpha = buttons.alpha;
}

#pragma mark - Now Playing: the DJ button and caption

@interface MRGDJPlayerButton : UIButton
@end

@implementation MRGDJPlayerButton {
    UIView *_dot;
    UIVisualEffectView *_circle;
}

+ (instancetype)make {
    MRGDJPlayerButton *b = [self buttonWithType:UIButtonTypeSystem];
    UIImageSymbolConfiguration *c = [UIImageSymbolConfiguration configurationWithPointSize:19 weight:UIImageSymbolWeightMedium];
    [b setImage:[UIImage systemImageNamed:@"sparkles" withConfiguration:c] forState:UIControlStateNormal];
    b.accessibilityLabel = @"Mirage DJ";
    b.accessibilityIdentifier = @"mirage.dj.player";
    b->_dot = [UIView new];
    b->_dot.backgroundColor = kGreen();
    b->_dot.layer.cornerRadius = 3;
    b->_dot.userInteractionEnabled = NO;
    [b addSubview:b->_dot];
    [b addTarget:b action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    [NSNotificationCenter.defaultCenter addObserver:b selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [b refresh];
    return b;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (CGSize)intrinsicContentSize { return CGSizeMake(48, 48); }

- (void)refresh {
    BOOL active = djActive();
    self.tintColor = active ? kGreen() : UIColor.whiteColor;
    _dot.hidden = !active;
    self.accessibilityValue = active ? @"On" : nil;
}

// A glass circle like the ⋯'s, when the redesign gave the ⋯ one (its side).
- (void)setCircleSide:(CGFloat)side {
    if (side < 1) { [_circle removeFromSuperview]; _circle = nil; return; }
    if (!_circle) {
        _circle = [[UIVisualEffectView alloc] initWithEffect:glassEffect(NO)];
        _circle.userInteractionEnabled = NO;
        _circle.clipsToBounds = YES;
        _circle.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        [self insertSubview:_circle atIndex:0];
    }
    _circle.bounds = CGRectMake(0, 0, side, side);
    _circle.layer.cornerRadius = side / 2;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    if (_circle) {
        _circle.center = CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b));
        [self sendSubviewToBack:_circle];
    }
    _dot.frame = CGRectMake(CGRectGetMidX(b) + 9, CGRectGetMidY(b) - 14, 6, 6);
    [self bringSubviewToFront:_dot];
}

- (void)tapped { MRGShowDJ(controllerOf(self)); }

@end

// Now Playing while a set is on: the DJ's bar over the bottom of the artwork (under the header when the artwork isn't
// found), a glass capsule with a DJ badge, what the DJ is doing and a Switch it up button in the accent. While the DJ
// talks it opens up to the line, and a soft glow in the accent breathes behind it; a moment after, it closes again.
@interface MRGDJNowBar : UIView
@property (nonatomic, weak) UIView *header;   // the header row (⌄ title ✦ ⋯)
- (void)placeIn:(UIView *)root;
- (void)refresh;
@end

@implementation MRGDJNowBar {
    UIView *_glow;
    UIVisualEffectView *_glass;
    UILabel *_badge, *_title, *_line;
    MRGDJEqualizer *_eq;
    UIButton *_switch;
    BOOL _talking;
    NSString *_spoken;
    NSUInteger _token;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.alpha = 0;
    self.hidden = YES;
    _glow = [UIView new];
    _glow.userInteractionEnabled = NO;
    _glow.backgroundColor = UIColor.clearColor;
    _glow.layer.shadowOffset = CGSizeZero;
    _glow.layer.shadowRadius = 22;
    _glow.layer.shadowOpacity = 0;
    [self addSubview:_glow];
    _glass = [[UIVisualEffectView alloc] initWithEffect:glassEffect(NO)];
    _glass.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self addSubview:_glass];
    _badge = makeLabel(11, UIFontWeightHeavy, MRGOnAccent(), 1);
    _badge.text = @"DJ";
    _badge.textAlignment = NSTextAlignmentCenter;
    _badge.clipsToBounds = YES;
    _badge.layer.cornerRadius = 10;
    _eq = [MRGDJEqualizer new];
    _title = makeLabel(14, UIFontWeightSemibold, UIColor.whiteColor, 1);
    _line = makeLabel(14, UIFontWeightMedium, UIColor.whiteColor, 3);
    _line.alpha = 0;
    UIButtonConfiguration *c = [UIButtonConfiguration filledButtonConfiguration];
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.image = [UIImage systemImageNamed:@"shuffle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold]];
    c.imagePadding = 5;
    c.title = @"Switch it up";
    c.contentInsets = NSDirectionalEdgeInsetsMake(7, 12, 7, 12);
    c.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *a) {
        NSMutableDictionary *m = [a mutableCopy];
        m[NSFontAttributeName] = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
        return m;
    };
    _switch = [UIButton buttonWithConfiguration:c primaryAction:nil];
    _switch.accessibilityLabel = @"Switch it up";
    [_switch addTarget:self action:@selector(switchItUp) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[_badge, _eq, _title, _line, _switch]) [_glass.contentView addSubview:v];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(openSheet)];
    [_glass addGestureRecognizer:tap];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(speaking:) name:MRGDJSpeakingNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGPlayerTrackChangedNotification object:nil];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)openSheet { MRGShowDJ(controllerOf(self)); }
- (void)switchItUp { [[UIImpactFeedbackGenerator new] impactOccurred]; [MRGDJ.shared startWithRequest:nil]; }

- (BOOL)shouldShow { return MRGDJShowsPlayerButton() && MRGDJ.shared.state != MRGDJIdle; }

- (void)refresh {
    MRGDJ *dj = MRGDJ.shared;
    UIColor *accent = kGreen();
    _badge.backgroundColor = accent;
    _badge.textColor = MRGOnAccent();
    UIButtonConfiguration *c = _switch.configuration;
    c.baseBackgroundColor = accent;
    c.baseForegroundColor = MRGOnAccent();
    _switch.configuration = c;
    _switch.enabled = dj.state != MRGDJThinking;
    _glow.layer.shadowColor = accent.CGColor;
    NSString *title;
    if (dj.state == MRGDJThinking) title = dj.status.length ? dj.status : @"Picking your next set…";
    else if (dj.currentIndex >= 0 && dj.currentIndex < (NSInteger)dj.set.count && dj.set[dj.currentIndex].why.length)
        title = [NSString stringWithFormat:@"Mirage DJ · %@", dj.set[dj.currentIndex].why];
    else title = @"Mirage DJ";
    _title.text = title;
    _eq.hidden = !_talking;
    BOOL show = [self shouldShow];
    if (show == !self.hidden && self.alpha > 0.01) { [self setNeedsLayout]; return; }
    if (show) {
        self.hidden = NO;
        [self.superview bringSubviewToFront:self];
        [self placeIn:self.superview];
        [UIView animateWithDuration:0.3 animations:^{ self.alpha = 1; }];
    } else {
        [UIView animateWithDuration:0.25 animations:^{ self.alpha = 0; } completion:^(BOOL f) { if (![self shouldShow]) self.hidden = YES; }];
    }
}

// The cover the player shows: the biggest square picture under the header.
static UIView *artworkUnder(UIView *root, CGFloat belowY) {
    __block UIView *best = nil;
    __block CGFloat bestArea = 160 * 160;
    forEachView(root, ^(UIView *v, BOOL *stop) {
        if (![v isKindOfClass:UIImageView.class] || !((UIImageView *)v).image || !visibleOnScreen(v)) return;
        CGRect f = [v convertRect:v.bounds toView:root];
        if (fabs(f.size.width - f.size.height) > 24 || f.origin.y < belowY - 4) return;
        if (!CGRectIntersectsRect(f, root.bounds)) return;
        CGFloat area = f.size.width * f.size.height;
        if (area > bestArea) { bestArea = area; best = v; }
    });
    return best;
}

- (void)placeIn:(UIView *)root {
    UIView *header = self.header;
    if (!header || !root) return;
    CGRect h = [header convertRect:header.bounds toView:root];
    UIView *art = artworkUnder(root, CGRectGetMaxY(h));
    CGFloat width = MIN(root.bounds.size.width - 32, 520);
    CGRect a = art ? [art convertRect:art.bounds toView:root] : CGRectNull;
    if (art) width = MIN(width, a.size.width - 20);
    CGFloat height = _talking ? [self talkingHeightFor:width] : 48;
    CGFloat x = round(art ? CGRectGetMidX(a) - width / 2 : (root.bounds.size.width - width) / 2);
    CGFloat y = round(art ? CGRectGetMaxY(a) - 12 - height : CGRectGetMaxY(h) + 10);
    CGRect frame = CGRectMake(x, y, width, height);
    if (!CGRectEqualToRect(self.frame, frame)) self.frame = frame;
}

- (CGFloat)talkingHeightFor:(CGFloat)width {
    CGFloat textWidth = width - 16 - 16;
    CGFloat lineH = [_line sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)].height;
    lineH = MIN(lineH, ceil(_line.font.lineHeight * 3) + 1);
    return ceil(48 + lineH + 12);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _glass.frame = b;
    shapeGlass(_glass, 24, NO);
    _glow.frame = CGRectInset(b, 6, 6);
    _glow.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_glow.bounds cornerRadius:20].CGPath;
    [_switch sizeToFit];
    CGSize sw = _switch.bounds.size;
    _switch.frame = CGRectMake(b.size.width - 8 - sw.width, round((48 - sw.height) / 2), sw.width, sw.height);
    _badge.frame = CGRectMake(12, 14, 30, 20);
    _eq.frame = CGRectMake(CGRectGetMaxX(_badge.frame) + 8, 17, 14, 14);
    CGFloat titleX = (_eq.hidden ? CGRectGetMaxX(_badge.frame) : CGRectGetMaxX(_eq.frame)) + 8;
    _title.frame = CGRectMake(titleX, 14, CGRectGetMinX(_switch.frame) - 8 - titleX, 20);
    _line.frame = CGRectMake(16, 48, b.size.width - 32, MAX(0, b.size.height - 48 - 12));
}

- (void)breathe:(BOOL)on {
    [_glow.layer removeAnimationForKey:@"breathe"];
    if (!on) { _glow.layer.shadowOpacity = 0; return; }
    _glow.layer.shadowOpacity = 0.55;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"shadowOpacity"];
    a.fromValue = @0.25;
    a.toValue = @0.85;
    a.duration = 1.1;
    a.autoreverses = YES;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [_glow.layer addAnimation:a forKey:@"breathe"];
}

- (void)speaking:(NSNotification *)n {
    BOOL on = [n.userInfo[@"speaking"] boolValue];
    NSString *line = n.userInfo[@"line"];
    NSUInteger token = ++_token;
    if (on && line.length) {
        _talking = YES;
        _line.text = line;
        [self refresh];
        if (self.hidden || !self.superview || !visibleOnScreen(self.header)) return;
        [self.superview bringSubviewToFront:self];
        [self breathe:YES];
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            [self placeIn:self.superview];
            [self layoutIfNeeded];
            self->_line.alpha = 1;
        } completion:nil];
        return;
    }
    if (on) return;
    // A beat after the voice ends, the line folds away.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (token != self->_token) return;
        self->_talking = NO;
        [self breathe:NO];
        [self refresh];
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            self->_line.alpha = 0;
            [self placeIn:self.superview];
            [self layoutIfNeeded];
        } completion:nil];
    });
}

@end

static char kPlayerButtonKey, kPlayerSpacerKey, kNowBarKey;

// Now Playing's own root view under the window (the topmost ancestor that is the player's), so the bar sits over the
// artwork and goes away with the player.
static UIView *playerRoot(UIView *v) {
    UIView *root = v.superview ?: v;
    for (UIView *p = v.superview; p && p != v.window; p = p.superview) {
        UIResponder *owner = p.nextResponder;
        if (classNamed(p, @"NowPlaying") || ([owner isKindOfClass:UIViewController.class] && classNamed(owner, @"NowPlaying"))) root = p;
    }
    return root;
}

static UIStackView *headerRow(UIView *host) {
    return (UIStackView *)findView(host, ^BOOL(UIView *v) {
        if (![v isKindOfClass:UIStackView.class]) return NO;
        UIStackView *s = (UIStackView *)v;
        return s.axis == UILayoutConstraintAxisHorizontal && s.arrangedSubviews.count >= 3;
    });
}

void MRGDJPlacePlayerButton(UIViewController *unit) {
    UIView *host = unit.viewIfLoaded;
    if (!host) return;
    MRGDJPlayerButton *button = objc_getAssociatedObject(unit, &kPlayerButtonKey);
    UIView *spacer = objc_getAssociatedObject(unit, &kPlayerSpacerKey);
    MRGDJNowBar *bar = objc_getAssociatedObject(unit, &kNowBarKey);
    if (!MRGDJShowsPlayerButton()) {
        [button removeFromSuperview];
        [spacer removeFromSuperview];
        [bar removeFromSuperview];
        return;
    }
    UIStackView *row = headerRow(host);
    if (!row) return;
    if (!button) {
        button = [MRGDJPlayerButton make];
        spacer = [UIView new];
        spacer.alpha = 0;
        spacer.userInteractionEnabled = NO;
        spacer.isAccessibilityElement = NO;
        [button.widthAnchor constraintEqualToConstant:48].active = YES;
        [spacer.widthAnchor constraintEqualToConstant:48].active = YES;
        objc_setAssociatedObject(unit, &kPlayerButtonKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(unit, &kPlayerSpacerKey, spacer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (button.superview != row) {
        // ⌄ [spacer] title [DJ] ⋯ : the spacer balances the button, so the title stays centered.
        NSArray<UIView *> *arranged = row.arrangedSubviews;
        UIView *more = arranged.lastObject;
        [row insertArrangedSubview:spacer atIndex:1];
        [row insertArrangedSubview:button atIndex:[row.arrangedSubviews indexOfObject:more]];
    }
    // The ⋯ with a glass circle (Vitrine's redesign puts one inside it): the DJ button gets the same.
    UIView *more = row.arrangedSubviews.lastObject;
    UIVisualEffectView *moreGlass = (UIVisualEffectView *)findView(more, ^BOOL(UIView *v) { return v != more && [v isKindOfClass:UIVisualEffectView.class]; });
    [button setCircleSide:moreGlass ? MAX(moreGlass.bounds.size.width, moreGlass.bounds.size.height) : 0];

    UIView *root = playerRoot(host);
    if (!bar) {
        bar = [MRGDJNowBar new];
        objc_setAssociatedObject(unit, &kNowBarKey, bar, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    bar.header = row;
    if (bar.superview != root) { [root addSubview:bar]; [bar refresh]; }
    if (!bar.hidden) {
        if (root.subviews.lastObject != bar) [root bringSubviewToFront:bar];
        [bar placeIn:root];
    }
}
