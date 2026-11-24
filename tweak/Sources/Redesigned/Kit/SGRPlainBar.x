// Redesign, iOS < 26: the pages that sit under UIKit's own navigation bar instead of drawing a header of
// their own -- Chapters (Show all of an episode's Chapters), Listening stats and its Top artists and Top
// songs, a track or an artist opened from them, Your Premium and its Manage subscription, and SongDNA (its
// Share and Close pinned as glass circles). Each is a controller hosted by
// Navigation_PageAPIIntegrationImpl.MusicAppPageHostingViewController.
//
// So are Messages (Campfire_RecentChatsPageImpl: Back, the title and the compose button, which the ⋯'s pinned button
// draws in glass) and Settings with all its sections (Settings_PlatformImpl.SettingsListViewController). Settings
// has no ⋯: its bar is dressed with Back and the title only (SGRDressBarPageBackOnly), whatever else Spotify keeps at
// the trailing edge.
//
// The bar is dressed by Pages/PageBar.m, as Recents' and Your Updates' are: Spotify's blur behind it drawn by
// nothing, its Back and its Share pinned to the page as glass circles at the corners, the title on a glass
// capsule in white. Pinned, and not a glass put inside the bar's own buttons: the Back of the bar is UIKit's, and
// the swipe back moves its chevron and its mask about and builds it again, so a circle inside it ended up on one
// layer with the chevron on another, under it and off centre. The chevron the bar draws sits 6pt left of the
// middle of its button besides.
//
// It is dressed from the bar's own layout passes as well as the page's: the page's child controller is made once
// its data has loaded, which no pass of the hosting controller follows, so a page opened at the top of its list
// showed Spotify's bar until it was scrolled.
//
// Its blur is kept off from the push (SGRSyncBarBlur, Pages/PageAppearance.x), not from the first pass that finds the bar.
//
// And the page itself is made dark. Under the redesign these lists drew a white UICollectionView under
// their white labels until the app was left and entered again, so every hosted page is given the dark
// appearance, which Spotify has everywhere, and the two Stats lists are cleared of the white they were
// painted. Manage subscription paints a black band as high as the bar over its list, which is drawn by
// nothing here.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"
#import "Redesigned/Pages/Pages.h"

static Class sg_hosting;

// A part of the name of a page's own controller, below the hosting one.
//
// The second group is the same kind of page, found in the class dump of 9.1.78 and not yet seen on a phone: pages of
// Navigation's page API (a module named ...PageImpl, so the hosting controller above holds them) from the families of the
// ones above -- the rest of Subscription management beside Your Premium and Plan overview, the listening activity
// pages beside Listening stats, Highlights stats' summary and details, the friends list, the new episodes list. The
// markers carry the module so a controller of another module with the same name is not taken for one. A page that keeps
// a header of its own (the audit's report lists a fill the bar should have taken, or the bar looks doubled) comes out
// of this list.
//
// The third group is found in the same class dump and not yet seen on a phone either: the rest of Subscription
// management (add a child, add-ons, member name and birthday, invitations, remove member, video settings), the audience
// picker of Listening activity, the profile's small editors (blocked list, bio, social handle, pronouns, completion),
// and the settings-like lists under the same bar (notifications, podcast, auto download, language, fitness, legal
// information, remote downloads, episodes settings, Your Library's offline sync, Settings search, the DJ's language and
// feedback pages, the reports of Lyrics and AI playlists, the AI disclosure, Martini's history). Pages of these
// modules that turn out to be sheets or to have a header of their own come out of the list, as above.
static NSArray<NSString *> *pageMarkers(void) {
    return @[@"EntitySegmentsViewController", @"UserTimelineViewController", @"StatsDetailsViewController",
             @"YourPremiumViewController", @"PlanOverviewViewController", @"SongDNAViewController",
             @"SubscriptionManagement_AvailablePlansPageImpl", @"SubscriptionManagement_PlanDetailsPageImpl",
             @"SubscriptionManagement_BillingPageImpl", @"SubscriptionManagement_AddOnManagementPageImpl",
             @"SubscriptionManagement_MemberDetailsPageImpl", @"SubscriptionManagement_RegularMemberSubAccountDetailsPageImpl",
             @"SubscriptionManagement_DenominationSelectionPageImpl",
             @"ListeningActivity_ListeningActivityDetailsPageImpl", @"ListeningActivity_GroupDetailsPageImpl",
             @"ListeningActivity_AudienceSettingPageImpl",
             @"HighlightsStats_SummaryPageImpl", @"HighlightsStats_HighlightDetailsPageImpl",
             @"Profile_FriendsListPageImpl", @"CollectionPodcast_NewEpisodesPageImpl",
             @"SubscriptionManagement_AddChildPlanMemberPageImpl", @"SubscriptionManagement_AddOnConsiderationPageImpl",
             @"SubscriptionManagement_AudiobookConsiderationPageImpl", @"SubscriptionManagement_MemberDetailsUpdateNamePageImpl",
             @"SubscriptionManagement_MemberDetailsUpdateBirthdayPageImpl", @"SubscriptionManagement_PlanMemberInvitationImpl",
             @"SubscriptionManagement_RemoveMemberPageImpl", @"SubscriptionManagement_VideoSettingsPageImpl",
             @"ListeningActivity_GroupAudienceSelectionPageImpl",
             @"Profile_BlockedListImpl", @"Profile_EditBioPageImpl", @"Profile_EditSocialHandlePageImpl",
             @"Profile_PronounsPageImpl", @"Profile_CompletionImpl",
             @"Notifications_NotificationPreferencesImpl", @"Notifications_PodcastNewEpisodeNotificationImpl",
             @"PodcastSettings_CommonImpl", @"AutoDownload_CommonImpl", @"Language_LanguageSettingsImpl",
             @"Fitness_SettingsPageImpl", @"LegalInformation_BusinessInformationPageImpl",
             @"RemoteDownloads_RemoteDownloadsUIImpl", @"CollectionEpisodes_EpisodesSettingsImpl",
             @"YourLibraryOfflineSyncViewController", @"Settings_SearchPageImpl",
             @"Endless_DJSettingsLanguagePageImpl", @"Endless_DJSubmitFeedbackPageImpl",
             @"Lyrics_ReportPageImpl", @"AIPlaylist_ReportAProblemPageImpl",
             @"Martini_AiDisclosurePageImpl", @"Martini_HistoryPageImpl",
             @"Campfire_RecentChatsPageImpl", @"SettingsListViewController"];
}

// The pages above that have no ⋯ of their own and keep what Spotify has at the trailing edge.
static NSArray<NSString *> *backOnlyMarkers(void) {
    return @[@"SettingsListViewController"];
}

static BOOL holdsMarker(UIViewController *controller, NSArray<NSString *> *markers, int depth) {
    if (depth > 6) return NO;
    for (UIViewController *child in controller.childViewControllers) {
        NSString *name = NSStringFromClass(child.class);
        for (NSString *marker in markers) {
            if ([name containsString:marker]) return YES;
        }
        if (holdsMarker(child, markers, depth + 1)) return YES;
    }
    return NO;
}

static BOOL isPage(UIViewController *controller, int depth) {
    return holdsMarker(controller, pageMarkers(), depth);
}

static BOOL isBackOnlyPage(UIViewController *controller) {
    return holdsMarker(controller, backOnlyMarkers(), 0);
}

// The white UICollectionView Spotify's Stats lists paint.
static void clearStatsLists(UIView *root) {
    SGForEachView(root, ^(UIView *v) {
        if (![v isKindOfClass:UICollectionView.class]) return;
        if (![v.accessibilityIdentifier hasSuffix:@"ViewController.CollectionView"]) return;
        if (![v.accessibilityIdentifier hasPrefix:@"UserTimeline"] && ![v.accessibilityIdentifier hasPrefix:@"StatsDetails"]) return;
        if (v.backgroundColor && ![v.backgroundColor isEqual:UIColor.clearColor]) v.backgroundColor = UIColor.clearColor;
    });
}

// The black band over the top of Manage subscription's list: a plain childless view at the top of the page, as wide
// as it and as high as the bar, painted the page black. An empty mask, which Spotify's painting it again does not undo.
static void clearTopBand(UIView *root) {
    CGFloat width = root.bounds.size.width;
    SGForEachView(root, ^(UIView *v) {
        if (v == root || ![v isMemberOfClass:UIView.class] || v.subviews.count || v.layer.mask) return;
        CGRect frame = v.frame;
        if (fabs(frame.origin.y) > 0.5 || fabs(frame.size.width - width) > 1 || frame.size.height < 40 || frame.size.height > 140) return;
        CGColorRef color = v.layer.backgroundColor;
        if (!color || !SGIsBaseSurface(color)) return;
        v.layer.mask = [CALayer layer];
        if (v.userInteractionEnabled) v.userInteractionEnabled = NO;
    });
}

static void dress(UIViewController *page) {
    UIView *root = page.viewIfLoaded;
    if (root.overrideUserInterfaceStyle != UIUserInterfaceStyleDark) root.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    if (!isPage(page, 0)) return;
    clearStatsLists(root);
    clearTopBand(root);
    if (!SGBelowiOS26()) return;
    if (isBackOnlyPage(page)) SGRDressBarPageBackOnly(page);
    else SGRDressBarPage(page);
}

static void undress(UIViewController *page) {
    if (!SGBelowiOS26() || !isPage(page, 0)) return;
    SGRUndressBarPage(page);
}

// The bar's own passes: the page on top of its navigation controller, if it is one of these, is dressed.
static void barPass(UIView *bar) {
    UIViewController *top = SGRNavigationOf(bar).topViewController;
    if (top && [top isKindOfClass:sg_hosting] && top.viewIfLoaded.window) dress(top);
}

%ctor {
    // Below iOS 26 only: on iOS 26 the page keeps the look it has on main.
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    Class hosting = SGRSwiftClass(@"Navigation_PageAPIIntegrationImpl", @"MusicAppPageHostingViewController");
    if (!hosting) {
        SGLog(@"class Navigation_PageAPIIntegrationImpl.MusicAppPageHostingViewController not found, Chapters, Listening stats, Your Premium and Manage subscription keep Spotify's bar");
        return;
    }
    sg_hosting = hosting;
    // A hosted page whose own controller has not been made yet is taken for one of these: its blur stays off from the push,
    // and is given back at the next pass if the page turns out to be another.
    if (SGBelowiOS26()) {
        SGRRegisterBarPages(^BOOL(UIViewController *top) {
            return [top isKindOfClass:hosting] && (!top.childViewControllers.count || isPage(top, 0));
        });
    }
    SGRPassController(hosting, ^(UIViewController *c) { dress(c); });
    SGRPassControllerGoing(hosting, ^(UIViewController *c) { undress(c); });
    SGRObserveBarPasses(^(UIView *bar) { barPass(bar); });
}
