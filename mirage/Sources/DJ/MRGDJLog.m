#import "MRGDJLog.h"
#import <objc/runtime.h>

static NSMutableArray<NSString *> *sLines;
static const NSUInteger kMax = 600;

static NSString *logPath(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject stringByAppendingPathComponent:@"Mirage"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"dj.log"];
}

static void load(void) {
    if (sLines) return;
    NSString *text = [NSString stringWithContentsOfFile:logPath() encoding:NSUTF8StringEncoding error:nil];
    sLines = [NSMutableArray array];
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) if (l.length) [sLines addObject:l];
    while (sLines.count > kMax) [sLines removeObjectAtIndex:0];
}

static void save(void) {
    static BOOL pending;
    if (pending) return;
    pending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        pending = NO;
        [[sLines componentsJoinedByString:@"\n"] writeToFile:logPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
}

void MRGDJLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    static NSDateFormatter *f;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss.SSS"; });
    NSString *line = [NSString stringWithFormat:@"%@ %@", [f stringFromDate:NSDate.date], [message stringByReplacingOccurrencesOfString:@"\n" withString:@" "]];
    NSLog(@"[Mirage DJ] %@", message);
    void (^append)(void) = ^{
        load();
        [sLines addObject:line];
        while (sLines.count > kMax) [sLines removeObjectAtIndex:0];
        save();
    };
    if (NSThread.isMainThread) append(); else dispatch_async(dispatch_get_main_queue(), append);
}

NSString *MRGDJLogText(void) { load(); return [sLines componentsJoinedByString:@"\n"]; }
void MRGDJLogClear(void) { load(); [sLines removeAllObjects]; save(); }

#pragma mark - accent

UIColor *MRGAccent(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    BOOL redesign = [d boolForKey:@"spotifyglass.redesign"];
    if (@available(iOS 26.0, *)) {} else redesign = redesign && [d boolForKey:@"spotifyglass.redesign.untested"];
    NSInteger rgb;
    if (redesign) {
        id v = [d objectForKey:@"spotifyglass.redesign.accent"];
        rgb = [v isKindOfClass:NSNumber.class] ? [v integerValue] : 0x37F200;
    } else {
        id v = [d objectForKey:@"spotifyglass.accent"];
        rgb = [v isKindOfClass:NSNumber.class] ? [v integerValue] : -1;
    }
    if (rgb < 0 || rgb > 0xFFFFFF) rgb = 0x1ED760;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0 green:((rgb >> 8) & 0xFF) / 255.0 blue:(rgb & 0xFF) / 255.0 alpha:1];
}

UIColor *MRGOnAccent(void) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [MRGAccent() getRed:&r green:&g blue:&b alpha:&a];
    return 0.2126 * r + 0.7152 * g + 0.0722 * b > 0.5 ? UIColor.blackColor : UIColor.whiteColor;
}

#pragma mark - the page

@interface MRGDJLogController : UIViewController
@end

@implementation MRGDJLogController {
    UITextView *_text;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DJ debug log";
    self.view.backgroundColor = UIColor.blackColor;
    _text = [UITextView new];
    _text.editable = NO;
    _text.backgroundColor = UIColor.blackColor;
    _text.textColor = [UIColor colorWithWhite:1 alpha:0.85];
    _text.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    _text.textContainerInset = UIEdgeInsetsMake(12, 10, 24, 10);
    _text.alwaysBounceVertical = YES;
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_text];
    [NSLayoutConstraint activateConstraints:@[
        [_text.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_text.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [_text.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_text.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
    self.navigationItem.rightBarButtonItems = @[
        [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStyleDone target:self action:@selector(copyLog)],
        [[UIBarButtonItem alloc] initWithTitle:@"Clear" style:UIBarButtonItemStylePlain target:self action:@selector(clearLog)],
    ];
    [self reload];
}

- (void)reload {
    NSString *t = MRGDJLogText();
    _text.text = t.length ? t : @"Nothing logged yet. Start the DJ, then come back here.";
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_text.text.length) [self->_text scrollRangeToVisible:NSMakeRange(self->_text.text.length - 1, 1)];
    });
}

- (void)copyLog {
    NSString *header = [NSString stringWithFormat:@"Mirage %@ DJ log, iOS %@\n", @MRG_VERSION, UIDevice.currentDevice.systemVersion];
    UIPasteboard.generalPasteboard.string = [header stringByAppendingString:MRGDJLogText()];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Copied" message:@"The DJ log is on the clipboard." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)clearLog { MRGDJLogClear(); [self reload]; }

@end

UIViewController *MRGDJLogPage(void) { return [MRGDJLogController new]; }

static id mrgPageID(id self, SEL _cmd) { return [@"mirage." stringByAppendingString:NSStringFromClass([self class])]; }
static id mrgPageURI(id self, SEL _cmd) { return [NSURL URLWithString:[@"spotify:internal:mirage:" stringByAppendingString:NSStringFromClass([self class]).lowercaseString]]; }

void MRGPushPage(UIViewController *owner, UIViewController *page) {
    if (!owner || !page) return;
    Protocol *proto = objc_getProtocol("_TtP19Tome_PageAttributes17SPTPageController_") ?: objc_getProtocol("SPTPageController");
    BOOL ok = NO;
    if (proto) {
        Class c = page.class;
        if (![c instancesRespondToSelector:@selector(spt_pageIdentifier)]) class_addMethod(c, @selector(spt_pageIdentifier), (IMP)mrgPageID, "@@:");
        if (![c instancesRespondToSelector:@selector(spt_pageURI)]) class_addMethod(c, @selector(spt_pageURI), (IMP)mrgPageURI, "@@:");
        ok = class_conformsToProtocol(c, proto) || class_addProtocol(c, proto);
    }
    UINavigationController *nav = owner.navigationController;
    if (nav && (ok || ![NSStringFromClass(nav.class) hasPrefix:@"SPT"])) { [nav pushViewController:page animated:YES]; return; }
    UINavigationController *wrap = [[UINavigationController alloc] initWithRootViewController:page];
    wrap.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    page.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:wrap action:@selector(mrg_close)];
    [owner presentViewController:wrap animated:YES completion:nil];
}

@implementation UINavigationController (MRGClose)
- (void)mrg_close { [self dismissViewControllerAnimated:YES completion:nil]; }
@end
