// Redesigned/ContextMenu/ContextMenu.x and Redesigned/Player/PlayerMenu.m run for real against a mock of
// Spotify's player ⋯ and its context menu sheet (its class name, a table of rows that are Encore-style ListRow
// controls and no didSelect, as on the phone), and the system menu checked as it comes up.
//
//     THEOS=$HOME/theos ./build.sh && xcrun simctl install <udid> build/SystemMenuHarness.app
//     xcrun simctl launch --console-pty <udid> com.vitrine.systemmenuharness <scenario>
//
// The ⋯ is the mod's own pull-down button over Spotify's ⋯, and a tap on it is a finger's touch (../tabbar/touch.m),
// down and up, at its middle: UIKit opens the button's menu on the touch down. (Tapped with -performPrimaryAction
// before, the harness missed that a finger's touch on a button holding no menu yet opened nothing, 2026-10-06.)
// Every scenario taps at 1 s and prints PASS or FAIL lines, then `done` (README.md lists them). A pick or a
// submenu is opened the way a finger on the menu does it, through the menu view's own selection
// (_UIContextMenuView's _handleSelectionForElement:, the harness's only private call).
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import "Redesigned/ContextMenu/ContextMenu.h"
#import "Shared/LyricsSources/LyricsSources.h"

// The album footer is exercised by harness/album-queue and the Spotify simulator test. These
// player-menu fixtures do not provide an album page or the shared album footer.
void SGAlbumQueueInstall(UIViewController *menu) {}
void SGBatchTranslationInstall(UIViewController *menu) {}

void SGRPlayerMenuWatch(UIView *button);
// touch.m: a finger's touches, through UIKit's own recognizers.
extern void SGHarnessTap(UIWindow *window, CGPoint point);

static NSString *scenario(void) {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    return arguments.count > 1 ? arguments.lastObject : @"rows";
}

static BOOL is(NSString *run) {
    return [scenario() isEqualToString:run];
}

static void check(BOOL ok, NSString *what) {
    NSLog(@"[harness] %@ %@", ok ? @"PASS" : @"FAIL", what);
}

static void after(NSTimeInterval seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

// Runs `then` once `condition` holds, or after `limit` seconds whether or not it does; looks every 10 ms.
static void waitFor(BOOL (^condition)(void), NSTimeInterval limit, dispatch_block_t then) {
    if (condition() || limit <= 0) {
        then();
        return;
    }
    after(0.01, ^{ waitFor(condition, limit - 0.01, then); });
}

#pragma mark - what the menu's code calls

static double sg_speed = 1;
static float sg_pitch, sg_reverb;
static BOOL sg_follows = YES, sg_animated;
static NSInteger sg_background = 2;
double SGPlayerSpeed(void) { return sg_speed; }
BOOL SGPlayerSpeedAllowed(void) { return YES; }
void SGSetPlayerSpeed(double speed) { sg_speed = speed; NSLog(@"[harness] speed %.2f", speed); }
void SGPlayerShowSpeedPitchPanel(UIView *from) { NSLog(@"[harness] speed and pitch panel requested"); }
float SGPlayerPitch(void) { return sg_pitch; }
void SGSetPlayerPitch(float semitones) { sg_pitch = semitones; NSLog(@"[harness] pitch %.0f", semitones); }
BOOL SGPlayerPitchAvailable(void) { return YES; }
BOOL SGPlayerPitchFollowsSpeed(void) { return sg_follows; }
void SGSetPlayerPitchFollowsSpeed(BOOL follows) { sg_follows = follows; }
float SGPlayerReverb(void) { return sg_reverb; }
void SGPlayerSetReverb(float amount) { sg_reverb = amount; }
BOOL SGPlayerMenuOffersAnimatedArtwork(void) { return YES; }
BOOL SGPlayerMenuAnimatedArtwork(void) { return sg_animated; }
void SGPlayerMenuSetAnimatedArtwork(BOOL on) { sg_animated = on; NSLog(@"[harness] animated artwork %d", on); }
static NSUInteger sg_marked;
void SGPlayerMenuMarkPlayers(void) { sg_marked++; }
// Lyrics Source (LyricsSources.m, LyricsPick.m): every source off, so the menu offers no Lyrics Source, and the
// rest is never asked.
NSString *SGKaraokePlayingTrack(void) { return @"harness"; }
BOOL SGLyricsEnabled(void) { return NO; }
NSArray<NSString *> *SGLyricsOrder(void) { return @[]; }
SGLyricsProvider *SGLyricsProviderFor(NSString *key) { return nil; }
NSString *SGLyricsCreditFor(NSString *trackID) { return nil; }
NSString *SGLyricsChosenSource(NSString *trackID) { return nil; }
NSDictionary<NSString *, SGLyricsResult *> *SGLyricsOffersSoFar(NSString *trackID, NSArray<NSString *> **asking) { return @{}; }
void SGLyricsChooseSource(NSString *trackID, NSString *key) {}
void SGLyricsChooseAutomatic(NSString *trackID) {}
// The player's background (Redesigned/Player/Player.h's SGRPlayerBackgroundKind): Fluid, so the menu offers
// Animated and the Visualizer; Show Animated Artwork switches it on.
NSInteger SGRPlayerBackground(void) { return sg_background; }
void SGRPlayerMenuSetBackground(NSInteger kind) { sg_background = kind; SGPlayerMenuSetAnimatedArtwork(kind == 3); }
@class SPTPlayerState;
SPTPlayerState *SGPlayerState(void) { return nil; }
NSString *SGURIString(id uri) { return nil; }
UIView *SGRPinnedMoreRecentButton(void) { return nil; }
void SGRAnimate(NSInteger motion, void (^animations)(void), void (^completion)(BOOL finished)) {
    [UIView animateWithDuration:0.2 animations:animations completion:completion];
}

// Every action and submenu the menu makes, by its title, so the harness can pick or open one.
static NSMutableDictionary<NSString *, UIMenuElement *> *sg_elements;
static IMP sg_actionWithTitle, sg_menuWithTitle;
static UIAction *recordAction(id self, SEL _cmd, NSString *title, UIImage *image, NSString *identifier, UIActionHandler handler) {
    UIAction *action = ((UIAction *(*)(id, SEL, NSString *, UIImage *, NSString *, UIActionHandler))sg_actionWithTitle)(self, _cmd, title, image, identifier, handler);
    if (title) sg_elements[title] = action;
    return action;
}
static UIMenu *recordMenu(id self, SEL _cmd, NSString *title, UIImage *image, NSString *identifier, UIMenuOptions options, NSArray *children) {
    UIMenu *menu = ((UIMenu *(*)(id, SEL, NSString *, UIImage *, NSString *, UIMenuOptions, NSArray *))sg_menuWithTitle)(self, _cmd, title, image, identifier, options, children);
    if (title.length) sg_elements[title] = menu;
    return menu;
}

#pragma mark - Spotify's sheet

// The rows of 9.1.78's player sheet, with their item numbers; Sleep timer last, below what the sheet shows.
static NSArray<NSArray<NSString *> *> *spotifyRows(void) {
    if (is(@"podcast")) return @[@[@"text.badge.plus", @"Add to queue", @"11"], @[@"square.stack", @"Go to show", @"40"], @[@"square.and.arrow.up", @"Share", @"9"]];
    NSMutableArray *rows = [@[@[@"plus.circle", @"Add to playlist", @"19"], @[@"text.badge.plus", @"Add to queue", @"11"],
                              @[@"square.and.arrow.up", @"Share", @"9"], @[@"square.stack", @"Go to album", @"1"],
                              @[@"quote.bubble", @"Lyrics", @"28"]] mutableCopy];
    for (int i = 0; i < 9; i++) [rows addObject:@[@"circle", [NSString stringWithFormat:@"Row %d", i + 1], [NSString stringWithFormat:@"%d", 60 + i]]];
    [rows addObject:@[@"moon", @"Sleep timer", @"44"]];
    return rows;
}

static NSString *sg_selected;
static NSUInteger sg_spotifyTaps;
// The sheet waits for the harness to give it its rows (sg_rowsAfter seconds after it loads, or never).
static BOOL sg_rowsHeld, sg_rowsNever;
static NSTimeInterval sg_rowsAfter;

// A row of the mod's own in the sheet's header, as Redesigned/Playlist/PlaylistMenu.x puts Sort there.
@interface SGHarnessSortRow : UIControl
@end
@implementation SGHarnessSortRow
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.arrow.down"]];
    glyph.frame = CGRectMake(16, 16, 24, 24);
    [self addSubview:glyph];
    self.accessibilityLabel = @"Sort";
    [self addTarget:self action:@selector(fired) forControlEvents:UIControlEventTouchUpInside];
    return self;
}
- (void)fired {
    UIViewController *sheet = nil;
    for (UIResponder *responder = self; responder && !sheet; responder = responder.nextResponder) {
        if ([responder isKindOfClass:UINavigationController.class]) sheet = (UIViewController *)responder;
    }
    sg_selected = @"Sort";
    [sheet.presentingViewController dismissViewControllerAnimated:YES completion:^{ NSLog(@"[harness] sort fired"); }];
}
@end

// Spotify's row: an Encore ListRow, a control whose identifier is the item number, acting on touch up inside.
@interface SGHarnessListRow : UIControl
@property (nonatomic, copy) NSString *title;
@end
@implementation SGHarnessListRow
@end

@class SGHarnessPlayer;
static SGHarnessPlayer *sg_player;

@interface _TtC24ContextMenu_InternalImpl25ContextMenuViewController : UIViewController <UITableViewDataSource>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic) BOOL loaded, sleepOptions;
- (void)giveRows;
@end

@interface SGHarnessPlayer : UIViewController
@property (nonatomic, strong) UIButton *more, *arrow;
@property (nonatomic, strong) UIView *header;
@property (nonatomic) NSUInteger arrowTaps, frontDowns, frontUps, frontCancels;
@property (nonatomic, weak) UINavigationController *sheet;
@property (nonatomic, weak) UIViewController *sleepSheet;
- (void)presentSleepOptions;
@end

@implementation _TtC24ContextMenu_InternalImpl25ContextMenuViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    self.loaded = self.sleepOptions || !sg_rowsHeld;
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.rowHeight = 64;
    self.table.dataSource = self;
    self.table.allowsSelection = NO;
    [self.table registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
    if (is(@"sort")) {
        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, 56)];
        SGHarnessSortRow *sort = [[SGHarnessSortRow alloc] initWithFrame:header.bounds];
        sort.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [header addSubview:sort];
        self.table.tableHeaderView = header;
    }
    [self.view addSubview:self.table];
    if (!self.loaded && !sg_rowsNever && sg_rowsAfter > 0) {
        __weak typeof(self) weakSelf = self;
        after(sg_rowsAfter, ^{ [weakSelf giveRows]; });
    }
}

- (void)giveRows {
    if (self.loaded) return;
    self.loaded = YES;
    [self.table reloadData];
    NSLog(@"[harness] the sheet has its rows");
}

- (NSArray<NSArray<NSString *> *> *)rows {
    if (self.sleepOptions) return @[@[@"timer", @"1 minute", @"s1"], @[@"timer", @"5 minutes", @"s5"]];
    return spotifyRows();
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.loaded ? self.rows.count : 0;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    for (UIView *old in cell.contentView.subviews) [old removeFromSuperview];
    NSArray<NSString *> *row = self.rows[indexPath.row];
    SGHarnessListRow *control = [[SGHarnessListRow alloc] initWithFrame:cell.contentView.bounds];
    control.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    control.accessibilityIdentifier = row[2];
    control.title = row[1];
    [control addTarget:self action:@selector(rowTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIImageView *glyph = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:row[0]]];
    glyph.frame = CGRectMake(16, 20, 24, 24);
    glyph.tintColor = UIColor.whiteColor;
    [control addSubview:glyph];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(56, 0, 280, 64)];
    title.text = row[1];
    // Lyrics grayed out, as for a track no source has them for.
    title.textColor = [row[1] isEqualToString:@"Lyrics"] ? [UIColor colorWithWhite:1 alpha:0.3] : UIColor.whiteColor;
    [control addSubview:title];
    [cell.contentView addSubview:control];
    cell.backgroundColor = UIColor.clearColor;
    return cell;
}

// Share opens a page of its own inside the sheet; Sleep timer opens its options, inside the sheet 0.3 s later
// (`sleep`) or as a context menu sheet of its own presented from the player (`sleeppresent`); every other row
// does its thing and closes the sheet.
- (void)rowTapped:(SGHarnessListRow *)row {
    sg_selected = row.title;
    NSLog(@"[harness] selected %@", row.title);
    UINavigationController *navigation = self.navigationController;
    if ([row.title isEqualToString:@"Share"] || ([row.title isEqualToString:@"Sleep timer"] && !is(@"sleeppresent"))) {
        after([row.title isEqualToString:@"Share"] ? 0 : 0.3, ^{
            UIViewController *page = [UIViewController new];
            page.title = [row.title stringByAppendingString:@" page"];
            page.view.backgroundColor = UIColor.darkGrayColor;
            [navigation pushViewController:page animated:YES];
        });
        return;
    }
    if ([row.title isEqualToString:@"Sleep timer"]) {
        // As on the phone: the card stays while Spotify presents the timer's own sheet from the player.
        after(0.3, ^{ [sg_player presentSleepOptions]; });
        return;
    }
    [navigation.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

@end

// A controller of Spotify's own presented in place of the sheet's navigation controller, which it puts the sheet
// into only as it appears (`wrapped`), as NavigationUI_SheetImpl.ContainerViewController does on the phone.
@interface SGHarnessWrapper : UIViewController
@property (nonatomic, strong) UINavigationController *inner;
@end
@implementation SGHarnessWrapper
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (self.inner.parentViewController) return;
    [self addChildViewController:self.inner];
    self.inner.view.frame = self.view.bounds;
    self.inner.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.inner.view];
    [self.inner didMoveToParentViewController:self];
}
@end

#pragma mark - the player

static UIView *menuView(UIView *root) {
    if ([NSStringFromClass(root.class) isEqualToString:@"_UIContextMenuView"]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = menuView(child);
        if (found) return found;
    }
    return nil;
}

static UIView *openMenu(void) {
    for (UIWindowScene *scene in UIApplication.sharedApplication.connectedScenes) {
        for (UIWindow *window in scene.windows) {
            UIView *found = menuView(window);
            if (found) return found;
        }
    }
    return nil;
}

// Whether a label in the open menu reads exactly `title`.
static BOOL menuShows(NSString *title) {
    __block BOOL found = NO;
    UIView *menu = openMenu();
    void (^walk)(UIView *);
    __block __weak void (^weakWalk)(UIView *);
    weakWalk = walk = ^(UIView *view) {
        if ([view isKindOfClass:UILabel.class] && !view.hidden && view.window && [((UILabel *)view).text isEqualToString:title]) found = YES;
        for (UIView *child in view.subviews) weakWalk(child);
    };
    if (menu) walk(menu);
    return found;
}

static BOOL menuShowsAll(NSArray<NSString *> *titles) {
    for (NSString *title in titles) if (!menuShows(title)) return NO;
    return YES;
}

static BOOL menuShowsAny(NSArray<NSString *> *titles) {
    for (NSString *title in titles) if (menuShows(title)) return YES;
    return NO;
}

static void pick(NSString *title) {
    UIView *menu = openMenu();
    UIMenuElement *element = sg_elements[title];
    NSLog(@"[harness] picking %@ (%@)", title, element ? @"made" : @"never made");
    if (menu && element) ((void (*)(id, SEL, id))objc_msgSend)(menu, NSSelectorFromString(@"_handleSelectionForElement:"), element);
}

@implementation SGHarnessPlayer

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.25 green:0.1 blue:0.2 alpha:1];
    // Spotify's header row (trees/clean/player/01.txt: HeaderElementsUnit's view is a 402x48 row holding the
    // down arrow, 48x48 at x 12, and the ⋯, 48x48 at the trailing edge), each button with the redesign's 44pt
    // glass circle first among its subviews, taking no touches (PlayerHeader.x, SGRGlassInside).
    self.header = [[UIView alloc] initWithFrame:CGRectMake(0, 70, 402, 48)];
    [self.view addSubview:self.header];
    self.arrow = [self headerButton:@"chevron.down" at:12 identifier:@"now-playing-minimize-button" label:@"Minimize"];
    [self.arrow addTarget:self action:@selector(arrowTapped) forControlEvents:UIControlEventTouchUpInside];
    self.more = [self headerButton:@"ellipsis" at:342 identifier:@"Context menu" label:@"More options"];
    [self.more addTarget:self action:@selector(moreTapped) forControlEvents:UIControlEventTouchUpInside];
    SGRPlayerMenuWatch(self.more);
    // The press PlayerHeader.x's circle listens to: down, and up or drag out (not the cancel UIKit sends as the
    // menu comes up, which the mod's button turns into a touch up outside once the menu ends).
    [self.front addTarget:self action:@selector(frontDown) forControlEvents:UIControlEventTouchDown];
    [self.front addTarget:self action:@selector(frontUp) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchDragExit];
    [self.front addTarget:self action:@selector(frontCancel) forControlEvents:UIControlEventTouchCancel];
}

// As PlayerHeader.x does on every layout of Spotify's header unit.
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    SGRPlayerMenuWatch(self.more);
}

- (UIButton *)headerButton:(NSString *)symbol at:(CGFloat)x identifier:(NSString *)identifier label:(NSString *)label {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.frame = CGRectMake(x, 0, 48, 48);
    button.accessibilityIdentifier = identifier;
    button.accessibilityLabel = label;
    UIVisualEffectView *circle = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterialDark]];
    circle.frame = CGRectMake(2, 2, 44, 44);
    circle.layer.cornerRadius = 22;
    circle.clipsToBounds = YES;
    circle.userInteractionEnabled = NO;
    [button insertSubview:circle atIndex:0];
    [self.header addSubview:button];
    return button;
}

- (void)arrowTapped {
    self.arrowTaps++;
    NSLog(@"[harness] Spotify's down arrow action ran");
}

- (void)frontDown {
    self.frontDowns++;
}

- (void)frontUp {
    self.frontUps++;
}

- (void)frontCancel {
    self.frontCancels++;
}

// A finger on `button`'s middle.
- (void)touch:(UIView *)button {
    CGPoint middle = [button convertPoint:CGPointMake(CGRectGetMidX(button.bounds), CGRectGetMidY(button.bounds)) toView:nil];
    NSLog(@"[harness] a finger taps %@ at %@ (hit view %@)", button.accessibilityIdentifier, NSStringFromCGPoint(middle),
          NSStringFromClass([button.window hitTest:middle withEvent:nil].class));
    SGHarnessTap(button.window, middle);
}

// What Spotify's ⋯ does: build its sheet and present it, animated.
- (void)moreTapped {
    sg_spotifyTaps++;
    NSLog(@"[harness] Spotify's ⋯ action ran");
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:[_TtC24ContextMenu_InternalImpl25ContextMenuViewController new]];
    self.sheet = navigation;
    if (is(@"wrapped")) {
        SGHarnessWrapper *wrapper = [SGHarnessWrapper new];
        wrapper.inner = navigation;
        [self presentViewController:wrapper animated:YES completion:nil];
        return;
    }
    [self presentViewController:navigation animated:YES completion:nil];
}

- (void)presentSleepOptions {
    _TtC24ContextMenu_InternalImpl25ContextMenuViewController *options = [_TtC24ContextMenu_InternalImpl25ContextMenuViewController new];
    options.sleepOptions = YES;
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:options];
    self.sleepSheet = navigation;
    NSLog(@"[harness] Spotify presents the sleep timer's own sheet");
    [self presentViewController:navigation animated:YES completion:nil];
}

- (UIButton *)front {
    for (UIView *view in self.more.subviews) if ([NSStringFromClass(view.class) isEqualToString:@"SGRMenuFront"]) return (UIButton *)view;
    return nil;
}

// A finger's tap on the ⋯, which the mod's button over it takes and opens its menu on, as UIKit opens any
// button's menu. The time from the touch down to the menu on screen, looked at every 10 ms.
- (void)tap:(void (^)(CFTimeInterval took))up {
    CFTimeInterval tapped = CACurrentMediaTime();
    [self touch:self.more];
    waitFor(^BOOL { return openMenu() != nil; }, 3, ^{
        CFTimeInterval took = CACurrentMediaTime() - tapped;
        NSLog(@"[harness] the menu view is on screen %.0f ms after the touch down", took * 1000);
        if (up) up(openMenu() ? took : -1);
    });
}

- (UIWindow *)sheetWindow {
    return self.sheet.viewIfLoaded.window;
}

- (CGFloat)sheetAlpha {
    UIViewController *outer = self.sheet;
    while (outer.parentViewController) outer = outer.parentViewController;
    UIView *container = outer.presentationController.containerView;
    return container ? container.alpha : -1;
}

// Seen: in the app's window, or in the mod's window raised over it, its container opaque.
- (BOOL)sheetShown {
    UIWindow *window = self.sheetWindow;
    return window && self.sheetAlpha == 1 && (window == self.view.window || window.windowLevel > self.view.window.windowLevel);
}

- (BOOL)sheetGone {
    return !self.sheet.viewIfLoaded.window;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    static BOOL started;
    if (started) return;
    started = YES;
    after(1, ^{ [self run:scenario()]; });
}

static NSArray<NSString *> *quickTitles(void) {
    return @[@"Share", @"Add to Playlist", @"Add to Queue"];
}

- (_TtC24ContextMenu_InternalImpl25ContextMenuViewController *)mockSheet {
    return (id)self.sheet.viewControllers.firstObject;
}

- (void)run:(NSString *)run {
    void (^finish)(void) = ^{
        NSLog(@"[harness] done");
        exit(0);
    };
    sg_rowsHeld = is(@"loading") || is(@"quick") || is(@"quicklate") || is(@"podcast") || is(@"stored");
    sg_rowsNever = is(@"quicklate");
    sg_rowsAfter = is(@"quick") ? 1.2 : is(@"loading") || is(@"podcast") ? 1.5 : 0;

    if ([run isEqualToString:@"arrow"]) {
        // The header's other button keeps its own touches: a finger on the down arrow runs Spotify's action and
        // opens no menu; one on the ⋯ then reaches the mod's button, whose touch down opens the menu.
        UIView *front = self.front;
        CGRect over = [front convertRect:front.bounds toView:nil], under = [self.more convertRect:self.more.bounds toView:nil];
        check(CGRectEqualToRect(over, under), [NSString stringWithFormat:@"the mod's ⋯ sits over Spotify's exactly (%@ over %@)", NSStringFromCGRect(over), NSStringFromCGRect(under)]);
        check(self.more.subviews.lastObject == front && self.more.subviews.firstObject != front, @"it is over the ⋯'s glass circle and glyph");
        check(!front.isAccessibilityElement || front.accessibilityLabel.length > 0, @"VoiceOver reaches it with the ⋯'s own label");
        check([self.arrow.window hitTest:CGPointMake(CGRectGetMidX([self.arrow convertRect:self.arrow.bounds toView:nil]), 94) withEvent:nil] != front, @"a touch on the arrow does not reach the mod's ⋯");
        [self touch:self.arrow];
        after(0.5, ^{
            check(self.arrowTaps == 1, [NSString stringWithFormat:@"Spotify's down arrow action ran (%lu)", (unsigned long)self.arrowTaps]);
            check(self.frontDowns == 0 && !openMenu() && sg_spotifyTaps == 0, @"the mod's ⋯ saw no touch, no menu came, Spotify's ⋯ action did not run");
            [self tap:^(CFTimeInterval took) {
                check(took >= 0, @"a finger on the ⋯ opens the menu");
                check(self.frontDowns == 1, [NSString stringWithFormat:@"the mod's ⋯ sent its touch down (%lu)", (unsigned long)self.frontDowns]);
                check(self.arrowTaps == 1, @"the arrow's action did not run again");
                // The finger lifted 0.08 s after the touch down; the press holds while the menu is up.
                after(0.5, ^{
                    check(self.frontUps == 0, [NSString stringWithFormat:@"with the menu up the press holds: no touch up yet (canceled %lu)", (unsigned long)self.frontCancels]);
                    [self.front.contextMenuInteraction dismissMenu];
                    waitFor(^BOOL { return self.frontUps > 0; }, 2, ^{
                        check(self.frontUps == 1, [NSString stringWithFormat:@"the menu's end lets the press go (%lu)", (unsigned long)self.frontUps]);
                        finish();
                    });
                });
            }];
        });
        return;
    }

    if ([run isEqualToString:@"timing"]) {
        // Ten taps, each closed again, and each time to the menu on screen.
        __block int round = 0;
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        // Kept by itself until the last round lets it go.
        __block void (^next)(void);
        next = ^{
            if (round++ == 10) {
                // The first tap of a launch pays for UIKit's menu classes loading; the other nine are the measure.
                NSArray *sorted = [[times subarrayWithRange:NSMakeRange(1, times.count - 1)] sortedArrayUsingSelector:@selector(compare:)];
                NSLog(@"[harness] tap to menu on screen over %lu taps: median %.0f ms, best %.0f ms, worst %.0f ms", (unsigned long)sorted.count,
                      [sorted[sorted.count / 2] doubleValue] * 1000, [sorted.firstObject doubleValue] * 1000, [sorted.lastObject doubleValue] * 1000);
                check([sorted[sorted.count / 2] doubleValue] < 0.25, @"the median tap brings the menu up within 250 ms");
                next = nil;
                finish();
                return;
            }
            [self tap:^(CFTimeInterval took) {
                [times addObject:@(took)];
                after(0.5, ^{
                    [self.front.contextMenuInteraction dismissMenu];
                    after(1.5, ^{ next(); });
                });
            }];
        };
        next();
        return;
    }

    [self tap:^(CFTimeInterval took) {
        // The simulator's first menu of a launch is slow (UIKit loading its menu classes); `timing` measures the rest.
        check(took >= 0 && took < 1, [NSString stringWithFormat:@"the menu is on screen %.0f ms after the tap", took * 1000]);
        check(self.front.userInteractionEnabled, @"the mod's ⋯ takes touches");
        check(menuShowsAll(@[@"Speed, Pitch & Reverb", @"Show Animated Artwork", @"More"]), @"the player's own items and More are in it");
        check(menuShowsAll(quickTitles()), @"the quick row has Share, Add to Playlist and Add to Queue");
        check(!menuShowsAny(@[@"Go to album", @"Lyrics", @"Sleep timer"]), @"Spotify's other rows are not at the top level");
        // Spotify's sheet is asked for once the menu is up, into the mod's window, under the app's.
        waitFor(^BOOL { return self.sheetWindow != nil; }, 2, ^{
            check(sg_spotifyTaps == 1, [NSString stringWithFormat:@"Spotify's ⋯ action ran once, from code (%lu)", (unsigned long)sg_spotifyTaps]);
            check(sg_marked == 1, @"Speed and pitch was told the sheet is the player's");
            check(self.sheetWindow && self.sheetWindow != self.view.window && self.sheetWindow.windowLevel < self.view.window.windowLevel,
                  @"Spotify's sheet is in the mod's window, under the app's");
            check(!self.sheetShown, @"Spotify's sheet is not seen");
            check(openMenu() != nil, @"the menu is still up");
            [self run:run finish:finish];
        });
    }];
}

// Waits for the sheet and the menu to go, then reports.
- (void)gone:(NSString *)what selected:(NSString *)selected from:(CFTimeInterval)from finish:(dispatch_block_t)finish {
    waitFor(^BOOL { return self.sheetGone && !openMenu(); }, 6, ^{
        check(self.sheetGone, [NSString stringWithFormat:@"%@: Spotify's sheet went, %.2f s later", what, CACurrentMediaTime() - from]);
        if (selected) check([sg_selected isEqualToString:selected], [NSString stringWithFormat:@"Spotify's %@ was selected (%@)", selected, sg_selected]);
        check(self.front.userInteractionEnabled, @"the mod's ⋯ still takes touches");
        finish();
    });
}

- (void)run:(NSString *)run finish:(dispatch_block_t)finish {
    if ([run isEqualToString:@"rows"] || [run isEqualToString:@"sort"] || [run isEqualToString:@"wrapped"]) {
        after(0.3, ^{
            pick(@"More");
            waitFor(^BOOL { return menuShows(@"Go to album"); }, 3, ^{
                check(menuShowsAll(@[@"Go to album", @"Lyrics", @"Sleep timer"]), @"More holds the rest of Spotify's rows, Sleep timer below the sheet's fold too");
                check(!menuShowsAny(@[@"Add to playlist", @"Add to queue"]), @"More leaves out the rows the quick row has");
                if ([run isEqualToString:@"sort"]) check(menuShows(@"Sort"), @"the mod's row in the sheet's header is in More");
                after(0.3, ^{
                    NSString *title = [run isEqualToString:@"sort"] ? @"Sort" : @"Go to album";
                    pick(title);
                    [self gone:[@"picked " stringByAppendingString:title] selected:title from:CACurrentMediaTime() finish:finish];
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"loading"]) {
        // The first menu ever: More shows the system's loading row until the rows come, 1.5 s after the sheet.
        pick(@"More");
        after(0.3, ^{
            check(openMenu() && !menuShows(@"Go to album"), @"More has no rows before the sheet has them");
            waitFor(^BOOL { return menuShows(@"Go to album"); }, 4, ^{
                check(menuShows(@"Go to album"), @"Spotify's rows came into the open More");
                after(0.3, ^{
                    pick(@"Go to album");
                    [self gone:@"picked Go to album" selected:@"Go to album" from:CACurrentMediaTime() finish:finish];
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"stored"]) {
        // A second menu, its sheet's rows held back: More shows the first one's rows at once, and a pick on them
        // waits for the live ones.
        pick(@"More");
        after(0.6, ^{
            check(!menuShows(@"Go to album"), @"the first menu has no stored rows: More waits for the live ones");
            [self.mockSheet giveRows];
            waitFor(^BOOL { return menuShows(@"Go to album"); }, 3, ^{
                [self.front.contextMenuInteraction dismissMenu];
                waitFor(^BOOL { return self.sheetGone && !openMenu(); }, 3, ^{
                    check(self.sheetGone, @"the first menu closed with no pick took its sheet with it");
                    after(1, ^{
                        [self tap:^(CFTimeInterval took) {
                            check(took >= 0 && took < 0.5, [NSString stringWithFormat:@"the second menu is on screen %.0f ms after the tap", took * 1000]);
                            pick(@"More");
                            after(0.15, ^{
                                check(menuShowsAll(@[@"Go to album", @"Sleep timer"]), @"More shows the stored rows at once, the live ones not in yet");
                                check(!self.mockSheet.loaded, @"(the live rows are not in)");
                                pick(@"Go to album");
                                after(0.8, ^{
                                    check(!self.sheetGone && ![sg_selected isEqualToString:@"Go to album"], @"the pick waits for the live rows");
                                    [self.mockSheet giveRows];
                                    [self gone:@"picked Go to album from the stored rows" selected:@"Go to album" from:CACurrentMediaTime() finish:finish];
                                });
                            });
                        }];
                    });
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"quick"] || [run isEqualToString:@"quicklate"]) {
        BOOL late = [run isEqualToString:@"quicklate"];
        pick(late ? @"Add to Playlist" : @"Add to Queue");
        CFTimeInterval picked = CACurrentMediaTime();
        after(0.5, ^{ check(!self.sheetShown && !self.sheetGone, @"the sheet stays hidden while the pick waits for its row"); });
        if (!late) {
            [self gone:@"Add to Queue picked before the rows (they came 1.2 s after the sheet)" selected:@"Add to queue" from:picked finish:finish];
            return;
        }
        waitFor(^BOOL { return self.sheetShown; }, 6, ^{
            check(self.sheetShown, [NSString stringWithFormat:@"with no rows in 4 s Spotify's sheet is shown (%.1f s after the pick)", CACurrentMediaTime() - picked]);
            check(!sg_selected, @"nothing was selected");
            finish();
        });
        return;
    }
    if ([run isEqualToString:@"podcast"]) {
        waitFor(^BOOL { return !menuShows(@"Add to Playlist"); }, 4, ^{
            check(!menuShows(@"Add to Playlist"), @"once the rows are in, the quick item this sheet has no row for is gone");
            check(menuShowsAll(@[@"Share", @"Add to Queue", @"More"]), @"the other quick items and More are still there");
            pick(@"More");
            waitFor(^BOOL { return menuShows(@"Go to show"); }, 3, ^{
                check(menuShows(@"Go to show"), @"More holds the podcast's other rows");
                after(0.3, ^{
                    pick(@"Go to show");
                    [self gone:@"picked Go to show" selected:@"Go to show" from:CACurrentMediaTime() finish:finish];
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"close"]) {
        after(0.3, ^{
            [self.front.contextMenuInteraction dismissMenu];
            CFTimeInterval closed = CACurrentMediaTime();
            // The sheet timed alone: the simulator's menu takes a second and more to fade out on its own.
            __block CFTimeInterval took = -1;
            waitFor(^BOOL { if (took < 0 && self.sheetGone) took = CACurrentMediaTime() - closed; return self.sheetGone && !openMenu(); }, 4, ^{
                check(self.sheetGone && took < 1, [NSString stringWithFormat:@"closing with no pick took the hidden sheet away, %.2f s later", took]);
                check(!sg_selected, @"nothing was selected");
                [self tap:^(CFTimeInterval took) {
                    check(took >= 0 && took < 0.5, [NSString stringWithFormat:@"a second tap opens the menu again, %.0f ms after it", took * 1000]);
                    finish();
                }];
            });
        });
        return;
    }
    if ([run isEqualToString:@"subpage"] || [run isEqualToString:@"sleep"]) {
        BOOL sleep = [run isEqualToString:@"sleep"];
        after(0.3, ^{
            if (sleep) pick(@"More");
            waitFor(^BOOL { return !sleep || menuShows(@"Sleep timer"); }, 3, ^{
                pick(sleep ? @"Sleep timer" : @"Share");
                waitFor(^BOOL { return self.sheetShown && [self.sheet.topViewController.title hasSuffix:@"page"]; }, 4, ^{
                    check([sg_selected isEqualToString:sleep ? @"Sleep timer" : @"Share"], [NSString stringWithFormat:@"Spotify's row was tapped (%@)", sg_selected]);
                    check(self.sheetShown, @"the sheet is shown, over the player");
                    check([self.sheet.topViewController.title hasSuffix:@"page"], [NSString stringWithFormat:@"on the page the row pushed (%@)", self.sheet.topViewController.title]);
                    waitFor(^BOOL { return !openMenu(); }, 3, ^{
                        check(!openMenu(), @"the menu is gone");
                        // Closed, the mod's window goes back under the app's.
                        [self.sheet.presentingViewController dismissViewControllerAnimated:NO completion:nil];
                        after(0.6, ^{
                            check(self.view.window.windowLevel > [self.front.window windowLevel] - 1 && !self.sheetWindow, @"the sheet closed, nothing of the mod's stays over the player");
                            UIWindow *host = nil;
                            for (UIWindow *window in self.view.window.windowScene.windows) if ([NSStringFromClass(window.class) isEqualToString:@"SGRSheetWindow"]) host = window;
                            check(host.windowLevel < self.view.window.windowLevel, [NSString stringWithFormat:@"the mod's window is back under the app's (level %.0f)", host.windowLevel]);
                            finish();
                        });
                    });
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"sleeppresent"]) {
        after(0.3, ^{
            pick(@"More");
            waitFor(^BOOL { return menuShows(@"Sleep timer"); }, 3, ^{
                pick(@"Sleep timer");
                waitFor(^BOOL { return self.sleepSheet.viewIfLoaded.window && !self.sleepSheet.isBeingPresented; }, 4, ^{
                    UIViewController *sleepSheet = self.sleepSheet;
                    check(sleepSheet.viewIfLoaded.window == self.view.window && sleepSheet.presentingViewController == self,
                          @"Spotify's sleep timer sheet is up, from the player, in the app's window");
                    UIView *container = sleepSheet.presentationController.containerView;
                    check(container.alpha == 1 && container.userInteractionEnabled, @"and it is seen and takes touches, as Spotify's");
                    waitFor(^BOOL { return !openMenu(); }, 3, ^{
                        check(!openMenu(), @"no menu came up for it (the picked one faded out)");
                        check(sg_spotifyTaps == 1, @"Spotify's ⋯ action ran only once");
                        after(1, ^{
                            check(self.sheetGone, @"the card it came from is gone, unseen");
                            check(sleepSheet.viewIfLoaded.window != nil, @"the sleep timer sheet is still up");
                            finish();
                        });
                    });
                });
            });
        });
        return;
    }
    if ([run isEqualToString:@"animated"]) {
        pick(@"Show Animated Artwork");
        check(sg_animated, @"Show Animated Artwork switched it on");
        [self gone:@"picked Show Animated Artwork" selected:nil from:CACurrentMediaTime() finish:finish];
        return;
    }
    check(NO, [NSString stringWithFormat:@"no scenario %@", run]);
    finish();
}

@end

@interface SGHarnessApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation SGHarnessApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    sg_player = [SGHarnessPlayer new];
    self.window.rootViewController = sg_player;
    [self.window makeKeyAndVisible];
    return YES;
}
@end

// Before every %ctor, so the redesign's gate reads on; and no rows stored from an earlier run.
__attribute__((constructor(101))) static void sgr_harnessDefaults(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setBool:YES forKey:@"spotifyglass.redesign"];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"spotifyglass.redesign.player.menuRows"]) [defaults removeObjectForKey:key];
    }
    sg_elements = [NSMutableDictionary dictionary];
    Method make = class_getClassMethod(UIAction.class, @selector(actionWithTitle:image:identifier:handler:));
    sg_actionWithTitle = method_setImplementation(make, (IMP)recordAction);
    Method menu = class_getClassMethod(UIMenu.class, @selector(menuWithTitle:image:identifier:options:children:));
    sg_menuWithTitle = method_setImplementation(menu, (IMP)recordMenu);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessApp.class));
    }
}
