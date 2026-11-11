#import "MRGSettings.h"
#import "MRGPrefs.h"
#import "MRGImporter.h"
#import "MRGBackgroundView.h"
#import "MRGAI.h"
#import "MRGDJ.h"
#import "MRGDJView.h"
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
        case MRGSecLook: return 6;                 // blur, dim, scale, top fade, clear pages, profile glow
        case MRGSecScreens: return 5;
        case MRGSecShop: return 1;
        case MRGSecDJ: return 7;                   // key, model, voice, duck, Home chip, player button, open
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
        case MRGSecLook: return @"Top fade is the dark shade Spotify lays behind the status bar and the header: Soft keeps a third of it, Off removes it. Clear page backgrounds makes Spotify's own page fill transparent so the background shows through; cards and Vitrine's glass stay as they are. Profile picture glow replaces the profile page's color gradient with a soft glow of that color around your picture.";
        case MRGSecScreens: return @"Everywhere puts the background behind every page, Home and Library included. The side drawer has its own switch, a little dimmer so its text stays readable.";
        case MRGSecDJ: {
            NSString *voice = MRGProviderHasTTS(MRGAIProvider()) ? @"Voice: Phone uses the best voice installed (add Premium voices in iOS Settings → Accessibility → Spoken Content); Provider uses your provider's own speech." : [NSString stringWithFormat:@"Voice: the best voice installed on this phone (%@); add Premium voices in iOS Settings → Accessibility → Spoken Content.", MRGDJDeviceVoiceName()];
            return [NSString stringWithFormat:@"Bring your own key: OpenAI, Gemini, Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together or DeepSeek. The key stays in this phone's keychain. Privacy: only track and artist names (what's playing, what you played, your top and liked tracks) and the requests you type are sent to your provider, nothing else. %@ On Spotify Free, Spotify may shuffle the set and its skip limit still applies.", voice];
        }
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

- (UITableViewCell *)djCell:(NSInteger)row {
    MRGProvider provider = MRGAIProvider();
    BOOL hasKey = provider != MRGProviderNone;
    switch (row) {
        case 0: {
            UITableViewCell *c = [self actionCell:@"API key" symbol:@"key.fill" destructive:NO enabled:YES];
            c.detailTextLabel.text = hasKey ? MRGProviderName(provider) : @"Add";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return c;
        }
        case 1: {
            UITableViewCell *c = [self actionCell:@"Model" symbol:@"cpu" destructive:NO enabled:hasKey];
            NSString *model = MRGAIModel();
            c.detailTextLabel.text = hasKey ? [NSString stringWithFormat:@"%@%@", model ?: @"-", MRGAIHasOverride() ? @"" : @" ✦"] : @"-";
            c.detailTextLabel.textColor = UIColor.grayColor;
            c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
            c.detailTextLabel.minimumScaleFactor = 0.6;
            return c;
        }
        case 2: {
            UITableViewCell *c = baseCell();
            c.textLabel.text = @"Voice";
            c.imageView.image = [UIImage systemImageNamed:@"speaker.wave.2.fill"];
            c.imageView.tintColor = UIColor.whiteColor;
            UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Phone", @"Provider", @"Off"]];
            [seg setEnabled:MRGProviderHasTTS(provider) forSegmentAtIndex:1];
            MRGDJVoiceMode m = MRGDJVoice();
            if (m == MRGDJVoiceProvider && !MRGProviderHasTTS(provider)) m = MRGDJVoiceDevice;
            seg.selectedSegmentIndex = m;
            [seg addTarget:self action:@selector(voiced:) forControlEvents:UIControlEventValueChanged];
            c.accessoryView = seg;
            [seg sizeToFit];
            return c;
        }
        case 3: return [self switchCell:@"Lower music while talking" on:MRGDJDucks() tag:20 symbol:@"speaker.badge.exclamationmark.fill"];
        case 4: return [self switchCell:@"DJ chip on Home" on:MRGDJShowsPill() tag:21 symbol:@"capsule.fill"];
        case 5: return [self switchCell:@"DJ button on Now Playing" on:MRGDJShowsPlayerButton() tag:22 symbol:@"play.circle.fill"];
        default: return [self actionCell:@"Open Mirage DJ" symbol:@"waveform.and.mic" destructive:NO enabled:YES];
    }
}

- (void)voiced:(UISegmentedControl *)seg { MRGDJSetVoice(seg.selectedSegmentIndex); }

- (void)reloadDJ { [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:MRGSecDJ] withRowAnimation:UITableViewRowAnimationNone]; }

- (void)editKey {
    BOOL hasKey = MRGAIProvider() != MRGProviderNone;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"AI provider key"
        message:@"Paste an API key from OpenAI, Gemini, Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together or DeepSeek. Mirage tells the provider from the key."
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.placeholder = @"sk-… / AIza… / gsk_… / xai-…";
        f.secureTextEntry = YES;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (hasKey) {
        [a addAction:[UIAlertAction actionWithTitle:@"Remove key" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *x) {
            [MRGDJ.shared stop];
            MRGAIForgetKey();
            [self reloadDJ];
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *key = a.textFields.firstObject.text;
        if (!key.length) return;
        [self->_spinner startAnimating];
        MRGAISetupKey(key, ^(BOOL ok, NSString *message) {
            [self->_spinner stopAnimating];
            [self reloadDJ];
            UIAlertController *r = [UIAlertController alertControllerWithTitle:ok ? @"Ready" : @"Couldn't use that key" message:message preferredStyle:UIAlertControllerStyleAlert];
            [r addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:r animated:YES completion:nil];
        });
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)pickModel:(UIView *)source {
    NSString *recommended = MRGAIRecommendedModel();
    NSMutableArray *models = [MRGAIModels() mutableCopy];
    if (recommended) { [models removeObject:recommended]; [models insertObject:recommended atIndex:0]; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Model"
        message:[NSString stringWithFormat:@"✦ is the recommended one for %@: fast and cheap. Any chat model works.", MRGProviderName(MRGAIProvider())]
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSUInteger shown = 0;
    for (NSString *m in models) {
        NSString *title = [m isEqualToString:recommended] ? [m stringByAppendingString:@" ✦"] : m;
        if ([m isEqualToString:MRGAIModel()]) title = [@"✓ " stringByAppendingString:title];
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            MRGAISetModelOverride(m);
            [self reloadDJ];
        }]];
        if (++shown >= 40) break;
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = source;
    a.popoverPresentationController.sourceRect = source.bounds;
    [self presentViewController:a animated:YES completion:nil];
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
            if (ip.row == 3) {
                UITableViewCell *c = baseCell();
                c.textLabel.text = @"Top fade";
                UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"Off", @"Soft", @"Full"]];
                seg.selectedSegmentIndex = MRGTopFade();
                [seg addTarget:self action:@selector(faded:) forControlEvents:UIControlEventValueChanged];
                c.accessoryView = seg;
                [seg sizeToFit];
                return c;
            }
            if (ip.row == 4) return [self switchCell:@"Clear page backgrounds" on:MRGClearPages() tag:2 symbol:nil];
            return [self switchCell:@"Profile picture glow" on:MRGProfileGlow() tag:3 symbol:nil];
        case MRGSecScreens: {
            NSArray *titles = @[@"Home", @"Now Playing", @"Library", @"Everywhere", @"Show in side drawer"];
            NSArray *symbols = @[@"house.fill", @"play.circle.fill", @"books.vertical.fill", @"square.stack.3d.up.fill", @"sidebar.left"];
            return [self switchCell:titles[ip.row] on:(screens & (1 << ip.row)) != 0 tag:100 + ip.row symbol:symbols[ip.row]];
        }
        case MRGSecShop: return [self comingSoon:@"Addon Shop" symbol:@"bag.fill"];
        case MRGSecDJ: return [self djCell:ip.row];
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
    if (ip.section == MRGSecDJ) {
        if (ip.row == 0) [self editKey];
        else if (ip.row == 1 && MRGAIProvider() != MRGProviderNone) [self pickModel:[t cellForRowAtIndexPath:ip]];
        else if (ip.row == 6) MRGShowDJ(self);
        return;
    }
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
    else if (sw.tag == 20) MRGDJSetDucks(sw.on);
    else if (sw.tag == 21) MRGDJSetShowsPill(sw.on);
    else if (sw.tag == 22) MRGDJSetShowsPlayerButton(sw.on);
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

- (void)faded:(UISegmentedControl *)seg { MRGSetTopFade(seg.selectedSegmentIndex); }

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
