#import "MRGAddons.h"
#import "MRGPrefs.h"
#import "MRGSafe.h"
#import "MRGDJLog.h"

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
static NSString *const kIndexURL = @"https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/index.json";

// The same as addons/index.json in the repo, for a first launch offline or a GitHub that doesn't answer.
static NSString *const kBundledIndex = @"{\"format\":1,\"addons\":[{\"id\":\"vinyl\",\"name\":\"Vinyl\",\"description\":\"Turns the Now Playing cover into a record sleeve: the album art moves to one side and a vinyl record peeks out from behind it, spinning while the song plays and stopping when you pause. The record's label is the album art. Choose the spin speed and which side the record sits on.\",\"preview\":\"https://raw.githubusercontent.com/x4nzz/Mirage/main/addons/previews/vinyl.png\",\"version\":\"1.0\",\"type\":\"Now Playing\",\"author\":\"Mirage\",\"min_mirage\":\"0.5.0\"}]}";

BOOL MRGAddonBuiltIn(NSString *addonID) { return [@[@"vinyl"] containsObject:addonID ?: @""]; }
BOOL MRGAddonInstalled(NSString *addonID) { return addonID.length && MRGAddonBuiltIn(addonID) && [D() boolForKey:[@"mirage.addon." stringByAppendingString:addonID]]; }
void MRGAddonSetInstalled(NSString *addonID, BOOL on) {
    if (!addonID.length) return;
    [D() setBool:on forKey:[@"mirage.addon." stringByAppendingString:addonID]];
    MRGDJLog(@"addons: %@ %@", addonID, on ? @"installed" : @"removed");
    MRGPostChange();
}
NSUInteger MRGAddonsInstalledCount(void) {
    NSUInteger n = 0;
    for (NSDictionary *a in MRGAddonIndex()) if (MRGAddonInstalled(a[@"id"])) n++;
    return n;
}

double MRGVinylSecondsPerTurn(void) { id v = [D() objectForKey:@"mirage.addon.vinyl.turn"]; double s = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.8; return MIN(8, MAX(0.8, s)); }
void MRGVinylSetSecondsPerTurn(double s) { [D() setDouble:s forKey:@"mirage.addon.vinyl.turn"]; MRGPostChange(); }
BOOL MRGVinylOnLeft(void) { return [D() boolForKey:@"mirage.addon.vinyl.left"]; }
void MRGVinylSetOnLeft(BOOL left) { [D() setBool:left forKey:@"mirage.addon.vinyl.left"]; MRGPostChange(); }

static NSArray<NSDictionary *> *parseIndex(NSData *data) {
    id j = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSArray *list = [j isKindOfClass:NSDictionary.class] && [j[@"addons"] isKindOfClass:NSArray.class] ? j[@"addons"] : nil;
    NSMutableArray *out = [NSMutableArray array];
    for (id a in list) {
        if (![a isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *m = [NSMutableDictionary dictionary];
        for (NSString *k in @[@"id", @"name", @"description", @"preview", @"version", @"type", @"author", @"min_mirage"])
            if ([a[k] isKindOfClass:NSString.class]) m[k] = a[k];
        if ([m[@"id"] length] && [m[@"name"] length]) [out addObject:m];
    }
    return out.count ? out : nil;
}

NSArray<NSDictionary *> *MRGAddonIndex(void) {
    NSData *cached = [D() dataForKey:@"mirage.addons.index"];
    return parseIndex(cached) ?: parseIndex([kBundledIndex dataUsingEncoding:NSUTF8StringEncoding]) ?: @[];
}

void MRGAddonRefresh(void (^done)(NSArray<NSDictionary *> *, NSString *)) {
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kIndexURL]];
    r.timeoutInterval = 12;
    r.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger st = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        NSArray *list = st == 200 ? parseIndex(data) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (list) [D() setObject:data forKey:@"mirage.addons.index"];
            NSString *err = list ? nil : [NSString stringWithFormat:@"Couldn't load the shop from GitHub (%@); showing the built-in list.", error.localizedDescription ?: [NSString stringWithFormat:@"HTTP %ld", (long)st]];
            if (err) MRGDJLog(@"addons: %@", err);
            done(MRGAddonIndex(), err);
        });
    }] resume];
}

// "0.5.0" ≥ "0.4.10" by numbers.
static BOOL versionAtLeast(NSString *have, NSString *need) {
    if (!need.length) return YES;
    return [have compare:need options:NSNumericSearch] != NSOrderedAscending;
}

#pragma mark - preview images (downloaded once, kept in Caches)

static NSCache *sImages;
static NSURL *imageFile(NSDictionary *a) {
    NSURL *dir = [[NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"MirageAddons"];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *name = [NSString stringWithFormat:@"%@-%@.img", a[@"id"], a[@"version"] ?: @"0"];
    return [dir URLByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"]];
}
static void loadPreview(NSDictionary *a, void (^done)(UIImage *)) {
    if (!sImages) sImages = [NSCache new];
    NSString *key = [NSString stringWithFormat:@"%@-%@", a[@"id"], a[@"version"]];
    UIImage *hit = [sImages objectForKey:key];
    if (hit) { done(hit); return; }
    NSURL *file = imageFile(a);
    UIImage *disk = [UIImage imageWithContentsOfFile:file.path];
    if (disk) { [sImages setObject:disk forKey:key]; done(disk); return; }
    NSURL *url = [a[@"preview"] hasPrefix:@"https://"] ? [NSURL URLWithString:a[@"preview"]] : nil;
    if (!url) { done(nil); return; }
    [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        UIImage *img = data.length ? [UIImage imageWithData:data] : nil;
        if (img) [data writeToURL:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{ if (img) [sImages setObject:img forKey:key]; done(img); });
    }] resume];
}

// Drawn when there's no preview yet: a record and a sleeve, so the card never looks empty.
static UIImage *placeholderArt(CGSize size) {
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef c = ctx.CGContext;
        [[UIColor colorWithWhite:0.09 alpha:1] setFill];
        CGContextFillRect(c, (CGRect){CGPointZero, size});
        CGFloat side = size.height * 0.62, cx = size.width * 0.42, cy = size.height / 2;
        CGRect disc = CGRectMake(cx + side * 0.05, cy - side * 0.48, side * 0.96, side * 0.96);
        [[UIColor colorWithWhite:0.03 alpha:1] setFill];
        CGContextFillEllipseInRect(c, disc);
        [[UIColor colorWithWhite:1 alpha:0.07] setStroke];
        for (CGFloat i = 0.2; i < 0.48; i += 0.03) CGContextStrokeEllipseInRect(c, CGRectInset(disc, side * i, side * i));
        [MRGAccent() setFill];
        CGContextFillEllipseInRect(c, CGRectInset(disc, side * 0.33, side * 0.33));
        [[UIColor colorWithWhite:0.2 alpha:1] setFill];
        UIBezierPath *sleeve = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(cx - side / 2, cy - side / 2, side, side) cornerRadius:10];
        [sleeve fill];
    }];
}

#pragma mark - a card

@interface MRGAddonCard : UITableViewCell
@property (nonatomic, copy) NSDictionary *addon;
@property (nonatomic, copy) void (^onToggle)(void);
@end

@implementation MRGAddonCard {
    UIImageView *_art;
    UILabel *_name, *_meta, *_desc;
    UIButton *_button;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)rid {
    if (!(self = [super initWithStyle:style reuseIdentifier:rid])) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.92];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _art = [UIImageView new];
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.clipsToBounds = YES;
    _art.layer.cornerRadius = 14;
    _art.layer.cornerCurve = kCACornerCurveContinuous;
    _art.backgroundColor = [UIColor colorWithWhite:0.07 alpha:1];
    _name = [UILabel new];
    _name.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _name.textColor = UIColor.whiteColor;
    _meta = [UILabel new];
    _meta.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _meta.textColor = MRGAccent();
    _desc = [UILabel new];
    _desc.font = [UIFont systemFontOfSize:14];
    _desc.textColor = [UIColor colorWithWhite:0.72 alpha:1];
    _desc.numberOfLines = 0;
    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightBold];
    _button.layer.cornerRadius = 17;
    _button.contentEdgeInsets = UIEdgeInsetsMake(7, 18, 7, 18);
    [_button addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *v in @[_art, _name, _meta, _desc, _button]) { v.translatesAutoresizingMaskIntoConstraints = NO; [self.contentView addSubview:v]; }
    UILayoutGuide *g = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_art.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:14],
        [_art.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_art.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_art.heightAnchor constraintEqualToAnchor:_art.widthAnchor multiplier:9.0 / 16.0],
        [_name.topAnchor constraintEqualToAnchor:_art.bottomAnchor constant:12],
        [_name.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_name.trailingAnchor constraintLessThanOrEqualToAnchor:_button.leadingAnchor constant:-8],
        [_meta.topAnchor constraintEqualToAnchor:_name.bottomAnchor constant:2],
        [_meta.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_meta.trailingAnchor constraintLessThanOrEqualToAnchor:_button.leadingAnchor constant:-8],
        [_button.centerYAnchor constraintEqualToAnchor:_name.bottomAnchor],
        [_button.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_desc.topAnchor constraintEqualToAnchor:_meta.bottomAnchor constant:8],
        [_desc.leadingAnchor constraintEqualToAnchor:g.leadingAnchor],
        [_desc.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [_desc.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16],
    ]];
    [_button setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    return self;
}

- (void)setAddon:(NSDictionary *)a {
    _addon = [a copy];
    _name.text = a[@"name"];
    NSMutableArray *meta = [NSMutableArray array];
    if (a[@"type"]) [meta addObject:[a[@"type"] uppercaseString]];
    if (a[@"version"]) [meta addObject:[@"v" stringByAppendingString:a[@"version"]]];
    if (a[@"author"]) [meta addObject:[@"by " stringByAppendingString:a[@"author"]]];
    _meta.text = [meta componentsJoinedByString:@"  ·  "];
    _desc.text = a[@"description"];
    BOOL builtIn = MRGAddonBuiltIn(a[@"id"]) && versionAtLeast(@MRG_VERSION, a[@"min_mirage"]);
    BOOL on = MRGAddonInstalled(a[@"id"]);
    NSString *title = !builtIn ? @"Update Mirage" : on ? @"Remove" : @"Get";
    [_button setTitle:title forState:UIControlStateNormal];
    _button.enabled = builtIn;
    _button.backgroundColor = on ? [UIColor colorWithWhite:1 alpha:0.12] : builtIn ? MRGAccent() : [UIColor colorWithWhite:1 alpha:0.06];
    [_button setTitleColor:on ? UIColor.whiteColor : builtIn ? MRGOnAccent() : UIColor.grayColor forState:UIControlStateNormal];
    _art.image = placeholderArt(CGSizeMake(320, 180));
    NSString *mine = a[@"id"];
    loadPreview(a, ^(UIImage *img) { if (img && [self->_addon[@"id"] isEqualToString:mine]) self->_art.image = img; });
}

- (void)tapped { if (self.onToggle) self.onToggle(); }
@end

#pragma mark - settings of an addon (Vinyl)

@interface MRGVinylSettings : UITableViewController
@end

@implementation MRGVinylSettings
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Vinyl";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return 1; }
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s { return s == 0 ? @"Spin speed" : @"Record side"; }
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return s == 1 ? @"The record spins while a song plays and stops when you pause. If Spotify changes its player and the cover can't be found, Now Playing simply stays as it is." : nil;
}
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.9];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        NSArray *items = ip.section == 0 ? @[@"Chill", @"33⅓", @"45"] : @[@"Left", @"Right"];
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:items];
        seg.selectedSegmentTintColor = MRGAccent();
        [seg setTitleTextAttributes:@{NSForegroundColorAttributeName: MRGOnAccent()} forState:UIControlStateSelected];
        if (ip.section == 0) {
            double s = MRGVinylSecondsPerTurn();
            seg.selectedSegmentIndex = s > 2.5 ? 0 : s > 1.5 ? 1 : 2;
            [seg addTarget:self action:@selector(speed:) forControlEvents:UIControlEventValueChanged];
        } else {
            seg.selectedSegmentIndex = MRGVinylOnLeft() ? 0 : 1;
            [seg addTarget:self action:@selector(side:) forControlEvents:UIControlEventValueChanged];
        }
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:10],
            [seg.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-10],
        ]];
        return c;
    });
}
- (void)speed:(UISegmentedControl *)s { MRGVinylSetSecondsPerTurn([@[@4.0, @1.8, @1.33][s.selectedSegmentIndex] doubleValue]); }
- (void)side:(UISegmentedControl *)s { MRGVinylSetOnLeft(s.selectedSegmentIndex == 0); }
@end

#pragma mark - the shop

@interface MRGAddonShop : UITableViewController
@end

@implementation MRGAddonShop {
    NSArray<NSDictionary *> *_addons;
    NSString *_note;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Addon Shop";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.estimatedRowHeight = 360;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    UIEdgeInsets inset = self.tableView.contentInset; inset.bottom = 150; self.tableView.contentInset = inset;
    self.tableView.tableHeaderView = [self header];
    self.refreshControl = [UIRefreshControl new];
    self.refreshControl.tintColor = MRGAccent();
    [self.refreshControl addTarget:self action:@selector(reload) forControlEvents:UIControlEventValueChanged];
    _addons = MRGAddonIndex();
    [self reload];
}

- (UIView *)header {
    UIView *h = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 96)];
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 14, 280, 34)];
    title.text = @"Make Spotify yours";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightHeavy];
    title.textColor = UIColor.whiteColor;
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 50, 280, 40)];
    sub.text = @"Addons are built into Mirage and switched on here. Nothing gets downloaded and run.";
    sub.numberOfLines = 2;
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = UIColor.grayColor;
    sub.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [h addSubview:title];
    [h addSubview:sub];
    return h;
}

- (void)reload {
    MRGAddonRefresh(^(NSArray<NSDictionary *> *addons, NSString *error) {
        self->_addons = addons;
        self->_note = error;
        [self.refreshControl endRefreshing];
        [self.tableView reloadData];
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return MAX((NSInteger)_addons.count, 1); }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return MRGSafeCount(^NSInteger {
        if (!self->_addons.count) return 0;
        NSDictionary *a = self->_addons[s];
        return 1 + ([a[@"id"] isEqualToString:@"vinyl"] && MRGAddonInstalled(a[@"id"]) ? 1 : 0);
    });
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    return s == (NSInteger)_addons.count - 1 || !_addons.count ? (_note ?: @"Pull down to check for new addons.") : nil;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    return MRGSafeCell(ip, ^UITableViewCell *{
        NSDictionary *a = self->_addons[ip.section];
        if (ip.row == 1) {
            UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.92];
            c.textLabel.text = @"Settings";
            c.textLabel.textColor = UIColor.whiteColor;
            c.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            c.imageView.tintColor = MRGAccent();
            c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %@", MRGVinylSecondsPerTurn() > 2.5 ? @"Chill" : MRGVinylSecondsPerTurn() > 1.5 ? @"33⅓" : @"45", MRGVinylOnLeft() ? @"left" : @"right"];
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        MRGAddonCard *card = [[MRGAddonCard alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        card.addon = a;
        __weak typeof(self) weak = self;
        card.onToggle = ^{
            BOOL on = !MRGAddonInstalled(a[@"id"]);
            MRGAddonSetInstalled(a[@"id"], on);
            [weak.tableView reloadSections:[NSIndexSet indexSetWithIndex:ip.section] withRowAnimation:UITableViewRowAnimationAutomatic];
        };
        return card;
    });
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.row == 1) MRGPushPage(self, [MRGVinylSettings new]);
}

- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
@end

UIViewController *MRGAddonShopPage(void) { return [MRGAddonShop new]; }
