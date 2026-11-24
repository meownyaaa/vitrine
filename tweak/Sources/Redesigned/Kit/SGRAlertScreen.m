#import "SGRAlertScreen.h"
#import <objc/runtime.h>
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

// Telegram's AlertComponent, point for point.
static const CGFloat kAlertWidth = 300;
static const CGFloat kAlertRadius = 35;
static const CGFloat kContentTop = 22;
static const CGFloat kContentBottom = 21;
static const CGFloat kContentSide = 30;
static const CGFloat kContentGap = 8;
static const CGFloat kActionSide = 16;
static const CGFloat kActionGap = 8;
static const CGFloat kActionHeight = 48;
static const CGFloat kFieldHeight = 50;
static const CGFloat kFieldTop = 15;
static const CGFloat kSheetMargin = 8;
static const CGFloat kSheetMaxWidth = 420;

typedef void (^SGRAlertHandler)(UIAlertAction *action);

typedef NS_ENUM(NSInteger, SGRAlertKind) {
    SGRAlertKindGeneric,            // 10% white, white text
    SGRAlertKindDefault,            // the accent, bold
    SGRAlertKindDestructive,        // 10% white, red text
    SGRAlertKindDefaultDestructive, // red, white text, bold
};

#pragma mark - reading the system alert

static Ivar handlerIvar(void) {
    static Ivar ivar;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ivar = class_getInstanceVariable(UIAlertAction.class, "_handler"); });
    return ivar;
}

// What the action runs when it is picked: UIAlertAction keeps it in a private ivar and has no public way to hand it
// back.
static SGRAlertHandler handlerOf(UIAlertAction *action) {
    Ivar ivar = handlerIvar();
    return ivar ? (SGRAlertHandler)object_getIvar(action, ivar) : nil;
}

static UIColor *destructiveRed(void) {
    return [UIColor colorWithRed:1.0 green:0x67 / 255.0 blue:0x67 / 255.0 alpha:1];   // Telegram's night itemDestructiveColor
}

#pragma mark - a button

@interface SGRAlertButton : UIView
@property (nonatomic, strong) UIAlertAction *action;
@property (nonatomic, copy) SGRAlertHandler handler;
@property (nonatomic) SGRAlertKind kind;
@property (nonatomic) BOOL isCancel;
@property (nonatomic) BOOL highlighted;
@property (nonatomic) BOOL actionEnabled;
@property (nonatomic, strong) UIView *fill;
@property (nonatomic, strong) UILabel *label;
- (instancetype)initWithAction:(UIAlertAction *)action kind:(SGRAlertKind)kind;
- (CGFloat)preferredWidth;
@end

@implementation SGRAlertButton

- (instancetype)initWithAction:(UIAlertAction *)action kind:(SGRAlertKind)kind {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _action = action;
    _handler = handlerOf(action);
    _kind = kind;
    _isCancel = action.style == UIAlertActionStyleCancel;
    _actionEnabled = action.enabled;

    _fill = [UIView new];
    _fill.userInteractionEnabled = NO;
    _fill.clipsToBounds = YES;
    _fill.layer.cornerCurve = kCACornerCurveContinuous;
    [self addSubview:_fill];

    _label = [UILabel new];
    _label.userInteractionEnabled = NO;
    _label.textAlignment = NSTextAlignmentCenter;
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.numberOfLines = 1;
    _label.text = action.title;
    [self addSubview:_label];

    BOOL bold = kind == SGRAlertKindDefault || kind == SGRAlertKindDefaultDestructive;
    _label.font = [UIFont systemFontOfSize:17 weight:bold ? UIFontWeightSemibold : UIFontWeightMedium];

    UIColor *accent = SGRAccent();
    switch (kind) {
        case SGRAlertKindGeneric:
            _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
            _label.textColor = UIColor.whiteColor;
            break;
        case SGRAlertKindDefault:
            _fill.backgroundColor = accent;
            _label.textColor = SGRInkOnAccent(accent);
            break;
        case SGRAlertKindDestructive:
            _fill.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
            _label.textColor = destructiveRed();
            break;
        case SGRAlertKindDefaultDestructive:
            _fill.backgroundColor = destructiveRed();
            _label.textColor = UIColor.whiteColor;
            break;
    }
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = action.title;
    [self refresh];
    return self;
}

- (CGFloat)preferredWidth {
    return ceil([self.label.text ?: @"" sizeWithAttributes:@{NSFontAttributeName: self.label.font}].width) + 32;
}

// Telegram dims the fill, not the title: a pressed button to 35%, a disabled one to 20%.
- (void)refresh {
    self.fill.alpha = self.actionEnabled ? (self.highlighted ? 0.35 : 1.0) : 0.2;
    self.label.alpha = self.actionEnabled ? 1.0 : 0.4;
    self.accessibilityTraits = UIAccessibilityTraitButton | (self.actionEnabled ? 0 : UIAccessibilityTraitNotEnabled);
}

- (void)setHighlighted:(BOOL)highlighted {
    if (_highlighted == highlighted) return;
    _highlighted = highlighted;
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction animations:^{
        [self refresh];
    } completion:nil];
}

- (void)setActionEnabled:(BOOL)enabled {
    if (_actionEnabled == enabled) return;
    _actionEnabled = enabled;
    [UIView animateWithDuration:0.25 animations:^{ [self refresh]; }];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.fill.frame = self.bounds;
    self.fill.layer.cornerRadius = self.bounds.size.height / 2;
    self.label.frame = CGRectInset(self.bounds, 16, 0);
}

@end

#pragma mark - the screen

static char kPanelGlassKey;
static void *kEnabledContext = &kEnabledContext;

// What lies behind the card: the page is only dimmed a little, so it stays the page and the card stands a step
// in front of it. No blur: a heavy veil hid the page and made the whole screen look like another one.
static const CGFloat kScrimAlert = 0.3, kScrimSheet = 0.36;

@interface SGRAlertScreen ()
@property (nonatomic, strong) UIAlertController *alert;
@end

@implementation SGRAlertScreen {
    UIAlertControllerStyle _style;
    UIView *_dim;
    UIView *_panel;
    UIScrollView *_scroll;
    UILabel *_titleLabel;
    UILabel *_messageLabel;
    NSArray<UITextField *> *_fields;
    NSMutableArray<UIView *> *_fieldBoxes;
    NSArray<SGRAlertButton *> *_buttons;   // top to bottom, or left to right
    BOOL _horizontal;
    SGRAlertButton *_cancelButton;
    SGRAlertButton *_pressed;
    UISelectionFeedbackGenerator *_feedback;
    CGFloat _keyboard;
    BOOL _animatedIn;
    BOOL _finishing;
    BOOL _observing;
}

+ (BOOL)handlersReadable {
    return handlerIvar() != NULL;
}

+ (BOOL)canShow:(UIAlertController *)alert {
    if (!handlerIvar()) return NO;
    if (alert.preferredStyle == UIAlertControllerStyleActionSheet && UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) return NO;
    // A controller of the app's own inside the alert (the private contentViewController): not ours to redraw.
    @try {
        if ([alert valueForKey:@"contentViewController"]) return NO;
    } @catch (__unused NSException *e) {}
    if (!alert.title.length && !alert.message.length && !alert.actions.count && !alert.textFields.count) return NO;
    return YES;
}

- (instancetype)initWithAlert:(UIAlertController *)alert {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    _alert = alert;
    _style = alert.preferredStyle;
    self.modalPresentationStyle = UIModalPresentationOverFullScreen;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _feedback = [UISelectionFeedbackGenerator new];
    return self;
}

- (void)dealloc {
    [self stopObserving];
}

- (BOOL)isAlertStyle {
    return _style == UIAlertControllerStyleAlert;
}

#pragma mark building

// Which of the alert's actions is the main one (the accent button): the preferred action, else the first Default
// of an alert, else the one thing an alert can do besides being cancelled. An action sheet has none unless one is
// preferred: its rows are all the same weight.
- (UIAlertAction *)primaryAction {
    UIAlertAction *preferred = self.alert.preferredAction;
    if (preferred && [self.alert.actions containsObject:preferred]) return preferred;
    if (![self isAlertStyle]) return nil;
    NSMutableArray<UIAlertAction *> *others = [NSMutableArray array];
    for (UIAlertAction *action in self.alert.actions) {
        if (action.style == UIAlertActionStyleDefault) return action;
        if (action.style != UIAlertActionStyleCancel) [others addObject:action];
    }
    if (others.count == 1) return others.firstObject;   // a lone Delete
    if (!others.count) {
        for (UIAlertAction *action in self.alert.actions) {
            if (action.style == UIAlertActionStyleCancel) return action;   // a lone OK
        }
    }
    return nil;
}

- (void)buildButtons {
    UIAlertAction *primary = [self primaryAction];
    NSMutableArray<SGRAlertButton *> *regular = [NSMutableArray array];
    for (UIAlertAction *action in self.alert.actions) {
        SGRAlertKind kind;
        if (action == primary) kind = action.style == UIAlertActionStyleDestructive ? SGRAlertKindDefaultDestructive : SGRAlertKindDefault;
        else kind = action.style == UIAlertActionStyleDestructive ? SGRAlertKindDestructive : SGRAlertKindGeneric;
        SGRAlertButton *button = [[SGRAlertButton alloc] initWithAction:action kind:kind];
        if (button.isCancel) _cancelButton = button; else [regular addObject:button];
        [action addObserver:self forKeyPath:@"enabled" options:NSKeyValueObservingOptionNew context:kEnabledContext];
        _observing = YES;
    }
    // Two buttons that fit side by side go cancel left, the other right; anything else is a column, the others in
    // the order they were added and the cancel last.
    _horizontal = NO;
    NSMutableArray<SGRAlertButton *> *ordered = [NSMutableArray array];
    if ([self isAlertStyle] && regular.count + (_cancelButton ? 1 : 0) == 2) {
        CGFloat half = (kAlertWidth - kActionSide * 2 - kActionGap) / 2;
        SGRAlertButton *first = _cancelButton ?: regular[0];
        SGRAlertButton *second = _cancelButton ? regular.firstObject : regular[1];
        if (first.preferredWidth <= half && second.preferredWidth <= half) {
            _horizontal = YES;
            [ordered addObjectsFromArray:@[first, second]];
        }
    }
    if (!_horizontal) {
        [ordered addObjectsFromArray:regular];
        if (_cancelButton) [ordered addObject:_cancelButton];
    }
    _buttons = ordered;
}

static UILabel *textLabel(NSString *text, UIFont *font) {
    UILabel *label = [UILabel new];
    label.text = text;
    label.font = font;
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentNatural;
    return label;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;

    _dim = [UIView new];
    _dim.backgroundColor = [UIColor colorWithWhite:0 alpha:[self isAlertStyle] ? kScrimAlert : kScrimSheet];
    _dim.alpha = 0;
    [_dim addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dimTapped)]];
    [self.view addSubview:_dim];

    _panel = [UIView new];
    _panel.alpha = 0;
    _panel.accessibilityViewIsModal = YES;
    _panel.layer.shadowColor = UIColor.blackColor.CGColor;
    _panel.layer.shadowOpacity = 0.35;
    _panel.layer.shadowRadius = 24;
    _panel.layer.shadowOffset = CGSizeMake(0, 8);
    [self.view addSubview:_panel];

    _scroll = [UIScrollView new];
    _scroll.showsVerticalScrollIndicator = NO;
    _scroll.alwaysBounceVertical = NO;
    _scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [_panel addSubview:_scroll];

    if (self.alert.title.length) {
        _titleLabel = textLabel(self.alert.title, [UIFont systemFontOfSize:17 weight:UIFontWeightBold]);
        [_scroll addSubview:_titleLabel];
    }
    if (self.alert.message.length) {
        _messageLabel = textLabel(self.alert.message, [UIFont systemFontOfSize:15 weight:UIFontWeightRegular]);
        [_scroll addSubview:_messageLabel];
    }

    // The alert's own text fields, moved into pills of ours. The fields stay the caller's: its configuration, its
    // targets and the text read back in the handler all work on these very objects.
    _fields = [self.alert.textFields copy] ?: @[];
    _fieldBoxes = [NSMutableArray array];
    UIColor *accent = SGRAccent();
    for (UITextField *field in _fields) {
        UIView *box = [UIView new];
        box.backgroundColor = [UIColor colorWithWhite:1 alpha:0.1];
        box.layer.cornerRadius = kFieldHeight / 2;
        box.layer.cornerCurve = kCACornerCurveContinuous;
        [field removeFromSuperview];
        // Laid out by frame in the pill (viewDidLayoutSubviews). The alert placed it with Auto Layout, and the size it
        // was given there stays on it: left on, it put the field at the pill's top left corner at its old size.
        field.translatesAutoresizingMaskIntoConstraints = YES;
        for (NSLayoutConstraint *constraint in field.constraints) {
            if (constraint.firstItem == field && !constraint.secondItem) constraint.active = NO;
        }
        field.borderStyle = UITextBorderStyleNone;
        field.backgroundColor = UIColor.clearColor;
        field.font = [UIFont systemFontOfSize:17];
        field.textColor = UIColor.whiteColor;
        field.tintColor = accent;
        field.keyboardAppearance = UIKeyboardAppearanceDark;
        if (field.clearButtonMode == UITextFieldViewModeNever) field.clearButtonMode = UITextFieldViewModeWhileEditing;
        if (field.placeholder.length) {
            field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:field.placeholder
                attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.4], NSFontAttributeName: field.font}];
        }
        [box addSubview:field];
        [_scroll addSubview:box];
        [_fieldBoxes addObject:box];
    }

    [self buildButtons];
    for (SGRAlertButton *button in _buttons) [_panel addSubview:button];

    // Press, slide and lift: a button lights while the finger is on it and fires when it lifts there, as Telegram's
    // does. Begins only over a button, so the text fields and the scrolling text keep their own touches.
    UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressed:)];
    press.minimumPressDuration = 0;
    press.allowableMovement = CGFLOAT_MAX;
    press.delegate = self;
    [_panel addGestureRecognizer:press];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
}

- (void)stopObserving {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    if (!_observing) return;
    _observing = NO;
    for (UIAlertAction *action in self.alert.actions) {
        @try { [action removeObserver:self forKeyPath:@"enabled" context:kEnabledContext]; } @catch (__unused NSException *e) {}
    }
}

// Save stays dimmed until the field has text: callers flip UIAlertAction.enabled and the button follows.
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != kEnabledContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        for (SGRAlertButton *button in self->_buttons) {
            if (button.action == object) button.actionEnabled = button.action.enabled;
        }
    });
}

#pragma mark layout

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self layoutPanel];
}

- (void)layoutPanel {
    CGRect bounds = self.view.bounds;
    UIEdgeInsets safe = self.view.safeAreaInsets;
    BOOL alertStyle = [self isAlertStyle];
    _dim.frame = bounds;

    CGFloat width = alertStyle ? MIN(kAlertWidth, bounds.size.width - 32) : MIN(kSheetMaxWidth, bounds.size.width - kSheetMargin * 2);
    CGFloat textWidth = width - kContentSide * 2;

    // The content: title, text, fields.
    CGFloat y = 0;
    BOOL hasContent = _titleLabel || _messageLabel || _fields.count;
    CGFloat contentHeight = 0;
    if (hasContent) {
        y = kContentTop;
        NSMutableArray<UILabel *> *labels = [NSMutableArray array];
        if (_titleLabel) [labels addObject:_titleLabel];
        if (_messageLabel) [labels addObject:_messageLabel];
        for (UILabel *label in labels) {
            if (y > kContentTop) y += kContentGap;
            CGSize size = [label sizeThatFits:CGSizeMake(textWidth, CGFLOAT_MAX)];
            label.frame = CGRectMake(kContentSide, y, textWidth, ceil(size.height));
            y += ceil(size.height);
        }
        for (UIView *box in _fieldBoxes) {
            y += (box == _fieldBoxes.firstObject) ? (y > kContentTop ? kFieldTop : 0) : kContentGap;
            box.frame = CGRectMake(kContentSide - 6, y, textWidth + 12, kFieldHeight);
            UITextField *field = (UITextField *)box.subviews.firstObject;
            field.frame = CGRectMake(16, 0, box.bounds.size.width - 32, kFieldHeight);
            y += kFieldHeight;
        }
        contentHeight = y + kContentBottom;
    }

    // The buttons.
    NSUInteger count = _buttons.count;
    CGFloat actionsTop = hasContent ? 0 : kActionSide;
    CGFloat actionsHeight = 0;
    CGFloat cancelGap = (!alertStyle && _cancelButton && count > 1) ? kActionGap : 0;   // a sheet sets Cancel apart
    if (count) {
        actionsHeight = _horizontal ? kActionHeight : kActionHeight * count + kActionGap * (count - 1) + cancelGap;
        actionsHeight += kActionSide;
    }
    CGFloat chrome = actionsTop + actionsHeight;

    // Past the screen the content scrolls and the buttons stay.
    CGFloat availableHeight;
    if (alertStyle) availableHeight = bounds.size.height - safe.top - MAX(safe.bottom, _keyboard) - 40;
    else availableHeight = bounds.size.height - safe.top - kSheetMargin * 2;
    CGFloat visibleContent = contentHeight;
    if (contentHeight + chrome > availableHeight) visibleContent = MAX(availableHeight - chrome, MIN(contentHeight, 120));
    CGFloat height = visibleContent + chrome;

    _scroll.frame = CGRectMake(0, 0, width, visibleContent);
    _scroll.contentSize = CGSizeMake(width, contentHeight);
    _scroll.scrollEnabled = contentHeight > visibleContent + 0.5;

    CGFloat buttonsY = visibleContent + actionsTop;
    CGFloat full = width - kActionSide * 2;
    CGFloat half = (full - kActionGap) / 2;
    CGFloat x = kActionSide;
    for (SGRAlertButton *button in _buttons) {
        if (_horizontal) {
            button.frame = CGRectMake(x, buttonsY, half, kActionHeight);
            x += half + kActionGap;
        } else {
            if (button == _cancelButton) buttonsY += cancelGap;
            button.frame = CGRectMake(kActionSide, buttonsY, full, kActionHeight);
            buttonsY += kActionHeight + kActionGap;
        }
    }

    // The panel is placed by bounds and center, so a transform on it (the animation) never makes its frame wrong.
    CGFloat centerY;
    if (alertStyle) {
        CGFloat top = safe.top + 20;
        CGFloat room = bounds.size.height - safe.top - MAX(safe.bottom, _keyboard) - 40;
        centerY = top + room / 2;
    } else {
        centerY = bounds.size.height - kSheetMargin - height / 2;
    }
    _panel.bounds = CGRectMake(0, 0, width, height);
    _panel.center = CGPointMake(bounds.size.width / 2, centerY);
    _panel.layer.shadowPath = [UIBezierPath bezierPathWithRoundedRect:_panel.bounds cornerRadius:kAlertRadius].CGPath;

    // The glass: the redesign's pane, the heavy body and the rim, then a dark film so white text reads on any page
    // behind. Under Reduce Transparency the pane is already solid.
    UIView *glass = SGRGlassPaneIn(_panel, &kPanelGlassKey, kAlertRadius);
    if (!SGRReduceTransparency()) SGRDimSheetGlass(glass, 0.45);
}

#pragma mark keyboard

- (void)keyboardChanged:(NSNotification *)note {
    if (![self isAlertStyle] || !self.isViewLoaded) return;
    CGRect end = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:end fromView:nil];
    _keyboard = MAX(0, CGRectGetHeight(self.view.bounds) - CGRectGetMinY(local));
    NSTimeInterval duration = [note.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationOptions curve = [note.userInfo[UIKeyboardAnimationCurveUserInfoKey] unsignedIntegerValue] << 16;
    [UIView animateWithDuration:duration delay:0 options:curve | UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self.view setNeedsLayout];
        [self.view layoutIfNeeded];
    } completion:nil];
}

#pragma mark touches

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (![gesture isKindOfClass:UILongPressGestureRecognizer.class]) return YES;
    return [self buttonAt:[gesture locationInView:_panel]] != nil;
}

- (SGRAlertButton *)buttonAt:(CGPoint)point {
    for (SGRAlertButton *button in _buttons) {
        if (CGRectContainsPoint(button.frame, point)) return button;
    }
    return nil;
}

- (void)pressed:(UILongPressGestureRecognizer *)gesture {
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
        case UIGestureRecognizerStateChanged: {
            SGRAlertButton *hit = [self buttonAt:[gesture locationInView:_panel]];
            if (hit && !hit.actionEnabled) hit = nil;
            if (hit != _pressed) {
                _pressed.highlighted = NO;
                _pressed = hit;
                hit.highlighted = YES;
                if (hit && gesture.state == UIGestureRecognizerStateChanged) [_feedback selectionChanged];
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            SGRAlertButton *button = _pressed;
            button.highlighted = NO;
            _pressed = nil;
            if (button) [self performButton:button];
            break;
        }
        default:
            _pressed.highlighted = NO;
            _pressed = nil;
            break;
    }
}

// A tap outside an action sheet is its Cancel button, as the system's sheet takes it. An alert ignores it, as the
// system's does: its Cancel can be a button of Spotify's that loses something (Discard on Discard changes?).
- (void)dimTapped {
    if (![self isAlertStyle]) [self runCancel];
}

- (void)runCancel {
    if (_cancelButton && _cancelButton.actionEnabled) [self performButton:_cancelButton];
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    return @[[UIKeyCommand keyCommandWithInput:UIKeyInputEscape modifierFlags:0 action:@selector(runCancel)]];
}

#pragma mark showing and going

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_animatedIn) return;
    _animatedIn = YES;
    BOOL still = SGRReduceMotion();
    BOOL alertStyle = [self isAlertStyle];
    if (!still) {
        _panel.transform = alertStyle ? CGAffineTransformMakeScale(1.15, 1.15)
                                      : CGAffineTransformMakeTranslation(0, _panel.bounds.size.height + kSheetMargin + 40);
    }
    BOOL fadePanel = alertStyle || still;
    if (!fadePanel) _panel.alpha = 1;   // a sheet slides in whole
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveLinear animations:^{
        self->_dim.alpha = 1;
        if (fadePanel) self->_panel.alpha = 1;
    } completion:nil];
    [UIView animateWithDuration:still ? 0 : 0.45 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_panel.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        // The first field takes the keyboard, as the system's alert does; without one, the screen takes the keys.
        if (self->_fields.count) [self->_fields.firstObject becomeFirstResponder];
        else [self becomeFirstResponder];
    }];
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, _titleLabel ?: _messageLabel ?: _panel);
}

- (void)animateOut:(void (^)(void))done {
    BOOL still = SGRReduceMotion();
    BOOL alertStyle = [self isAlertStyle];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_dim.alpha = 0;
        if (alertStyle || still) self->_panel.alpha = 0;
        else self->_panel.transform = CGAffineTransformMakeTranslation(0, self->_panel.bounds.size.height + kSheetMargin + 40);
    } completion:^(BOOL finished) { done(); }];
}

// The action runs after the alert is gone, as UIAlertController's does, so a handler that presents the next screen
// presents it from a clear stage.
- (void)performButton:(SGRAlertButton *)button {
    if (_finishing) return;
    _finishing = YES;
    SGRAlertHandler handler = button.handler;
    UIAlertAction *action = button.action;
    UIAlertController *alert = self.alert;   // alive until the handler has run: callers hold it weakly
    [self.view endEditing:YES];
    [self stopObserving];
    [self animateOut:^{
        void (^run)(void) = ^{
            if (handler) handler(action);
            (void)alert;
        };
        if (self.presentingViewController) [self dismissViewControllerAnimated:NO completion:run];
        else run();
    }];
}

@end
