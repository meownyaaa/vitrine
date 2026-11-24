// Spotify's context menu sheet mocked under its class name, presented from a now playing controller on a tap
// of the player's more button, so SpeedPitchMenu.x's hook adds Speed and pitch the way it would on the phone.
// `sleep` opens a second sheet from the first, as the ⋯ card's Sleep timer does, and `notap` one with no tap:
// neither may get the block.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install <udid> build/MenuHarness.app
//     xcrun simctl launch --console-pty <udid> com.vojta.menuharness [footer] [nospeed] [loading] [stuck] [open] [animated] [sleep] [notap] [minute]
//
// The plain run opens the menu at 1 s, opens the block at 3 s, moves the sliders at 5 s, checks what the
// block says at 6 s (PASS or FAIL lines), closes the block at 7 s and checks its row at 8 s. `loading` builds the sheet the way Spotify's is (the ivars of ContextMenuViewController in
// 9.1.78: a header, a content container holding a ContextMenuTableView whose height follows its
// contentSize by KVO, a loading spinner) and hands it its rows only 4 s after it is up, as Spotify does
// once its item factories have answered; `stuck` never hands them over. `open` opens the block on a first
// menu, closes it, and brings up a second one with the block open, as it stays for the session. Every frame of the first second the block is on screen
// is checked for a color of the system tint on anything it draws, and what the sheet shows is reported.
// `animated` offers the redesign's Animated artwork switch: it is flipped, then the block opened and
// closed, and where the switch's row sits is reported each time.
#import <UIKit/UIKit.h>

#pragma mark - what SpeedPitchMenu.x calls

static double sg_speed = 1;
static float sg_pitch;
static BOOL sg_speedAllowed = YES;
void SGPlayFeedback(NSInteger feedback) { NSLog(@"[harness] feedback %ld", (long)feedback); }
void SGPrepareFeedback(NSInteger feedback) {}
// Redesigned/Player/PlayerPanelGlass.m: below iOS 26 the panel's glass; on iOS 26, which the harness runs, nothing.
void SGPlayerStylePanel(UIView *content) {}
double SGPlayerSpeed(void) { return sg_speed; }
BOOL SGPlayerSpeedAllowed(void) { return sg_speedAllowed; }
void SGSetPlayerSpeed(double speed) { sg_speed = speed; NSLog(@"[harness] speed %.2f", speed); }
float SGPlayerPitch(void) { return sg_pitch; }
void SGSetPlayerPitch(float semitones) { sg_pitch = semitones; NSLog(@"[harness] pitch %.0f", semitones); }
BOOL SGPlayerPitchAvailable(void) { return YES; }
static BOOL sg_follows = YES;
BOOL SGPlayerPitchFollowsSpeed(void) { return sg_follows; }
void SGSetPlayerPitchFollowsSpeed(BOOL follows) { sg_follows = follows; NSLog(@"[harness] pitch follows speed %d", follows); }
static BOOL sg_animated;
BOOL SGPlayerMenuOffersAnimatedArtwork(void) { return [NSProcessInfo.processInfo.arguments containsObject:@"animated"]; }
BOOL SGPlayerMenuAnimatedArtwork(void) { return sg_animated; }
void SGPlayerMenuSetAnimatedArtwork(BOOL on) { sg_animated = on; NSLog(@"[harness] animated artwork %d", on); }
// The redesign's system menu, which never takes this sheet over here (harness/system-menu has it).
BOOL SGPlayerMenuReplaced(UIViewController *menu) { return NO; }
// The audio effects' settings, kept in a dictionary: the reverb slider reads and writes them.
static NSMutableDictionary *sg_dsp;
BOOL SGDSPSwitch(NSString *key) { return [sg_dsp[key] boolValue]; }
void SGDSPSetSwitch(NSString *key, BOOL on) { if (!sg_dsp) sg_dsp = [NSMutableDictionary dictionary]; sg_dsp[key] = @(on); NSLog(@"[harness] %@ %d", key, on); }
double SGDSPNumber(NSString *key) { return [sg_dsp[key] doubleValue]; }
void SGDSPSetNumber(NSString *key, double value) { if (!sg_dsp) sg_dsp = [NSMutableDictionary dictionary]; sg_dsp[key] = @(value); NSLog(@"[harness] %@ %.0f", key, value); }

static BOOL argument(NSString *name) {
    return [NSProcessInfo.processInfo.arguments containsObject:name];
}

static void check(BOOL ok, NSString *what) {
    NSLog(@"[harness] %@ %@", ok ? @"PASS" : @"FAIL", what);
}

static NSArray<NSArray<NSString *> *> *spotifyRows(void) {
    return @[@[@"plus.circle", @"Add to playlist"], @[@"music.note.list", @"Add to queue"], @[@"person", @"Go to artist"],
             @[@"square.stack", @"Go to album"], @[@"square.and.arrow.up", @"Share"], @[@"moon", @"Sleep timer"],
             @[@"dot.radiowaves.left.and.right", @"Go to song radio"], @[@"info.circle", @"View credits"]];
}

#pragma mark - Spotify's sheet

// ContextMenu_InternalImpl.(anon).ContextMenuTableView: sized to its content, its intrinsic size is its
// contentSize (it overrides intrinsicContentSize, layoutSubviews and reloadData in 9.1.78).
@interface SGHarnessMenuTable : UITableView
@end

@implementation SGHarnessMenuTable
- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, self.contentSize.height);
}
- (void)reloadData {
    [super reloadData];
    [self invalidateIntrinsicContentSize];
}
@end

@interface _TtC24ContextMenu_InternalImpl25ContextMenuViewController : UIViewController <UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UIActivityIndicatorView *spinner;
@property (nonatomic, strong) NSLayoutConstraint *contentHeight;
@property (nonatomic) BOOL loaded;
@end

@implementation _TtC24ContextMenu_InternalImpl25ContextMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    BOOL loading = argument(@"loading") || argument(@"stuck");
    self.loaded = !loading;
    self.table = [[(loading ? SGHarnessMenuTable.class : UITableView.class) alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.backgroundColor = UIColor.clearColor;
    self.table.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.table.rowHeight = 56;
    self.table.dataSource = self;
    [self.table registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    if (argument(@"footer")) {
        UILabel *heading = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 80)];
        heading.text = @"   Spotify's heading";
        heading.textColor = UIColor.whiteColor;
        self.table.tableHeaderView = heading;
    }
    if (!loading) {
        self.table.frame = self.view.bounds;
        self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self.view addSubview:self.table];
        return;
    }

    // Spotify's layout: its own header (the track), a divider, then the content container with the table
    // in it, the spinner over the container while the rows are not in.
    UILabel *header = [UILabel new];
    header.text = @"   Blinding Lights · The Weeknd";
    header.textColor = UIColor.whiteColor;
    UIView *container = [UIView new];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.color = UIColor.whiteColor;
    for (UIView *view in @[header, container, self.table, self.spinner]) view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:header];
    [self.view addSubview:container];
    [container addSubview:self.table];
    [container addSubview:self.spinner];
    self.contentHeight = [self.table.heightAnchor constraintEqualToConstant:0];
    self.contentHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:16],
        [header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [header.heightAnchor constraintEqualToConstant:56],
        [container.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [container.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [container.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [container.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor],
        [container.heightAnchor constraintGreaterThanOrEqualToConstant:120],
        [self.table.topAnchor constraintEqualToAnchor:container.topAnchor],
        [self.table.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
        [self.table.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
        [self.table.bottomAnchor constraintLessThanOrEqualToAnchor:container.bottomAnchor],
        self.contentHeight,
        [self.spinner.centerXAnchor constraintEqualToAnchor:container.centerXAnchor],
        [self.spinner.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
    ]];
    [self.spinner startAnimating];
    // ContextMenuTableViewCoordinator.tableViewContentSizeObservation
    [self.table addObserver:self forKeyPath:@"contentSize" options:NSKeyValueObservingOptionNew context:NULL];
}

- (void)dealloc {
    if (self.spinner) [self.table removeObserver:self forKeyPath:@"contentSize"];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    self.contentHeight.constant = self.table.contentSize.height;
}

// What the model publisher does once the item factories have answered.
- (void)takeRows {
    self.loaded = YES;
    [self.spinner stopAnimating];
    self.spinner.hidden = YES;
    [self.table reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaded ? spotifyRows().count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    UIListContentConfiguration *content = cell.defaultContentConfiguration;
    content.text = spotifyRows()[indexPath.row][1];
    content.textProperties.color = UIColor.whiteColor;
    content.image = [UIImage systemImageNamed:spotifyRows()[indexPath.row][0]];
    content.imageProperties.tintColor = [UIColor colorWithWhite:0.7 alpha:1];
    cell.contentConfiguration = content;
    cell.backgroundColor = UIColor.clearColor;
    return cell;
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
}

@end

#pragma mark - the player

// The player's header row (NowPlaying_ModesImpl.HeaderElementsUnit), its more button an Encore button with
// the identifier "Context menu" (trees/lyrics.txt:183), which SpeedPitchMenu.x finds and watches.
@interface _TtC20NowPlaying_ModesImpl18HeaderElementsUnit : UIViewController
@property (nonatomic, strong) UIButton *more;
@end

@implementation _TtC20NowPlaying_ModesImpl18HeaderElementsUnit
- (void)viewDidLoad {
    [super viewDidLoad];
    self.more = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.more setImage:[UIImage systemImageNamed:@"ellipsis"] forState:UIControlStateNormal];
    self.more.frame = CGRectMake(330, 0, 48, 48);
    self.more.accessibilityIdentifier = @"Context menu";
    [self.view addSubview:self.more];
}
@end

@interface NowPlayingHarnessViewController : UIViewController
@property (nonatomic, strong) _TtC20NowPlaying_ModesImpl18HeaderElementsUnit *header;
@end

@implementation NowPlayingHarnessViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.25 green:0.1 blue:0.2 alpha:1];
    self.header = [_TtC20NowPlaying_ModesImpl18HeaderElementsUnit new];
    [self addChildViewController:self.header];
    self.header.view.frame = CGRectMake(0, 60, 402, 48);
    [self.view addSubview:self.header.view];
    [self.header didMoveToParentViewController:self];
}
@end

static UIView *findBlock(UIView *root) {
    if ([NSStringFromClass(root.class) isEqualToString:@"SGSpeedPitchView"]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = findBlock(child);
        if (found) return found;
    }
    return nil;
}

static NSArray<UISlider *> *sliders(UIView *root) {
    NSMutableArray *found = [NSMutableArray array];
    if ([root isKindOfClass:UISlider.class]) [found addObject:root];
    for (UIView *child in root.subviews) [found addObjectsFromArray:sliders(child)];
    return found;
}

#pragma mark - the tint check

// A color is the system tint's when it resolves, in the view's own traits, to the system blue.
static BOOL isTint(UIColor *color, UIView *view) {
    if (!color) return NO;
    UIColor *resolved = [color resolvedColorWithTraitCollection:view.traitCollection];
    UIColor *blue = [UIColor.systemBlueColor resolvedColorWithTraitCollection:view.traitCollection];
    CGFloat r, g, b, a, br, bg, bb, ba;
    if (![resolved getRed:&r green:&g blue:&b alpha:&a] || ![blue getRed:&br green:&bg blue:&bb alpha:&ba]) return NO;
    return a > 0.05 && fabs(r - br) < 0.08 && fabs(g - bg) < 0.08 && fabs(b - bb) < 0.08;
}

// Everything the block draws in a color of its own: labels' text, buttons' titles, and whatever takes the
// tint (templated glyphs, sliders' thumbs and tracks).
static void tintedViews(UIView *view, NSMutableArray<NSString *> *out) {
    if (view.isHidden || view.alpha < 0.01) return;
    NSString *name = NSStringFromClass(view.class);
    if ([view isKindOfClass:UILabel.class] && isTint(((UILabel *)view).textColor, view)) [out addObject:[name stringByAppendingFormat:@" text \"%@\"", ((UILabel *)view).text]];
    if ([view isKindOfClass:UIImageView.class]) {
        UIImage *image = ((UIImageView *)view).image;
        // Drawn in the tint when templated, or left automatic on a symbol; a bitmap left automatic keeps
        // its own colors (the sliders' end images).
        BOOL templated = image.renderingMode == UIImageRenderingModeAlwaysTemplate
            || (image.renderingMode == UIImageRenderingModeAutomatic && image.isSymbolImage);
        if (templated && isTint(view.tintColor, view)) [out addObject:[name stringByAppendingString:@" glyph"]];
    }
    if ([view isKindOfClass:UIButton.class] && isTint([(UIButton *)view titleColorForState:((UIButton *)view).state], view)) [out addObject:[name stringByAppendingString:@" title"]];
    if ([view isKindOfClass:UISlider.class]) {
        UISlider *slider = (UISlider *)view;
        if (isTint(slider.minimumTrackTintColor ?: slider.tintColor, view)) [out addObject:@"UISlider track"];
    }
    if (isTint(view.backgroundColor, view)) [out addObject:[name stringByAppendingString:@" background"]];
    for (UIView *child in view.subviews) tintedViews(child, out);
}

@interface SGHarnessFrameWatch : NSObject
@property (nonatomic, weak) UIView *root;
@property (nonatomic) NSInteger frames, tinted;
@property (nonatomic) CFTimeInterval firstSeen;
@end

@implementation SGHarnessFrameWatch
- (void)tick:(CADisplayLink *)link {
    UIView *block = findBlock(self.root);
    if (!block.window) return;
    if (!self.firstSeen) self.firstSeen = link.timestamp;
    self.frames++;
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    tintedViews(block, found);
    if (found.count) {
        self.tinted++;
        NSLog(@"[harness] %p frame %ld: system tint on %@", self, (long)self.frames, [found componentsJoinedByString:@", "]);
    }
    if (link.timestamp - self.firstSeen > 1) {
        [link invalidate];
        NSLog(@"[harness] %p tint check: %ld of the block's first %ld frames drew something in the system tint", self, (long)self.tinted, (long)self.frames);
    }
}
@end

static void report(_TtC24ContextMenu_InternalImpl25ContextMenuViewController *menu, NSString *when) {
    UITableView *table = menu.table;
    NSInteger cells = 0;
    for (UITableViewCell *cell in table.visibleCells) cells += CGRectIntersectsRect([cell convertRect:cell.bounds toView:menu.view], menu.view.bounds) ? 1 : 0;
    UIView *block = findBlock(menu.view);
    NSLog(@"[harness] %@: table %@ content %.0f, %ld of %ld rows on screen, spinner %@, block %@ in the %@",
          when, NSStringFromCGRect(table.frame), table.contentSize.height, (long)cells, (long)[table numberOfRowsInSection:0],
          menu.spinner ? (menu.spinner.isAnimating ? @"spinning" : @"stopped") : @"none",
          block ? NSStringFromCGRect([block convertRect:block.bounds toView:menu.view]) : @"missing",
          table.tableHeaderView == block ? @"header" : table.tableFooterView == block ? @"footer" : @"nowhere");
}

#pragma mark - the sleep timer's cells

// Spotify's two cells that list the sleep timer's durations, under their class names (MinuteLabel.x).
@interface _TtC24ContextMenu_InternalImpl24ContextMenuTableViewCell : UITableViewCell
@end
@implementation _TtC24ContextMenu_InternalImpl24ContextMenuTableViewCell
@end
@interface _TtC30PlaybackControl_SleepTimerImpl10OptionCell : UICollectionViewCell
@end
@implementation _TtC30PlaybackControl_SleepTimerImpl10OptionCell
@end

// `minute`: a label reading "1 minutes" in each cell reads "1 minute" once laid out, in the font it had; "5
// minutes", another language's text and a label outside those cells stay as they were.
static void checkMinute(UIWindow *window) {
    UIFont *font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    UILabel *(^label)(UIView *, NSString *) = ^UILabel *(UIView *host, NSString *text) {
        UILabel *made = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 200, 30)];
        made.attributedText = [[NSAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName: font}];
        [host addSubview:made];
        return made;
    };
    UIView *row = [[_TtC24ContextMenu_InternalImpl24ContextMenuTableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    UIView *option = [[_TtC30PlaybackControl_SleepTimerImpl10OptionCell alloc] initWithFrame:CGRectMake(0, 100, 300, 50)];
    UIView *elsewhere = [[UIView alloc] initWithFrame:CGRectMake(0, 200, 300, 50)];
    UILabel *inRow = label(((UITableViewCell *)row).contentView, @"1 minutes"), *five = label(((UITableViewCell *)row).contentView, @"5 minutes");
    UILabel *inOption = label(((UICollectionViewCell *)option).contentView, @"1 minutes"), *other = label(((UICollectionViewCell *)option).contentView, @"1 minuto");
    UILabel *outside = label(elsewhere, @"1 minutes");
    row.frame = CGRectMake(0, 0, 300, 50);
    for (UIView *view in @[row, option, elsewhere]) {
        [window addSubview:view];
        [view setNeedsLayout];
        [view layoutIfNeeded];
    }
    check([inRow.text isEqualToString:@"1 minute"] && [inRow.font isEqual:font], [NSString stringWithFormat:@"the context menu row reads \"%@\" in its own font", inRow.text]);
    check([inOption.text isEqualToString:@"1 minute"] && [inOption.font isEqual:font], [NSString stringWithFormat:@"the options cell reads \"%@\" in its own font", inOption.text]);
    check([five.text isEqualToString:@"5 minutes"] && [other.text isEqualToString:@"1 minuto"] && [outside.text isEqualToString:@"1 minutes"],
          [NSString stringWithFormat:@"the rest is left alone (\"%@\", \"%@\", \"%@\" outside the cells)", five.text, other.text, outside.text]);
}

#pragma mark - the run

@interface SGHarnessApp : UIResponder <UIApplicationDelegate>
@end

@implementation SGHarnessApp
@end

@interface SGHarnessScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGHarnessScene

static void after(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

static void tapRow(UIViewController *menu) {
    UIControl *row = (UIControl *)findBlock(menu.view).subviews.firstObject;
    [row sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    sg_speedAllowed = !argument(@"nospeed");
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    NowPlayingHarnessViewController *player = [NowPlayingHarnessViewController new];
    self.window.rootViewController = player;
    [self.window makeKeyAndVisible];

    static SGHarnessFrameWatch *watch;
    __block _TtC24ContextMenu_InternalImpl25ContextMenuViewController *menu;
    BOOL loading = argument(@"loading"), stuck = argument(@"stuck");
    // Spotify's ⋯ card, put up by a tap on the player's more button: the tap first, as a finger lifting off it.
    void (^present)(void) = ^{
        [player.header.more sendActionsForControlEvents:UIControlEventTouchDown];
        [player.header.more sendActionsForControlEvents:UIControlEventTouchUpInside];
        menu = [_TtC24ContextMenu_InternalImpl25ContextMenuViewController new];
        UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:menu];
        navigation.navigationBarHidden = YES;
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.mediumDetent, UISheetPresentationControllerDetent.largeDetent];
        watch = [SGHarnessFrameWatch new];
        watch.root = navigation.view;
        [[CADisplayLink displayLinkWithTarget:watch selector:@selector(tick:)] addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
        [player presentViewController:navigation animated:YES completion:nil];
    };
    if (argument(@"minute")) {
        after(1, ^{ checkMinute(self.window); });
        return;
    }
    if (argument(@"sleep") || argument(@"notap")) {
        // `sleep`: the ⋯ card's Sleep timer row opens a context menu sheet of its own in the card, with no tap
        // on the more button; it must stay Spotify's. `notap`: a sheet the player puts up with no tap at all.
        BOOL sleep = argument(@"sleep");
        after(1, ^{
            if (sleep) {
                present();
                return;
            }
            menu = [_TtC24ContextMenu_InternalImpl25ContextMenuViewController new];
            [player presentViewController:[[UINavigationController alloc] initWithRootViewController:menu] animated:YES completion:nil];
        });
        if (!sleep) {
            after(3, ^{ check(!findBlock(menu.view), @"a sheet the player put up with no tap on ⋯ has no Speed and pitch"); });
            return;
        }
        __block UIViewController *card;
        after(3, ^{
            card = menu;
            check(findBlock(card.view) != nil, @"the ⋯ card has Speed and pitch");
            menu = [_TtC24ContextMenu_InternalImpl25ContextMenuViewController new];
            [card.navigationController pushViewController:menu animated:YES];
        });
        after(5, ^{
            check(menu.view.window && menu.navigationController.presentingViewController == player, @"the sleep timer sheet is up, presented from the player");
            check(!findBlock(menu.view), @"the sleep timer sheet has no Speed and pitch");
        });
        return;
    }
    if (argument(@"animated")) {
        void (^where)(NSString *) = ^(NSString *when) {
            UIView *block = findBlock(menu.view);
            UISwitch *toggle = nil;
            for (UIView *row in block.subviews) {
                for (UIView *view in row.subviews) {
                    if ([view isKindOfClass:UISwitch.class] && [view.accessibilityLabel isEqualToString:@"Animated artwork"]) toggle = (UISwitch *)view;
                }
            }
            CGRect row = [toggle.superview convertRect:toggle.superview.bounds toView:block];
            BOOL inside = CGRectContainsRect(block.bounds, row) && row.size.height > 0;
            NSLog(@"[harness] %@: block %.0f tall, the Animated artwork row at %.0f (%@), switch %@ -- %@", when,
                  block.bounds.size.height, row.origin.y, inside ? @"inside the block" : @"cut off", toggle.on ? @"on" : @"off",
                  toggle && inside && toggle.on == sg_animated ? @"PASS" : @"FAIL");
            if (toggle && ![when isEqualToString:@"closed"]) {
                toggle.on = !toggle.on;
                [toggle sendActionsForControlEvents:UIControlEventValueChanged];
            }
        };
        after(1, present);
        after(2.5, ^{ where(@"shown"); });
        after(3, ^{ tapRow(menu); });
        after(4.5, ^{ where(@"opened"); });
        after(5, ^{ tapRow(menu); });
        after(6.5, ^{ where(@"closed"); });
        return;
    }
    if (argument(@"open")) {
        // The block keeps whether it was open for the session: open it on a first menu, close that menu,
        // and watch a second one come up with the block already open.
        after(1, present);
        after(3, ^{ tapRow(menu); });
        after(4.5, ^{ [player dismissViewControllerAnimated:YES completion:nil]; });
        after(6, present);
        after(8, ^{ report(menu, @"reopened"); });
        return;
    }
    after(1, present);
    if (loading || stuck) {
        after(3, ^{ report(menu, @"loading"); });
        if (loading) after(5, ^{ [menu takeRows]; });
        after(6.5, ^{ report(menu, loading ? @"rows in" : @"still loading"); });
        if (stuck) return;
        after(7, ^{ tapRow(menu); });
        after(8.5, ^{ report(menu, @"block toggled"); });
        return;
    }
    after(3, ^{
        NSLog(@"[harness] block %@", findBlock(menu.view));
        tapRow(menu);
    });
    after(5, ^{
        NSArray<UISlider *> *found = sliders(findBlock(menu.view));
        // A disabled slider takes no finger, so `nospeed` leaves speed alone.
        if (sg_speedAllowed) {
            found[0].value = 1.27;
            [found[0] sendActionsForControlEvents:UIControlEventValueChanged];
            [found[0] sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
        found[1].value = -3.2;
        [found[1] sendActionsForControlEvents:UIControlEventValueChanged];
        [found[1] sendActionsForControlEvents:UIControlEventTouchUpInside];
        found[2].value = 41;
        [found[2] sendActionsForControlEvents:UIControlEventValueChanged];
        [found[2] sendActionsForControlEvents:UIControlEventTouchUpInside];
    });
    // What the block says once the fingers are off: the reverb's thumb where it was let go, and while pitch
    // follows a speed that is not normal, no semitones claimed. Without speed (`nospeed`) the switch is off
    // limits and the pitch is the slider's.
    BOOL speed = !argument(@"nospeed");
    after(6, ^{
        UIView *block = findBlock(menu.view);
        NSArray<UISlider *> *found = sliders(block);
        UIButton *pitch = [block valueForKey:@"_pitchValue"];
        UISwitch *follows = [block valueForKey:@"_follows"];
        check(found[2].value == 40, [NSString stringWithFormat:@"the reverb's thumb stays at 40 once let go (%.0f)", found[2].value]);
        NSString *want = speed ? @"Follows speed" : @"−3 st";
        check([[pitch titleForState:UIControlStateNormal] isEqualToString:want] && pitch.enabled == !speed,
              [NSString stringWithFormat:@"the pitch reads %@ (%@, reset %@)", want, [pitch titleForState:UIControlStateNormal], pitch.enabled ? @"on" : @"off"]);
        check(follows.enabled == speed, [NSString stringWithFormat:@"Pitch follows speed %@", speed ? @"enabled" : @"disabled without speed"]);
    });
    after(7, ^{ tapRow(menu); });
    after(8, ^{
        UILabel *summary = [findBlock(menu.view) valueForKey:@"_summary"];
        NSString *want = speed ? @"1.25×  Reverb" : @"−3 st  Reverb";
        check([summary.text isEqualToString:want], [NSString stringWithFormat:@"the closed row reads \"%@\" (\"%@\")", want, summary.text]);
    });
}

@end

// Before every %ctor, so the redesign's gate reads on.
__attribute__((constructor(101))) static void sgr_harnessDefaults(void) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"spotifyglass.redesign"];
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessApp.class));
    }
}
