// The phone driver (Diagnostics/Driver.m) on a mock app in the simulator: Diagnostics.x's tree server starts
// as in a FLEX build (a FLEXManager class is all it looks for) and proof.py drives it through scripts/phone.py
// over the Mac's loopback, which simulator apps share, so no iproxy.
//
// The mock: a tab bar (Home, Search); on Home a button, a view with a tap recognizer, a button whose menu is
// its primary action, a scroll view and a text field; a now playing bar under Spotify's bar controller's class
// name that opens a player under NPVScrollViewController's, with the down arrow and the ⋯ by Spotify's
// identifiers and a menu on the ⋯; a player behind SGDiagnosticsPlayer; and SGOpenModSettings pushing a long
// list. Everything that reacts says so with an SGLog line, which the driver's log command reads back.
#import <UIKit/UIKit.h>
#import "Core/SGCore.h"
#import "Diagnostics/Diagnostics.h"

// Diagnostics.x's SGIsDebugBuild looks for FLEX by this class.
@interface FLEXManager : NSObject
@end
@implementation FLEXManager
@end

#pragma mark - the player

@interface HarnessTrack : NSObject
@property (nonatomic, readonly) NSString *trackTitle, *artistName;
@property (nonatomic, readonly) id URI;
@end
@implementation HarnessTrack
- (NSString *)trackTitle { return @"Harness Song"; }
- (NSString *)artistName { return @"Harness Artist"; }
- (id)URI { return @"spotify:track:harness"; }
@end

@interface HarnessState : NSObject
@property (nonatomic) BOOL paused;
@property (nonatomic) double at;
@end
@implementation HarnessState
- (HarnessTrack *)track { return [HarnessTrack new]; }
- (BOOL)isPaused { return self.paused; }
- (BOOL)isPlaying { return YES; }
- (double)position { return self.at; }
- (double)positionAsOfTimestamp { return self.at; }
- (double)duration { return 200; }
@end

@interface HarnessPlayer : NSObject
@property (nonatomic, strong) HarnessState *state;
@end
@implementation HarnessPlayer
- (instancetype)init {
    if ((self = [super init])) _state = [HarnessState new];
    return self;
}
- (void)seekTo:(double)seconds { self.state.at = seconds; SGLog(@"harness: player seekTo %.0f", seconds); }
- (id)pause:(id)options { self.state.paused = YES; SGLog(@"harness: player pause"); return nil; }
- (id)resume:(id)options { self.state.paused = NO; SGLog(@"harness: player resume"); return nil; }
- (id)skipToNextTrackWithOptions:(id)options { SGLog(@"harness: player next"); return nil; }
@end

static HarnessPlayer *sg_player;
id SGDiagnosticsPlayer(void) { return sg_player; }

// The driver's speed, lossless, automix, sing and landscape commands, each saying it ran.
static double sg_speed = 1;
double SGPlayerSpeed(void) { return sg_speed; }
void SGSetPlayerSpeed(double speed) { sg_speed = speed; SGLog(@"harness: speed %.2f", speed); }
NSDictionary *SGLosslessProbe(NSString *verb, NSDictionary *p, NSString **error) { *error = @"no lossless in the harness"; return nil; }
NSDictionary *SGAutoMixProbeCommand(NSDictionary *p, NSString **error) { *error = @"no Automix in the harness"; return nil; }
void SGSetSingOn(BOOL on) { SGLog(@"harness: sing %d", on); }
void SGRPlayerShowLandscape(BOOL show) { SGLog(@"harness: landscape %d", show); }

#pragma mark - Mod Settings

@interface HarnessSettings : UITableViewController
@end
@implementation HarnessSettings
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mod Settings";
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
}
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return 40; }
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row" forIndexPath:indexPath];
    cell.textLabel.text = [NSString stringWithFormat:@"Row %ld", (long)indexPath.row];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    SGLog(@"harness: settings row Row %ld", (long)indexPath.row);
}
@end

static UINavigationController *sg_home;
void SGOpenModSettings(UIView *source) {
    SGLog(@"harness: SGOpenModSettings from a %@", source.class);
    [sg_home pushViewController:[HarnessSettings new] animated:NO];
}

#pragma mark - the player screen and the bar, under Spotify's class names

static UIButton *menuButton(NSString *title, NSString *identifier, NSArray<NSString *> *rows, NSString *what);

@interface _TtC21NowPlaying_ScrollImpl23NPVScrollViewController : UIViewController
@end
@implementation _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.darkGrayColor;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Down" forState:UIControlStateNormal];
    close.accessibilityIdentifier = @"now-playing-minimize-button";
    close.frame = CGRectMake(12, 70, 48, 48);
    [close addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:close];
    UIButton *more = menuButton(@"⋯", @"Context menu", @[@"Share", @"Go to album", @"Sleep timer"], @"player menu");
    more.frame = CGRectMake(340, 70, 48, 48);
    [self.view addSubview:more];
}
- (void)close {
    SGLog(@"harness: player down arrow");
    [self dismissViewControllerAnimated:NO completion:nil];
}
@end

@interface _TtC18NowPlaying_BarImpl27NowPlayingBarViewController : UIViewController
@end
@implementation _TtC18NowPlaying_BarImpl27NowPlayingBarViewController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemIndigoColor;
    [self.view addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(open)]];
}
- (void)open {
    SGLog(@"harness: bar tapped");
    UIViewController *player = [_TtC21NowPlaying_ScrollImpl23NPVScrollViewController new];
    player.modalPresentationStyle = UIModalPresentationFullScreen;
    [self presentViewController:player animated:NO completion:nil];
}
@end

#pragma mark - Home

// A button whose menu is its primary action; says when the menu is about to show.
@interface HarnessMenuButton : UIButton
@property (nonatomic, copy) NSString *what;
@end
@implementation HarnessMenuButton
- (void)contextMenuInteraction:(UIContextMenuInteraction *)interaction
    willDisplayMenuForConfiguration:(UIContextMenuConfiguration *)configuration
                           animator:(id<UIContextMenuInteractionAnimating>)animator {
    SGLog(@"harness: %@ will display", self.what);
    if ([UIButton instancesRespondToSelector:_cmd]) [super contextMenuInteraction:interaction willDisplayMenuForConfiguration:configuration animator:animator];
}
@end

static UIButton *menuButton(NSString *title, NSString *identifier, NSArray<NSString *> *rows, NSString *what) {
    HarnessMenuButton *button = [HarnessMenuButton buttonWithType:UIButtonTypeSystem];
    button.what = what;
    [button setTitle:title forState:UIControlStateNormal];
    button.accessibilityIdentifier = identifier;
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    for (NSString *row in rows) {
        [actions addObject:[UIAction actionWithTitle:row image:nil identifier:nil handler:^(UIAction *action) {
            SGLog(@"harness: %@ picked %@", what, row);
        }]];
    }
    button.menu = [UIMenu menuWithChildren:actions];
    button.showsMenuAsPrimaryAction = YES;
    return button;
}

@interface HarnessHome : UIViewController
@property (nonatomic) NSInteger taps;
@end
@implementation HarnessHome
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Home";
    self.view.backgroundColor = UIColor.blackColor;

    UIButton *counter = [UIButton buttonWithType:UIButtonTypeSystem];
    counter.frame = CGRectMake(20, 120, 160, 44);
    counter.accessibilityIdentifier = @"counter";
    [counter setTitle:@"Counter" forState:UIControlStateNormal];
    [counter addTarget:self action:@selector(count:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:counter];

    UIView *tapView = [[UIView alloc] initWithFrame:CGRectMake(220, 120, 160, 44)];
    tapView.backgroundColor = UIColor.systemTealColor;
    tapView.accessibilityIdentifier = @"tapview";
    [tapView addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(recognized)]];
    [self.view addSubview:tapView];

    UIButton *menu = menuButton(@"Menu", @"menubutton", @[@"Alpha", @"Sleep timer"], @"menu");
    menu.frame = CGRectMake(20, 180, 160, 44);
    [self.view addSubview:menu];

    UIScrollView *scroller = [[UIScrollView alloc] initWithFrame:CGRectMake(20, 240, 362, 220)];
    scroller.accessibilityIdentifier = @"scroller";
    scroller.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1];
    scroller.contentSize = CGSizeMake(362, 3000);
    for (NSInteger i = 0; i < 60; i++) {
        UILabel *line = [[UILabel alloc] initWithFrame:CGRectMake(12, i * 50, 300, 44)];
        line.text = [NSString stringWithFormat:@"Line %ld", (long)i];
        line.textColor = UIColor.whiteColor;
        [scroller addSubview:line];
    }
    [self.view addSubview:scroller];

    UITextField *field = [[UITextField alloc] initWithFrame:CGRectMake(20, 480, 362, 40)];
    field.accessibilityIdentifier = @"field";
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.placeholder = @"Type here";
    [field addTarget:self action:@selector(edited:) forControlEvents:UIControlEventEditingChanged];
    [self.view addSubview:field];

    UIViewController *bar = [_TtC18NowPlaying_BarImpl27NowPlayingBarViewController new];
    [self addChildViewController:bar];
    bar.view.frame = CGRectMake(8, 640, 386, 56);
    [self.view addSubview:bar.view];
    [bar didMoveToParentViewController:self];
}
- (void)count:(UIButton *)button {
    self.taps++;
    [button setTitle:[NSString stringWithFormat:@"Tapped %ld", (long)self.taps] forState:UIControlStateNormal];
    SGLog(@"harness: button tapped %ld", (long)self.taps);
}
- (void)recognized {
    SGLog(@"harness: recognizer tap");
}
- (void)edited:(UITextField *)field {
    SGLog(@"harness: field text %@", field.text);
}
@end

@interface HarnessSearch : UIViewController
@end
@implementation HarnessSearch
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Search";
    self.view.backgroundColor = UIColor.systemGray6Color;
}
@end

// Says when a finger lifts, so the proof can tell a menu opened while it was still down.
@interface HarnessWindow : UIWindow
@end
@implementation HarnessWindow
- (void)sendEvent:(UIEvent *)event {
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseEnded) SGLog(@"harness: finger up");
    }
    [super sendEvent:event];
}
@end

@interface SGHarnessApp : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation SGHarnessApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    sg_player = [HarnessPlayer new];
    sg_home = [[UINavigationController alloc] initWithRootViewController:[HarnessHome new]];
    sg_home.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Home" image:[UIImage systemImageNamed:@"house"] tag:0];
    UIViewController *search = [HarnessSearch new];
    search.tabBarItem = [[UITabBarItem alloc] initWithTitle:@"Search" image:[UIImage systemImageNamed:@"magnifyingglass"] tag:1];
    UITabBarController *tabs = [UITabBarController new];
    tabs.viewControllers = @[sg_home, search];
    self.window = [[HarnessWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = tabs;
    return YES;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(SGHarnessApp.class));
    }
}
