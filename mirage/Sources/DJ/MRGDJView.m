#import "MRGDJView.h"
#import "MRGDJ.h"
#import "MRGAI.h"
#import "MRGPlayer.h"
#import "MRGBackgroundView.h"
#import "MRGPrefs.h"
#import <objc/runtime.h>

static UIVisualEffect *glassEffect(BOOL interactive) {
    if (@available(iOS 26.0, *)) {
        UIGlassEffect *g = [UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];
        g.interactive = interactive;
        return g;
    }
    return [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
}

static UIColor *kGreen(void) { return [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1]; }

// A capsule of glass holding a label and a symbol.
static UIButton *glassButton(NSString *title, NSString *symbol, BOOL prominent) {
    UIButtonConfiguration *c;
    if (@available(iOS 26.0, *)) c = prominent ? [UIButtonConfiguration prominentGlassButtonConfiguration] : [UIButtonConfiguration glassButtonConfiguration];
    else c = prominent ? [UIButtonConfiguration filledButtonConfiguration] : [UIButtonConfiguration tintedButtonConfiguration];
    c.title = title;
    c.image = symbol ? [UIImage systemImageNamed:symbol] : nil;
    c.imagePadding = 6;
    c.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    c.baseForegroundColor = prominent ? UIColor.blackColor : UIColor.whiteColor;
    if (prominent) c.baseBackgroundColor = kGreen();
    c.contentInsets = NSDirectionalEdgeInsetsMake(12, 18, 12, 18);
    UIButton *b = [UIButton buttonWithConfiguration:c primaryAction:nil];
    b.tintColor = prominent ? kGreen() : UIColor.whiteColor;
    return b;
}

#pragma mark - sheet

@interface MRGDJSheet : UIViewController <UITextFieldDelegate>
@end

@implementation MRGDJSheet {
    UILabel *_line, *_now, *_upNext, *_error, *_status, *_privacy;
    UIButton *_go, *_stop;
    UITextField *_field;
    UIActivityIndicatorView *_spinner;
    UIScrollView *_scroll;
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

    UILabel *title = [UILabel new];
    title.text = @"Mirage DJ";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textColor = UIColor.whiteColor;
    UIImageView *mark = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.and.mic"]];
    mark.tintColor = kGreen();
    [mark setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[mark, title, [UIView new], _spinner]];
    head.spacing = 10;
    head.alignment = UIStackViewAlignmentCenter;

    _line = [self label:22 weight:UIFontWeightSemibold color:UIColor.whiteColor];
    _status = [self label:15 weight:UIFontWeightMedium color:kGreen()];
    _now = [self label:15 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.75]];
    _upNext = [self label:14 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.6]];
    _error = [self label:14 weight:UIFontWeightMedium color:UIColor.systemRedColor];

    // The line it said, on a glass card.
    UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:glassEffect(NO)];
    card.layer.cornerRadius = 22;
    card.layer.cornerCurve = kCACornerCurveContinuous;
    card.clipsToBounds = YES;
    UIStackView *cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[_line, _status, _now]];
    cardStack.axis = UILayoutConstraintAxisVertical;
    cardStack.spacing = 8;
    cardStack.translatesAutoresizingMaskIntoConstraints = NO;
    [card.contentView addSubview:cardStack];
    [NSLayoutConstraint activateConstraints:@[
        [cardStack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:18],
        [cardStack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-18],
        [cardStack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:18],
        [cardStack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-18],
    ]];

    _go = glassButton(@"Start", @"sparkles", YES);
    [_go addTarget:self action:@selector(go) forControlEvents:UIControlEventTouchUpInside];
    _stop = glassButton(@"Stop", @"stop.fill", NO);
    [_stop addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[_go, _stop]];
    buttons.spacing = 10;
    buttons.distribution = UIStackViewDistributionFillProportionally;

    // The request field, in a glass capsule with a send button.
    UIVisualEffectView *fieldGlass = [[UIVisualEffectView alloc] initWithEffect:glassEffect(YES)];
    fieldGlass.layer.cornerRadius = 24;
    fieldGlass.layer.cornerCurve = kCACornerCurveContinuous;
    fieldGlass.clipsToBounds = YES;
    _field = [UITextField new];
    _field.placeholder = @"Ask for something… \"more 2000s r&b\"";
    _field.textColor = UIColor.whiteColor;
    _field.returnKeyType = UIReturnKeySend;
    _field.delegate = self;
    _field.autocorrectionType = UITextAutocorrectionTypeYes;
    UIButton *send = [UIButton systemButtonWithImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] target:self action:@selector(sendRequest)];
    send.tintColor = kGreen();
    [send setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *fieldRow = [[UIStackView alloc] initWithArrangedSubviews:@[_field, send]];
    fieldRow.spacing = 8;
    fieldRow.translatesAutoresizingMaskIntoConstraints = NO;
    [fieldGlass.contentView addSubview:fieldRow];
    [NSLayoutConstraint activateConstraints:@[
        [fieldRow.leadingAnchor constraintEqualToAnchor:fieldGlass.contentView.leadingAnchor constant:18],
        [fieldRow.trailingAnchor constraintEqualToAnchor:fieldGlass.contentView.trailingAnchor constant:-10],
        [fieldRow.centerYAnchor constraintEqualToAnchor:fieldGlass.contentView.centerYAnchor],
        [fieldGlass.heightAnchor constraintEqualToConstant:48],
    ]];

    UILabel *nextTitle = [self label:13 weight:UIFontWeightSemibold color:[UIColor colorWithWhite:1 alpha:0.5]];
    nextTitle.text = @"UP NEXT";
    _privacy = [self label:12 weight:UIFontWeightRegular color:[UIColor colorWithWhite:1 alpha:0.45]];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, card, buttons, fieldGlass, _error, nextTitle, _upNext, _privacy]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    [stack setCustomSpacing:6 afterView:nextTitle];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_scroll addSubview:stack];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
        [_scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.topAnchor constant:28],
        [stack.bottomAnchor constraintEqualToAnchor:_scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
    ]];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGPlayerTrackChangedNotification object:nil];
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (UILabel *)label:(CGFloat)size weight:(UIFontWeight)w color:(UIColor *)color {
    UILabel *l = [UILabel new];
    l.font = [UIFont systemFontOfSize:size weight:w];
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

- (void)refresh {
    MRGDJ *dj = MRGDJ.shared;
    BOOL hasKey = MRGAIProvider() != MRGProviderNone;
    BOOL thinking = dj.state == MRGDJThinking, playing = dj.state == MRGDJPlaying;
    if (thinking) [_spinner startAnimating]; else [_spinner stopAnimating];
    _line.text = dj.currentLine.length ? [NSString stringWithFormat:@"“%@”", dj.currentLine]
               : hasKey ? @"Tap Start and I'll take it from here."
               : @"Add your AI provider's API key in Mirage settings (Settings → Mirage → AI DJ) and I'm on.";
    _status.text = dj.status;
    _status.hidden = !dj.status.length;
    NSDictionary *now = MRGNowPlaying();
    _now.text = now ? [NSString stringWithFormat:@"Now playing: %@ — %@", now[@"title"], now[@"artist"] ?: @""] : nil;
    _now.hidden = !now;
    _error.text = dj.error;
    _error.hidden = !dj.error.length;
    NSMutableArray *rows = [NSMutableArray array];
    NSInteger from = dj.currentIndex >= 0 ? dj.currentIndex + 1 : 0;
    for (NSInteger i = from; i < (NSInteger)dj.set.count; i++) [rows addObject:[NSString stringWithFormat:@"%@ — %@", dj.set[i].title, dj.set[i].artist]];
    _upNext.text = rows.count ? [rows componentsJoinedByString:@"\n"] : (playing ? @"Picking the next set as this one ends." : @"Nothing yet.");
    UIButtonConfiguration *c = _go.configuration;
    c.title = playing || dj.set.count ? @"Switch it up" : @"Start";
    c.image = [UIImage systemImageNamed:playing ? @"shuffle" : @"sparkles"];
    _go.configuration = c;
    _go.enabled = hasKey && !thinking;
    _stop.hidden = !(playing || thinking);
    _field.enabled = hasKey;
    NSString *provider = hasKey ? MRGProviderName(MRGAIProvider()) : @"your AI provider";
    _privacy.text = [NSString stringWithFormat:@"Only track and artist names and what you type here go to %@. Playback is Spotify's own.%@", provider,
                     [dj.playbackMode isEqualToString:@"playlist"] ? @" This set plays from your private “Mirage DJ” playlist (Spotify Free shuffles it)." : @""];
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

#pragma mark - pill

@interface MRGDJPill : UIView
@end

@implementation MRGDJPill {
    UIVisualEffectView *_glass;
    UIImageView *_icon;
    UILabel *_label;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.accessibilityIdentifier = @"mirage.djpill";
    self.accessibilityLabel = @"Mirage DJ";
    self.accessibilityTraits = UIAccessibilityTraitButton;
    self.isAccessibilityElement = YES;
    self.layer.shadowColor = UIColor.blackColor.CGColor;
    self.layer.shadowOpacity = 0.3;
    self.layer.shadowRadius = 10;
    self.layer.shadowOffset = CGSizeMake(0, 4);
    _glass = [[UIVisualEffectView alloc] initWithEffect:glassEffect(YES)];
    _glass.frame = self.bounds;
    _glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _glass.clipsToBounds = YES;
    _glass.userInteractionEnabled = NO;
    [self addSubview:_glass];
    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"waveform.and.mic"]];
    _icon.tintColor = kGreen();
    _icon.contentMode = UIViewContentModeScaleAspectFit;
    _label = [UILabel new];
    _label.text = @"DJ";
    _label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _label.textColor = UIColor.whiteColor;
    [_glass.contentView addSubview:_icon];
    [_glass.contentView addSubview:_label];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)];
    [self addGestureRecognizer:tap];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:MRGDJChangedNotification object:nil];
    [self refresh];
    return self;
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)refresh {
    MRGDJState s = MRGDJ.shared.state;
    _label.text = s == MRGDJThinking ? @"DJ…" : s == MRGDJPlaying ? @"DJ on" : @"DJ";
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    _glass.layer.cornerRadius = h / 2;
    _glass.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:self.bounds cornerRadius:h / 2].CGPath;
    _icon.frame = CGRectMake(14, (h - 20) / 2, 20, 20);
    [_label sizeToFit];
    _label.frame = CGRectMake(40, (h - _label.bounds.size.height) / 2, _label.bounds.size.width, _label.bounds.size.height);
}

- (CGSize)sizeThatFits:(CGSize)size {
    [_label sizeToFit];
    return CGSizeMake(40 + _label.bounds.size.width + 16, 44);
}

- (void)tapped {
    UIResponder *r = self;
    while (r && ![r isKindOfClass:UIViewController.class]) r = r.nextResponder;
    UIViewController *vc = (UIViewController *)r ?: self.window.rootViewController;
    if (vc) MRGShowDJ(vc);
}

@end

static char kPillKey;

void MRGPlaceDJPill(UIView *home) {
    if (!home) return;
    MRGDJPill *pill = objc_getAssociatedObject(home, &kPillKey);
    if (!MRGDJShowsPill()) { [pill removeFromSuperview]; return; }
    if (!pill) {
        pill = [[MRGDJPill alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(home, &kPillKey, pill, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (pill.superview != home) [home addSubview:pill];
    if (home.subviews.lastObject != pill) [home bringSubviewToFront:pill];
    // Trailing, above the mini player and the tab bar (which Spotify does not report as safe area to the page).
    CGSize s = [pill sizeThatFits:CGSizeZero];
    CGRect b = home.bounds;
    CGFloat bottom = MAX(home.safeAreaInsets.bottom, 34) + 132;
    BOOL rtl = home.effectiveUserInterfaceLayoutDirection == UIUserInterfaceLayoutDirectionRightToLeft;
    CGFloat x = rtl ? 16 : b.size.width - s.width - 16;
    CGRect frame = CGRectMake(x, b.size.height - bottom - s.height, s.width, s.height);
    if (!CGRectEqualToRect(pill.frame, frame)) pill.frame = frame;
}
