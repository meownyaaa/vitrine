// The redesign's Home page of Mod Settings: Top picks and where its cards come from, what stays on Home, and
// one switch per shelf Home has shown lately (HomeShelves.m). Every switch is read as Home lays out, so a
// change needs a restart (SGRestartNote).
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Home.h"

static NSString *const kFirstShelf = @"First shelf";

UIViewController *SGRHomeSettingsPage(void) {
    NSArray<NSString *> *shelves = SGRHomeShelvesSeen();
    NSArray<NSString *> *sources = [@[kFirstShelf] arrayByAddingObjectsFromArray:shelves];
    SGModRow *from = SGMenuRow(@"Cards from", sources, ^NSString *{ return SGRHomeTopPicksFrom() ?: kFirstShelf; }, ^(NSInteger index) {
        if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGRKeyHomeTopPicksFrom];
        else [NSUserDefaults.standardUserDefaults setObject:sources[(NSUInteger)index] forKey:SGRKeyHomeTopPicksFrom];
        SGPrefsChanged();
    });
    SGModRow *look = SGSwitchRow(@"Home look", @"Top picks, the tinted shortcut pills and the title's glass pill; off, Home as the redesign had it", SGRKeyHomeLook);
    SGModRow *topPicks = SGRHomeTopPicksRow();
    topPicks.waitsOn = SGRKeyHomeLook;
    from.waitsOn = SGRKeyHomeTopPicks;
    SGModRow *colour = SGSwitchRow(@"Color behind Top picks", nil, SGRKeyHomeTopPicksColour);
    colour.waitsOn = SGRKeyHomeTopPicks;
    SGModRow *heading = SGOptionRow(@"Show Top picks heading", @"The shelf's own heading over its cards", SGRKeyHomeTopPicksHeading);
    heading.waitsOn = SGRKeyHomeTopPicks;

    NSMutableArray<SGModRow *> *rows = [NSMutableArray array];
    for (NSString *identity in shelves) [rows addObject:SGShownRow(identity, nil, SGRHomeShelfHideKey(identity))];
    if (!rows.count) [rows addObject:SGStatRow(@"None seen yet", ^NSString *{ return @""; })];

    return [[SGModPage alloc] initWithTitle:@"Home" intro:SGRestartNote sections:@[
        SGNotedSection(nil, @[look, topPicks, from, colour, heading],
                       @"A shelf Home does not show today leaves Top picks off until it is back."),
        SGSection(@"On Home", @[
            SGShownRow(@"Shortcuts", nil, SGRKeyHomeHideShortcuts),
            SGShownRow(@"DJ", nil, SGRKeyHomeHideDJ),
            SGOptionRow(@"Title stays on scroll", @"The title, the avatar and the pill stay at the top as Home scrolls under them", SGRKeyHomeKeepTitle),
            SGOptionRow(@"Song suggestions", @"Spotify's carousel of songs to try, when Home offers one", SGRKeyHomeSongSuggestions),
            SGOptionRow(@"Video and playlist previews", @"The cards that play as Home scrolls", SGRKeyHomePreviews),
        ]),
        SGNotedSection(@"Shelves", rows, @"The shelves Home has shown in the last 30 days. A shelf is known by its heading, so one "
                                         @"Spotify names differently in another language is listed again."),
    ] footer:nil];
}
