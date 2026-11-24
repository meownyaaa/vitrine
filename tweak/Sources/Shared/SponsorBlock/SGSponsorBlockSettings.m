// Settings page and category metadata for SponsorBlock.
// Ported from EeveeSpotify Reincarnated (GPL-3.0) and Spot-SponsorBlock-Extension.

#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "SGSponsorBlock.h"
#import "SGSponsorBlockOverlay.h"

typedef struct {
    __unsafe_unretained NSString *key;
    __unsafe_unretained NSString *rowTitle;
    __unsafe_unretained NSString *toastName;
    SGSponsorBlockBehavior defaultBehavior;
    NSInteger defaultRGB;
} SGCategorySpec;

static const SGCategorySpec kCategories[] = {
    { @"sponsor",          @"Sponsor",               @"Sponsor",              SGSponsorBlockBehaviorSkip,   0x00D400 },
    { @"selfpromo",        @"Unpaid/Self Promotion", @"Self-promotion",       SGSponsorBlockBehaviorSkip,   0xFFFF00 },
    { @"interaction",      @"Interaction Reminder",  @"Interaction reminder", SGSponsorBlockBehaviorSkip,   0xCC00FF },
    { @"intro",            @"Intermission/Intro",    @"Intro",                SGSponsorBlockBehaviorPrompt, 0x00FFFF },
    { @"outro",            @"Outro/Credits",         @"Outro",                SGSponsorBlockBehaviorPrompt, 0x0202ED },
    { @"preview",          @"Preview/Recap",         @"Preview",              SGSponsorBlockBehaviorOff,    0x008FD6 },
    { @"hook",             @"Hook/Greetings",        @"Hook",                 SGSponsorBlockBehaviorOff,    0x008F87 },
    { @"filler",           @"Tangent/Filler",        @"Filler",               SGSponsorBlockBehaviorOff,    0x7300FF },
    { @"exclusive_access", @"Exclusive Access",      @"Exclusive access",     SGSponsorBlockBehaviorOff,    0x008A5C },
};

static const size_t kCategoryCount = sizeof(kCategories) / sizeof(kCategories[0]);

static const SGCategorySpec *specForCategory(NSString *category) {
    if ([category isEqualToString:@"exclusive"]) category = @"exclusive_access";
    for (size_t i = 0; i < kCategoryCount; i++) {
        if ([kCategories[i].key isEqualToString:category]) return &kCategories[i];
    }
    return NULL;
}

static NSInteger colorToRGB(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGFloat white = 0;
        if ([color getWhite:&white alpha:&a]) {
            r = g = b = white;
        }
    }
    NSInteger ir = (NSInteger)round(fmax(0.0, fmin(1.0, r)) * 255.0);
    NSInteger ig = (NSInteger)round(fmax(0.0, fmin(1.0, g)) * 255.0);
    NSInteger ib = (NSInteger)round(fmax(0.0, fmin(1.0, b)) * 255.0);
    return (ir << 16) | (ig << 8) | ib;
}

NSArray<NSString *> *SGSponsorBlockAllCategories(void) {
    static NSArray<NSString *> *all;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<NSString *> *list = [NSMutableArray arrayWithCapacity:kCategoryCount];
        for (size_t i = 0; i < kCategoryCount; i++) [list addObject:kCategories[i].key];
        all = [list copy];
    });
    return all;
}

UIColor *SGSponsorBlockCategoryColor(NSString *category) {
    if ([category isEqualToString:@"exclusive"]) category = @"exclusive_access";
    NSString *prefKey = [@"spotifyglass.sponsorblock.color." stringByAppendingString:category];
    NSInteger stored = SGInt(prefKey, -1);
    if (stored >= 0 && stored <= 0xFFFFFF) {
        return SGColorRGB(stored);
    }
    const SGCategorySpec *spec = specForCategory(category);
    return SGColorRGB(spec ? spec->defaultRGB : 0x00D400);
}

void SGSetSponsorBlockCategoryColor(NSString *category, NSInteger rgb) {
    if ([category isEqualToString:@"exclusive"]) category = @"exclusive_access";
    NSString *prefKey = [@"spotifyglass.sponsorblock.color." stringByAppendingString:category];
    SGSetInt(prefKey, rgb);
    SGSponsorBlockPreferencesDidChange();
}

void SGResetSponsorBlockCategoryColors(void) {
    for (size_t i = 0; i < kCategoryCount; i++) {
        NSString *prefKey = [@"spotifyglass.sponsorblock.color." stringByAppendingString:kCategories[i].key];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:prefKey];
    }
    SGPrefsChanged();
    SGSponsorBlockPreferencesDidChange();
}

NSString *SGSponsorBlockCategoryDisplayName(NSString *category) {
    const SGCategorySpec *spec = specForCategory(category);
    return spec ? spec->toastName : @"Sponsor";
}

SGSponsorBlockBehavior SGSponsorBlockCategoryBehavior(NSString *category) {
    const SGCategorySpec *spec = specForCategory(category);
    NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:spec ? spec->key : category];
    NSInteger val = SGInt(prefKey, -1);
    if (val >= 0 && val <= 3) return (SGSponsorBlockBehavior)val;
    return spec ? spec->defaultBehavior : SGSponsorBlockBehaviorOff;
}

void SGSetSponsorBlockCategoryBehavior(NSString *category, SGSponsorBlockBehavior behavior) {
    const SGCategorySpec *spec = specForCategory(category);
    NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:spec ? spec->key : category];
    SGSetInt(prefKey, behavior);
    SGSponsorBlockPreferencesDidChange();
}

void SGResetSponsorBlockCategoriesToDefaults(void) {
    for (size_t i = 0; i < kCategoryCount; i++) {
        NSString *prefKey = [@"spotifyglass.sponsorblock.behavior." stringByAppendingString:kCategories[i].key];
        [NSUserDefaults.standardUserDefaults removeObjectForKey:prefKey];
    }
    SGResetSponsorBlockCategoryColors();
}

static NSInteger segmentIndexForBehavior(SGSponsorBlockBehavior b) {
    switch (b) {
        case SGSponsorBlockBehaviorSkip: return 0;
        case SGSponsorBlockBehaviorPrompt: return 1;
        case SGSponsorBlockBehaviorShowOnly: return 2;
        case SGSponsorBlockBehaviorOff: return 3;
    }
    return 3;
}

static SGSponsorBlockBehavior behaviorForSegmentIndex(NSInteger idx) {
    switch (idx) {
        case 0: return SGSponsorBlockBehaviorSkip;
        case 1: return SGSponsorBlockBehaviorPrompt;
        case 2: return SGSponsorBlockBehaviorShowOnly;
        case 3: return SGSponsorBlockBehaviorOff;
    }
    return SGSponsorBlockBehaviorOff;
}

NSString *SGSponsorBlockSummary(void) {
    NSUInteger active = 0;
    for (size_t i = 0; i < kCategoryCount; i++) {
        if (SGSponsorBlockCategoryBehavior(kCategories[i].key) != SGSponsorBlockBehaviorOff) active++;
    }
    return active ? [NSString stringWithFormat:@"%lu active", (unsigned long)active] : @"None";
}

BOOL SGSponsorBlockSubSwitchEnabled(NSString *key) {
    return SGEnabled(key);
}

static SGModRow *categorySegmentRow(const SGCategorySpec *spec) {
    NSString *catKey = spec->key;
    NSString *catTitle = spec->rowTitle;
    NSArray<NSString *> *segments = @[@"Auto", @"Prompt", @"Show", @"Off"];

    SGModRow *row = SGSegmentRow(catTitle, nil, segments, ^NSInteger {
        return segmentIndexForBehavior(SGSponsorBlockCategoryBehavior(catKey));
    }, ^(NSInteger index) {
        SGSetSponsorBlockCategoryBehavior(catKey, behaviorForSegmentIndex(index));
    });

    row.swatch = ^UIColor *{
        return SGSponsorBlockCategoryColor(catKey);
    };

    row.colorAction = ^{
        UIColor *cur = SGSponsorBlockCategoryColor(catKey);
        NSInteger currentRGB = colorToRGB(cur);
        SGPickColor(catTitle, currentRGB, ^(NSInteger rgb) {
            SGSetSponsorBlockCategoryColor(catKey, rgb);
        });
    };

    return row;
}

static void presentDarkAlert(UIAlertController *alert) {
    SGPresentDark(alert);
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static UIViewController *sponsorBlockAdvancedPage(void) {
    __block __weak SGModPage *weakPage = nil;

    SGModRow *serverRow = SGWithSymbol(SGActionRow(@"Server URL", @"Custom SponsorBlock API server address", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Server URL"
                                                                       message:@"Enter custom SponsorBlock API server address (default: https://sponsor.ajay.app)"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        __weak UIAlertController *weakAlert = alert;
        [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
            textField.placeholder = @"https://sponsor.ajay.app";
            textField.text = SGSponsorBlockServerURL();
            textField.keyboardType = UIKeyboardTypeURL;
            textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
            textField.autocorrectionType = UITextAutocorrectionTypeNo;
        }];
        [alert addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            UITextField *tf = weakAlert.textFields.firstObject;
            SGSetSponsorBlockServerURL(tf.text);
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset to Default" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGSetSponsorBlockServerURL(nil);
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        presentDarkAlert(alert);
    }), @"network");
    serverRow.value = ^NSString *{
        return SGSponsorBlockServerURL();
    };

    SGModRow *minDuration = SGSliderRow(@"Min segment duration", nil, 0.0, 30.0, 0.5,
        ^double { return SGSponsorBlockMinDuration(); },
        ^(double value) { SGSetSponsorBlockMinDuration(value); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.1fs", value]; });

    SGModRow *toastDuration = SGSliderRow(@"Toast duration", nil, 1.0, 8.0, 0.2,
        ^double { return SGSponsorBlockToastDuration(); },
        ^(double value) { SGSetSponsorBlockToastDuration(value); },
        ^NSString *(double value) { return [NSString stringWithFormat:@"%.1fs", value]; });

    SGModRow *promptDuration = SGSliderRow(@"Prompt duration", nil, 5.0, SGSponsorBlockPromptDurationInfinite, 5.0,
        ^double { return SGSponsorBlockPromptDuration(); },
        ^(double value) { SGSetSponsorBlockPromptDuration(value); },
        ^NSString *(double value) {
            return value >= SGSponsorBlockPromptDurationInfinite ? @"Until end" : [NSString stringWithFormat:@"%.0fs", value];
        });

    SGModRow *resetAction = SGWithSymbol(SGActionRow(@"Reset advanced settings", @"Restore default server and duration settings", ^{
        UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Reset what?"
                                                                        message:nil
                                                                 preferredStyle:UIAlertControllerStyleActionSheet];
        void (^resetSettings)(BOOL) = ^(BOOL includeStats) {
            SGSetEnabled(SGKeySponsorBlockOverlay, YES);
            SGSetEnabled(SGKeySponsorBlockShowToast, YES);
            SGSetEnabled(SGKeySponsorBlockHaptics, YES);
            SGSetEnabled(SGKeySponsorBlockRespectManual, YES);
            SGResetSponsorBlockCategoriesToDefaults();
            if (includeStats) SGResetSponsorBlockStats();
            SGSetSponsorBlockMinDuration(0.0);
            SGSetSponsorBlockToastDuration(3.0);
            SGSetSponsorBlockPromptDuration(SGSponsorBlockPromptDurationInfinite);
            SGSetSponsorBlockServerURL(nil);
            SGSponsorBlockPreferencesDidChange();
            [weakPage.tableView reloadData];
        };
        [sheet addAction:[UIAlertAction actionWithTitle:@"Settings (toggles + categories + colors)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            resetSettings(NO);
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Everything (settings + statistics)" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            resetSettings(YES);
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        UIView *source = weakPage.view ?: SGTopController().view;
        sheet.popoverPresentationController.sourceView = source;
        sheet.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(source.bounds), CGRectGetMidY(source.bounds), 1, 1);
        sheet.popoverPresentationController.permittedArrowDirections = 0;
        presentDarkAlert(sheet);
    }), @"arrow.counterclockwise");
    resetAction.color = SGRed();

    SGModPage *page = [[SGModPage alloc] initWithTitle:@"Advanced" intro:nil sections:@[
        SGSection(@"Server", @[serverRow]),
        SGSection(@"Tuning", @[minDuration, toastDuration, promptDuration]),
        SGSection(nil, @[resetAction]),
    ] footer:nil];
    weakPage = page;
    return page;
}

UIViewController *SGSponsorBlockSettingsPage(void) {
    __block __weak SGModPage *weakPage = nil;

    SGModRow *overlay = SGWithSymbol(SGSwitchRow(@"Show colored overlay on progress bar", nil, SGKeySponsorBlockOverlay), @"chart.bar.xaxis");
    overlay.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *toast = SGWithSymbol(SGSwitchRow(@"Show toast when skipping", nil, SGKeySponsorBlockShowToast), @"bell");
    toast.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *haptics = SGWithSymbol(SGSwitchRow(@"Haptic feedback", nil, SGKeySponsorBlockHaptics), @"iphone.radiowaves.left.and.right");
    haptics.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    SGModRow *respectManual = SGWithSymbol(SGSwitchRow(@"Respect manual seek (don't re-skip)", nil, SGKeySponsorBlockRespectManual), @"slider.horizontal.below.rectangle");
    respectManual.changed = ^(BOOL on) { SGSponsorBlockPreferencesDidChange(); };

    NSMutableArray<SGModRow *> *categories = [NSMutableArray arrayWithCapacity:kCategoryCount + 1];
    for (size_t i = 0; i < kCategoryCount; i++) {
        [categories addObject:categorySegmentRow(&kCategories[i])];
    }

    SGModRow *resetCategoriesRow = SGWithSymbol(SGActionRow(@"Reset categories and colors", @"Restore default behaviors and segment colors", ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset categories and colors?"
                                                                        message:@"This restores all categories to their default behaviors and segment colors."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGResetSponsorBlockCategoriesToDefaults();
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        presentDarkAlert(alert);
    }), @"arrow.counterclockwise");
    [categories addObject:resetCategoriesRow];

    SGModRow *advancedNav = SGWithSymbol(SGPageRow(@"Advanced", ^UIViewController *{ return sponsorBlockAdvancedPage(); }), @"gearshape.2");

    SGModRow *statRow = SGWithSymbol(SGStatRow(@"Segments skipped", ^NSString *{
        return @(SGSponsorBlockSkipCount()).stringValue;
    }), @"number");

    SGModRow *timeRow = SGWithSymbol(SGStatRow(@"Time saved", ^NSString *{
        return SGSponsorBlockFormattedTimeSaved();
    }), @"clock");

    SGModRow *resetStatsRow = SGWithSymbol(SGActionRow(@"Reset statistics", nil, ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset statistics?"
                                                                        message:@"This clears your skipped segment count and time saved."
                                                                 preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            SGResetSponsorBlockStats();
            [weakPage.tableView reloadData];
        }]];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        presentDarkAlert(alert);
    }), @"trash");

    SGModRow *eeveeLink = SGWithSymbol(SGLinkRow(@"EeveeSpotify Reincarnated on GitHub", nil, @"https://github.com/SideloadLabs/EeveeSpotifyReincarnated"), @"link");
    SGModRow *extLink = SGWithSymbol(SGLinkRow(@"Spot-SponsorBlock-Extension on GitHub", nil, @"https://github.com/Spot-SponsorBlock/Spot-SponsorBlock-Extension"), @"link");
    SGModRow *sbLink = SGWithSymbol(SGLinkRow(@"SponsorBlock", nil, @"https://sponsor.ajay.app"), @"safari");

    NSString *headerSectionFooter = @"Skips community-marked segments in podcast episodes.";
    NSString *categoriesFooter = @"Auto · Prompt · Show · Off. Tap the color circle to change.";
    NSString *creditsFooter = @"Segment data from the SponsorBlock community (sponsor.ajay.app). Ported from EeveeSpotify Reincarnated (GPL-3.0), based on Spot-SponsorBlock-Extension.";

    SGModPage *page = [[SGModPage alloc] initWithTitle:@"SponsorBlock" intro:nil sections:@[
        SGNotedSection(nil, @[overlay, toast, haptics, respectManual], headerSectionFooter),
        SGNotedSection(@"Categories", categories, categoriesFooter),
        SGSection(nil, @[advancedNav]),
        SGSection(@"Statistics", @[statRow, timeRow, resetStatsRow]),
        SGNotedSection(@"Credits", @[eeveeLink, extLink, sbLink], creditsFooter),
    ] footer:nil];
    weakPage = page;
    return page;
}
