// Labs: Spotify's flags for features it built and did not ship; every row forces one flag.
#import "Settings/SGModPage.h"
#import "Flags.h"

static int compareKey(const void *key, const void *def) {
    return strcmp(key, ((const SGFlagDef *)def)->key);
}

// Only the rows for flags this Spotify has: the table comes from the IPA the build is for, and a flag
// it lacks would force nothing. A section left empty goes too.
static NSArray<SGModSection *> *known(NSArray<SGModSection *> *sections) {
    NSMutableArray<SGModSection *> *kept = [NSMutableArray array];
    for (SGModSection *section in sections) {
        NSIndexSet *rows = [section.rows indexesOfObjectsPassingTest:^BOOL(SGModRow *row, NSUInteger i, BOOL *stop) {
            return !row.flag || bsearch(row.key.UTF8String, SGFlagTable, SGFlagCount, sizeof *SGFlagTable, compareKey);
        }];
        if (!rows.count) continue;
        section.rows = [section.rows objectsAtIndexes:rows];
        [kept addObject:section];
    }
    return kept;
}

static UIViewController *martiniPage(void) {
    return [[SGModPage alloc] initWithTitle:@"AI Chat (Martini)" intro:SGRestartNote sections:known(@[
        SGSection(@"On Home", @[
            SGFlagRow(@"Chat entry point", @"ios-home-evopage-impl.interactive_entrypoint_enabled"),
            SGFlagRow(@"Martini behind it", @"ios-home-evopage-impl.interactive_entrypoint_martini_enabled"),
            SGFlagRow(@"Floating chat", @"ios-home-evopage-impl.interactive_entrypoint_floating_chat_enabled"),
            SGFlagRow(@"Microphone", @"ios-home-evopage-impl.interactive_entrypoint_mic_enabled"),
            SGFlagRow(@"Glowing pill", @"ios-home-evopage-impl.interactive_entrypoint_pill_glow_enabled"),
        ]),
        SGSection(@"The chat", @[
            SGFlagRow(@"Intent pills", @"ios-martini-floatingchat-impl.intent_pills_enabled"),
            SGFlagRow(@"Thinking states", @"ios-martini-floatingchat-impl.thinking_states_enabled"),
            SGFlagRow(@"Voice recording", @"ios-martini-floatingchat-impl.voice_recording_enabled"),
        ]),
        SGSection(@"In the player", @[
            SGFlagRow(@"Chat entry point", @"ios-martini-npvcardprovider-impl.floating_chat_entry_point_enabled"),
            SGFlagRow(@"Agent button", @"ios-martini-npvcardprovider-impl.npv_agent_button_enabled"),
        ]),
    ]) footer:nil];
}

UIViewController *SGLabsPage(void) {
    return [[SGModPage alloc] initWithTitle:@"Labs" intro:@"Unreleased features; some do nothing on your version. Changes apply after you restart Spotify." sections:known(@[
        SGSection(nil, @[
            SGWithSymbol(SGPageRow(@"AI Chat (Martini)", ^UIViewController *{ return martiniPage(); }), @"bubble.left.and.bubble.right"),
        ]),
        SGSection(@"Library", @[
            SGFlagRow(@"Local files from the Files app", @"ios-feature-localfiles.documents_enabled"),
        ]),
        SGSection(@"Home screen widget", @[
            SGFlagRow(@"Progress bar", @"ios-widgets-widgetremoteconfig-impl.progress_bar_enabled"),
        ]),
        SGNotedSection(@"Sleep timer", @[
            SGFlagRow(@"Fade out", @"ios-feature-sleeptimer.enable_fade_out"),
            SGFlagRow(@"One minute option", @"ios-feature-sleeptimer.enable_one_minute_option"),
            SGFlagRow(@"Options sheet", @"ios-feature-sleeptimer.use_options_sheet"),
        ], @"Options sheet is always on in Redesigned UI."),
        SGSection(@"DJ", @[
            SGFlagRow(@"Auto mix", @"ios-playlistcuration-mats.auto_mix_enabled_for_dj"),
            SGFlagRow(@"Auto mix in the context menu", @"ios-playlistcuration-mats.dj_auto_mix_context_menu_enabled"),
        ]),
        SGSection(@"Player", @[
            SGFlagRow(@"Snake on the cover art", @"ios-feature-cover-art-snake.enabled"),
        ]),
        SGSection(@"Podcast comments", @[
            SGFlagRow(@"Comments card", @"ios-feature-comments.enable_comments_card"),
            SGFlagRow(@"Pinned comments", @"ios-feature-comments.enable_pinned_comments"),
            SGFlagRow(@"Several reactions", @"ios-feature-comments.enable_multi_reactions"),
        ]),
    ]) footer:nil];
}
