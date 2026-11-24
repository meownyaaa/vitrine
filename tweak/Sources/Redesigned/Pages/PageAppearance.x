// Redesign: the blur Spotify draws behind the bar of its navigation stacks is kept off where a page asks
// (SGRSyncBarBlur). A dressed page took it off only from its own first layout pass, which a page whose bar had not
// been built yet missed, so a tinted header showed for a moment on Recents, Listening stats, Your Premium and the rest, and came back when the app was left and entered again.
// It is now settled as a page is pushed or popped, on every pass of the stack and as the app comes to the front.
// Threading: main thread only.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Pages.h"

static NSHashTable<UINavigationController *> *sg_stacks;

static void keepStack(UINavigationController *navigation) {
    if (!sg_stacks) sg_stacks = [NSHashTable weakObjectsHashTable];
    [sg_stacks addObject:navigation];
    SGRSyncBarBlur(navigation);
}

static void syncAllStacks(void) {
    for (UINavigationController *navigation in sg_stacks.allObjects) SGRSyncBarBlur(navigation);
}

%hook SPNavigationController
- (void)viewDidLoad {
    %orig;
    keepStack((UINavigationController *)self);
}

- (void)viewWillAppear:(BOOL)animated {
    %orig;
    keepStack((UINavigationController *)self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    keepStack((UINavigationController *)self);
}

// The top page changes inside these, before anything is drawn.
- (void)pushViewController:(UIViewController *)controller animated:(BOOL)animated {
    %orig;
    SGRSyncBarBlur((UINavigationController *)self);
}

- (UIViewController *)popViewControllerAnimated:(BOOL)animated {
    UIViewController *popped = %orig;
    SGRSyncBarBlur((UINavigationController *)self);
    return popped;
}

- (void)setViewControllers:(NSArray<UIViewController *> *)controllers animated:(BOOL)animated {
    %orig;
    SGRSyncBarBlur((UINavigationController *)self);
}
%end

// UIKit builds the bar's buttons and title while laying the content view out, after the bar's own pass: Spotify's
// controls are kept out of sight for a page that wants the redesign's bar from here (SGRSyncBarBlur), and the pages
// dressed from the bar are dressed (SGRObserveBarPasses).
static NSMutableArray<void (^)(UIView *)> *sg_barPasses;
static Class sg_barClass;

void SGRObserveBarPasses(void (^pass)(UIView *bar)) {
    if (!sg_barPasses) sg_barPasses = [NSMutableArray array];
    [sg_barPasses addObject:[pass copy]];
}

static void barLaidOut(UIView *bar) {
    UINavigationController *navigation = SGRNavigationOf(bar);
    if (navigation) SGRSyncBarBlur(navigation);
    if (!SGBelowiOS26()) return;
    for (void (^pass)(UIView *) in sg_barPasses) pass(bar);
}

%hook SPNavigationBar
- (void)layoutSubviews {
    %orig;
    barLaidOut((UIView *)self);
}
%end

%hook _UINavigationBarContentView
- (void)layoutSubviews {
    %orig;
    UIView *bar = ((UIView *)self).superview;
    if (sg_barClass && [bar isKindOfClass:sg_barClass]) barLaidOut(bar);
}
%end

%ctor {
    if (!SGRedesignedUI()) return;
    sg_barClass = NSClassFromString(@"SPNavigationBar");
    %init;
    SGRequireClasses(@[@"SPNavigationController", @"SPNavigationBar", @"_UINavigationBarContentView"]);
    // Spotify builds its blur again as the app comes back; it is settled at once and once more after its own pass.
    void (^comeback)(NSNotification *) = ^(NSNotification *note) {
        syncAllStacks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            syncAllStacks();
        });
    };
    for (NSNotificationName name in @[UIApplicationWillEnterForegroundNotification, UIApplicationDidBecomeActiveNotification]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:comeback];
    }
}
