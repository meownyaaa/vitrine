#import "MRGSettings.h"
#import "MRGPrefs.h"
#import "MRGImporter.h"
#import "MRGBackgroundView.h"
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/runtime.h>

// Spotify's navigation controller asserts that every controller pushed on it conforms to
// SPTPageController (Vitrine, tweak/Sources/Settings/SGPage.m); the page answers its two questions
// and is registered as conforming at launch, or presented when the protocol is missing.
static BOOL sg_pageConforms;

typedef NS_ENUM(NSInteger, MRGSection) { MRGSecPreview, MRGSecMedia, MRGSecLook, MRGSecScreens, MRGSecShop, MRGSecDJ, MRGSecAbout, MRGSecCount };

@interface MRGSettingsController : UITableViewController <PHPickerViewControllerDelegate, UIDocumentPickerDelegate>
@end

@implementation MRGSettingsController {
    UIActivityIndicatorView *_spinner;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (NSString *)spt_pageIdentifier { return @"mirage"; }
- (NSURL *)spt_pageURI { return [NSURL URLWithString:@"spotify:internal:mirage"]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mirage";
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.tableView.backgroundColor = UIColor.blackColor;
    // The page draws its own background, laid out for the whole window (not the table's frame, which
    // stops short of the tab bar), so it lines up with the screens around it; Mirage's page hooks
    // leave this table alone.
    self.tableView.accessibilityIdentifier = @"mirage.settings";
    self.tableView.backgroundView = [[MRGBackgroundView alloc] initWithFrame:self.tableView.bounds];
    self.tableView.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
    _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:_spinner];
    if (self.navigationController.viewControllers.firstObject == self && self.presentingViewController)
        self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
}

// Pushed on Spotify's stack the page runs under the tab bar and the mini player, which Spotify does not
// report as safe area to a page of ours; the last rows are kept clear of both.
static const CGFloat kBottomChrome = 150;

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    BOOL modal = self.navigationController.viewControllers.firstObject == self && self.presentingViewController;
    CGFloat bottom = modal ? 0 : MAX(0, kBottomChrome - self.view.safeAreaInsets.bottom);
    UITableView *t = self.tableView;
    if (t.contentInset.bottom != bottom) {
        UIEdgeInsets inset = t.contentInset; inset.bottom = bottom; t.contentInset = inset;
        UIEdgeInsets bar = t.verticalScrollIndicatorInsets; bar.bottom = bottom; t.verticalScrollIndicatorInsets = bar;
    }
}

- (void)close { [self dismissViewControllerAnimated:YES completion:nil]; }

#pragma mark - table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return MRGSecCount; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    switch (s) {
        case MRGSecPreview: return 2;              // enabled, preview
        case MRGSecMedia: return 3;                // photos, files, remove
        case MRGSecLook: return 5;                 // blur, dim, scale, clear pages, profile glow
        case MRGSecScreens: return 4;
        case MRGSecShop: case MRGSecDJ: return 1;
        case MRGSecAbout: return 2;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return @[@"Backgrounds", @"Media", @"Look", @"Show on", @"Addon Shop", @"AI DJ", @"About"][s];
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    switch (s) {
        case MRGSecMedia: return @"Images (PNG, JPG, HEIC), GIFs (converted to a looping MP4 when you pick them) and videos (MP4, MOV). Videos play muted, never touch Spotify's audio, and pause when Spotify is in the background.";
        case MRGSecLook: return @"Clear page backgrounds makes Spotify's own page fill transparent so the background shows through; cards and Vitrine's glass stay as they are. Profile picture glow replaces the profile page's color gradient with a soft glow of that color around your picture.";
        case MRGSecScreens: return @"Everywhere puts the background behind every page, Home and Library included.";
        case MRGSecAbout: return @"Mirage is free software under the GPL-3.0, built on Vitrine (github.com/meownyaaa/vitrine), itself a fork of Chroma by skopevoj (spoti.pw, up to v0.21.1).";
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)t heightForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == MRGSecPreview && ip.row == 1) return MRGCurrentKind() == MRGMediaNone ? 52 : 200;
    if (ip.section == MRGSecLook && ip.row < 2) return 64;
    return 48;
}

static UITableViewCell *baseCell(void) {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.backgroundColor = [UIColor colorWithWhite:0.11 alpha:0.78];
    c.textLabel.textColor = UIColor.whiteColor;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    return c;
}

- (UITableViewCell *)switchCell:(NSString *)title on:(BOOL)on tag:(NSInteger)tag symbol:(NSString *)symbol {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    if (symbol) { c.imageView.image = [UIImage systemImageNamed:symbol]; c.imageView.tintColor = UIColor.whiteColor; }
    UISwitch *sw = [UISwitch new];
    sw.on = on;
    sw.tag = tag;
    sw.onTintColor = [UIColor colorWithRed:0.12 green:0.84 blue:0.38 alpha:1];
    [sw addTarget:self action:@selector(switched:) forControlEvents:UIControlEventValueChanged];
    c.accessoryView = sw;
    return c;
}

- (UITableViewCell *)sliderCell:(NSString *)title value:(double)v max:(double)max tag:(NSInteger)tag {
    UITableViewCell *c = baseCell();
    UILabel *label = [UILabel new];
    label.text = title;
    label.textColor = UIColor.whiteColor;
    label.font = [UIFont systemFontOfSize:15];
    UISlider *slider = [UISlider new];
    slider.minimumValue = 0;
    slider.maximumValue = max;
    slider.value = v;
    slider.tag = tag;
    slider.continuous = NO;
    slider.minimumTrackTintColor = UIColor.whiteColor;
    [slider addTarget:self action:@selector(slid:) forControlEvents:UIControlEventValueChanged];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, slider]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [c.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:c.contentView.centerYAnchor],
    ]];
    return c;
}

- (UITableViewCell *)actionCell:(NSString *)title symbol:(NSString *)symbol destructive:(BOOL)destructive enabled:(BOOL)enabled {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    c.textLabel.textColor = !enabled ? UIColor.grayColor : destructive ? UIColor.systemRedColor : UIColor.whiteColor;
    c.imageView.image = [UIImage systemImageNamed:symbol];
    c.imageView.tintColor = c.textLabel.textColor;
    c.selectionStyle = enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    c.userInteractionEnabled = enabled;
    return c;
}

- (UITableViewCell *)comingSoon:(NSString *)title symbol:(NSString *)symbol {
    UITableViewCell *c = baseCell();
    c.textLabel.text = title;
    c.textLabel.textColor = UIColor.grayColor;
    c.imageView.image = [UIImage systemImageNamed:symbol];
    c.imageView.tintColor = UIColor.grayColor;
    c.detailTextLabel.text = @"Coming soon";
    c.detailTextLabel.textColor = UIColor.grayColor;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    MRGScreen screens = MRGScreens();
    BOOL hasMedia = MRGCurrentKind() != MRGMediaNone;
    switch (ip.section) {
        case MRGSecPreview:
            if (ip.row == 0) return [self switchCell:@"Custom background" on:MRGBackgroundEnabled() tag:1 symbol:@"sparkles"];
            if (!hasMedia) {
                UITableViewCell *c = baseCell();
                c.textLabel.text = @"No background picked yet";
                c.textLabel.textColor = UIColor.grayColor;
                return c;
            } else {
                UITableViewCell *c = baseCell();
                MRGBackgroundView *preview = [[MRGBackgroundView alloc] initWithFrame:c.contentView.bounds];
                preview.fitsBounds = YES;
                preview.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
                [c.contentView addSubview:preview];
                return c;
            }
        case MRGSecMedia:
            if (ip.row == 0) return [self actionCell:@"Choose from Photos" symbol:@"photo.on.rectangle" destructive:NO enabled:YES];
            if (ip.row == 1) return [self actionCell:@"Choose from Files" symbol:@"folder" destructive:NO enabled:YES];
            return [self actionCell:@"Remove background" symbol:@"trash" destructive:YES enabled:hasMedia];
        case MRGSecLook:
            if (ip.row == 0) return [self sliderCell:@"Blur" value:MRGBlur() max:1 tag:10];
            if (ip.row == 1) return [self sliderCell:@"Dim" value:MRGDim() max:0.9 tag:11];
            if (ip.row == 2) {
                UITableViewCell *c = baseCell();
                c.textLabel.text = @"Scale";
                UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Fill", @"Fit", @"Stretch"]];
                seg.selectedSegmentIndex = MRGScale();
                [seg addTarget:self action:@selector(scaled:) forControlEvents:UIControlEventValueChanged];
                c.accessoryView = seg;
                [seg sizeToFit];
                return c;
            }
            if (ip.row == 3) return [self switchCell:@"Clear page backgrounds" on:MRGClearPages() tag:2 symbol:nil];
            return [self switchCell:@"Profile picture glow" on:MRGProfileGlow() tag:3 symbol:nil];
        case MRGSecScreens: {
            NSArray *titles = @[@"Home", @"Now Playing", @"Library", @"Everywhere"];
            NSArray *symbols = @[@"house.fill", @"play.circle.fill", @"books.vertical.fill", @"square.stack.3d.up.fill"];
            return [self switchCell:titles[ip.row] on:(screens & (1 << ip.row)) != 0 tag:100 + ip.row symbol:symbols[ip.row]];
        }
        case MRGSecShop: return [self comingSoon:@"Addon Shop" symbol:@"bag.fill"];
        case MRGSecDJ: return [self comingSoon:@"AI DJ (your own API key)" symbol:@"waveform.and.mic"];
        case MRGSecAbout: {
            UITableViewCell *c = baseCell();
            c.textLabel.text = ip.row == 0 ? @"Version" : @"Vitrine";
            c.detailTextLabel.text = ip.row == 0 ? @(MRG_VERSION) : (NSClassFromString(@"SGModSettingsRow") ? @"Loaded" : @"Not loaded");
            c.detailTextLabel.textColor = UIColor.grayColor;
            return c;
        }
    }
    return baseCell();
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section != MRGSecMedia) return;
    if (ip.row == 0) [self pickFromPhotos];
    else if (ip.row == 1) [self pickFromFiles];
    else {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Remove background?" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            MRGRemoveCurrentMedia();
            [self.tableView reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    }
}

#pragma mark - controls

- (void)switched:(UISwitch *)sw {
    if (sw.tag == 1) MRGSetBackgroundEnabled(sw.on);
    else if (sw.tag == 2) MRGSetClearPages(sw.on);
    else if (sw.tag == 3) MRGSetProfileGlow(sw.on);
    else if (sw.tag >= 100) {
        MRGScreen bit = 1 << (sw.tag - 100);
        MRGSetScreens(sw.on ? (MRGScreens() | bit) : (MRGScreens() & ~bit));
    }
}

- (void)slid:(UISlider *)s {
    if (s.tag == 10) MRGSetBlur(s.value);
    else MRGSetDim(s.value);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGSecPreview] withRowAnimation:UITableViewRowAnimationNone];
}

- (void)scaled:(UISegmentedControl *)seg {
    MRGSetScale(seg.selectedSegmentIndex);
    [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGSecPreview] withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark - picking

- (void)pickFromPhotos {
    PHPickerConfiguration *config = [PHPickerConfiguration new];
    config.selectionLimit = 1;
    config.filter = [PHPickerFilter anyFilterMatchingSubfilters:@[PHPickerFilter.imagesFilter, PHPickerFilter.videosFilter]];
    config.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCurrent;
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    NSItemProvider *p = results.firstObject.itemProvider;
    if (!p) return;
    // GIF first (it also conforms to image), then movies, then any image.
    NSString *type = nil;
    for (UTType *t in @[UTTypeGIF, UTTypeMovie, UTTypeImage]) {
        if ([p hasItemConformingToTypeIdentifier:t.identifier]) { type = t.identifier; break; }
    }
    if (!type) return;
    [_spinner startAnimating];
    [p loadFileRepresentationForTypeIdentifier:type completionHandler:^(NSURL *url, NSError *error) {
        // The provider deletes its file when this block returns: copy it out first.
        NSURL *copy = nil;
        if (url) {
            copy = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"mirage-pick-%@.%@", NSUUID.UUID.UUIDString, url.pathExtension ?: @"dat"]];
            if (![NSFileManager.defaultManager copyItemAtURL:url toURL:copy error:&error]) copy = nil;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!copy) { [self finishedImport:error]; return; }
            MRGImportFile(copy, ^(NSError *e) {
                [NSFileManager.defaultManager removeItemAtURL:copy error:nil];
                [self finishedImport:e];
            });
        });
    }];
}

- (void)pickFromFiles {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeImage, UTTypeGIF, UTTypeMovie, UTTypeMPEG4Movie, UTTypeQuickTimeMovie] asCopy:YES];
    picker.delegate = self;
    picker.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)c didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    [_spinner startAnimating];
    MRGImportFile(url, ^(NSError *e) { [self finishedImport:e]; });
}

- (void)finishedImport:(NSError *)error {
    [_spinner stopAnimating];
    [self.tableView reloadData];
    if (!error) return;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Couldn't use that file" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end

void MRGRegisterSettingsPage(void) {
    Protocol *page = objc_getProtocol("_TtP19Tome_PageAttributes17SPTPageController_") ?: objc_getProtocol("SPTPageController");
    sg_pageConforms = page && (class_conformsToProtocol(MRGSettingsController.class, page) || class_addProtocol(MRGSettingsController.class, page));
}

void MRGShowSettings(UIViewController *owner) {
    MRGSettingsController *page = [MRGSettingsController new];
    if (owner.navigationController && sg_pageConforms) {
        [owner.navigationController pushViewController:page animated:YES];
        return;
    }
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [owner presentViewController:nav animated:YES completion:nil];
}
