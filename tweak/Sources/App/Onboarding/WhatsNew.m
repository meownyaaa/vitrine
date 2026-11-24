#import "Core/SGCore.h"
#import "Settings/SGPageStyle.h"
#import "Onboarding.h"
#import "App/About/About.h"

// This build's section of CHANGELOG.md, written by scripts/whats-new.sh when tweak/Makefile runs.
#if __has_include("SGWhatsNewNotes.h")
#import "SGWhatsNewNotes.h"
#else
static NSString *const SGWhatsNewNotes = @"";
#endif

NSArray<SGUpdateChange *> *SGWhatsNewChanges(void) {
    static NSArray<SGUpdateChange *> *changes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ changes = SGUpdateChangesIn(SGWhatsNewNotes); });
    return changes;
}

// A symbol a kind of change wears down the sheet, as Release Please names the kinds (release-please-config.json).
static NSString *symbolFor(NSString *kind) {
    NSDictionary<NSString *, NSString *> *symbols = @{
        @"Features": @"sparkles",
        @"Fixes": @"wrench.and.screwdriver",
        @"Performance": @"gauge.with.dots.needle.67percent",
        @"Reverts": @"arrow.uturn.backward",
    };
    return symbols[kind] ?: @"circle.fill";
}

static UILabel *label(NSString *text, UIFontTextStyle style, UIFontWeight weight, UIColor *color) {
    UILabel *view = [UILabel new];
    view.text = text;
    UIFont *font = [UIFont systemFontOfSize:[UIFont preferredFontForTextStyle:style].pointSize weight:weight];
    view.font = [[UIFontMetrics metricsForTextStyle:style] scaledFontForFont:font];
    view.adjustsFontForContentSizeCategory = YES;
    view.textColor = color;
    view.numberOfLines = 0;
    return view;
}

#pragma mark - the sheet

// What this version brought, the way the system's apps say it after an update: a large title, the
// changes under their kind with a symbol each, and Continue. A page sheet, so a swipe down closes it too.
@interface SGWhatsNewController : UIViewController
@end

@implementation SGWhatsNewController

- (instancetype)init {
    if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
    self.modalPresentationStyle = UIModalPresentationPageSheet;
    SGPresentDark(self);
    self.sheetPresentationController.prefersGrabberVisible = YES;
    return self;
}

- (UIView *)rowFor:(SGUpdateChange *)change {
    UIImageView *icon = SGSymbolView(symbolFor(change.kind), 20, UIImageSymbolWeightSemibold, 30);
    icon.tintColor = SGGreen();
    // Commit titles start in lower case; a sentence on a sheet does not.
    NSString *line = change.text.length ? [[change.text substringToIndex:1].uppercaseString stringByAppendingString:[change.text substringFromIndex:1]] : @"";
    UILabel *text = label(line, UIFontTextStyleBody, UIFontWeightRegular, UIColor.whiteColor);
    [text setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[icon, text]];
    row.alignment = UIStackViewAlignmentFirstBaseline;
    row.spacing = 14;
    [NSLayoutConstraint activateConstraints:@[[icon.widthAnchor constraintEqualToConstant:30]]];
    return row;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // iOS 26 gives a sheet its own material; before it the sheet takes the mod's page color.
    if (@available(iOS 26.0, *)) {} else self.view.backgroundColor = SGPageBackground();

    UILabel *title = label(@"What's New in Vitrine", UIFontTextStyleLargeTitle, UIFontWeightBold, UIColor.whiteColor);
    title.textAlignment = NSTextAlignmentCenter;
    title.accessibilityTraits = UIAccessibilityTraitHeader;
    UILabel *version = label([NSString stringWithFormat:@"Version %s", SG_VERSION], UIFontTextStyleSubheadline, UIFontWeightRegular, SGGrey());
    version.textAlignment = NSTextAlignmentCenter;

    UIStackView *column = [[UIStackView alloc] initWithArrangedSubviews:@[title, version]];
    column.axis = UILayoutConstraintAxisVertical;
    column.spacing = 6;
    [column setCustomSpacing:32 afterView:version];
    NSString *kind = nil;
    for (SGUpdateChange *change in SGWhatsNewChanges()) {
        if (![change.kind isEqualToString:kind]) {
            kind = change.kind;
            UILabel *heading = label(kind, UIFontTextStyleTitle3, UIFontWeightSemibold, UIColor.whiteColor);
            heading.accessibilityTraits = UIAccessibilityTraitHeader;
            if (column.arrangedSubviews.count > 2) [column setCustomSpacing:28 afterView:column.arrangedSubviews.lastObject];
            [column addArrangedSubview:heading];
            [column setCustomSpacing:14 afterView:heading];
        }
        UIView *row = [self rowFor:change];
        [column addArrangedSubview:row];
        [column setCustomSpacing:16 afterView:row];
    }
    column.translatesAutoresizingMaskIntoConstraints = NO;

    UIScrollView *scroll = [UIScrollView new];
    scroll.alwaysBounceVertical = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:column];
    [self.view addSubview:scroll];

    UIButton *done = SGOnboardingButton(@"Continue");
    [done addAction:[UIAction actionWithHandler:^(UIAction *action) {
        [self dismissViewControllerAnimated:YES completion:nil];
    }] forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:done];

    const CGFloat margin = 32;
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    UILayoutGuide *frame = scroll.frameLayoutGuide, *content = scroll.contentLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:done.topAnchor constant:-12],
        [column.topAnchor constraintEqualToAnchor:content.topAnchor constant:56],
        [column.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-16],
        [column.leadingAnchor constraintEqualToAnchor:content.leadingAnchor constant:margin],
        [column.trailingAnchor constraintEqualToAnchor:content.trailingAnchor constant:-margin],
        [column.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-2 * margin],
        [done.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:24],
        [done.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-24],
        [done.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-16],
    ]];
}

// Continue and a swipe down both end here; the signing sheet waits for whatever held the screen.
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    if (self.isBeingDismissed) SGShowSigningFixIfPending();
}

@end

#pragma mark - entry

static __weak SGWhatsNewController *sg_sheet;

BOOL SGWhatsNewShowing(void) {
    return sg_sheet != nil;
}

void SGShowWhatsNew(void) {
    if (sg_sheet || !SGWhatsNewChanges().count) return;
    UIViewController *top = SGTopController();
    // Presenting from an alert lands nowhere; the sheet waits for it to go.
    if (!top || SGIsAlertController(top)) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ SGShowWhatsNew(); });
        return;
    }
    SGWhatsNewController *sheet = [SGWhatsNewController new];
    sg_sheet = sheet;
    [top presentViewController:sheet animated:YES completion:nil];
}
