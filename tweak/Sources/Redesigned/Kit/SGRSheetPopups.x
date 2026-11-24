// Redesign, iOS < 26: glass for the popups that were still Spotify's opaque grey. Each gets the queue's pane
// (SGRGlassSheetChrome) and the screen's own top corners.
//
// Most are the same Navigation sheet (NavigationUI_SheetImpl.ContainerViewController, id=sheet-view) holding their
// own controller. That class is Swift and generic for SwiftUI pages, so a sheet is recognised by part of the inner
// controller's name (contentMarkers). The pane goes in from the sheet's own passes because its rows are built after
// the first layout; SGRRepaint.x keeps Spotify's grey clear in between. A page presented outside Navigation's sheet
// and not listed keeps its own look.
//
// Not Navigation sheets, so each gets its pane by its own controller: Save in, Share, Listening modes, the library's
// Sort by (a card of SPTSortingFilteringPresentationController), the podcast speed popup, Report a problem, Rate show
// and the Connect device menu.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

static void clearOpaque(UIView *view) {
    if (view.opaque) view.opaque = NO;
    if (view.layer.opaque) view.layer.opaque = NO;
}

// A part of the class name of the controller that fills each sheet above: the module, where every class of the
// module is that page, and the class itself where the module is UIKit's old picker.
static NSArray<NSString *> *contentMarkers(void) {
    return @[@"Connect_VolumeUXImpl",
             @"Jam_InvitationFlowImpl",
             @"Jam_ParticipantSettingsPageImpl",
             @"AssistedCuration_",
             @"SPTSortingFilteringPickerViewController",
             @"FilterAndSort_PresentingImpl",
             @"ShowPage_SortAndFilterImpl",
             @"TrackCredits_CreditsPageImpl",
             @"PlaylistCuration_AddToPlaylistImpl",
             @"Offline_ContentOffliningUIImpl",
             @"PlaylistMixing_MessagingImpl",
             @"MixingEditMoreMenuViewController",
             @"SongDNA_AboutSongDNAPageImpl",
             @"FolderRenameViewController",
             @"Jam_MessagingSheetImpl",
             @"SongDNA_ContributorSheetPageImpl",
             @"AccountSwitching_AccountPickerImpl",
             @"Settings_ConfirmationDialogPageImpl",
             @"PlaylistCollaboration_PlaylistEditorsPickerPageImpl",
             @"MusicVideos_VideoConnectSheetImpl",
             @"VideoSettingsBottomSheetViewController",
             @"VideoDisabledByPolicySheetViewController",
             @"ArtistBadgesSheetViewController",
             @"Audiobook_SupplementaryContentBottomSheetImpl",
             @"DSA_MessagingImpl",
             @"DSA_InlineToggleImpl",
             @"MarqueeContextMenuViewController",
             @"DisclaimerSheetViewController",
             @"Campfire_ChatDisclaimerImpl",
             @"ChatPhotoPickerViewController",
             @"Campfire_ChatGifPickerPageImpl",
             @"Campfire_ChatEntityPickerPageImpl",
             @"Campfire_ChatContentPickerPageImpl",
             @"PodcastMembershipBottomSheetViewController",
             @"GatedContent_GatedContentBottomSheetPageImpl",
             @"ModalReactionPickerViewController",
             @"PodcastInteractivity_CommentsImpl",
             @"ReactionSheetViewController",
             @"ReactionSheetPageViewController",
             @"PodcastInteractivity_TermsSheetPageImpl",
             @"Contribution_ContextMenuImpl",
             @"Creator_AgentsPresentationImpl",
             @"Reflection_SurveySheetPageImpl",
             @"OnTour_MultiEventBottomSheetImpl",
             @"LiveEvents_FilterSheetImpl",
             @"Merchandising_BottomSheetDialogKit",
             @"FontPickerViewController",
             @"ColorPickerViewController",
             @"ImagePickerViewController",
             @"StickerPickerViewController",
             @"Transcript_TranscriptSelectionImpl",
             @"AllBoarding_AllBoardingPlatformImpl",
             @"SocialListeningPartnerIntegrations_UIImpl",
             @"ClientMessagingPlatformBottomSheetPageViewController",
             @"SongDNA_MapKit",
             @"Connect_DevicePickerPageImpl",
             @"DevicePredictability_",
             @"YourLibrary_YourLibraryXImpl25BottomSheetViewController",
             @"AIPlaylist_PlaylistCreationPageImpl25BottomSheetViewController",
             @"Upsells_SheetPageImpl",
             @"EReader_EReaderPageImpl",
             @"VersionSunsetting_DialogPageImpl",
             @"SpotifyTap_AccessoryOnboardingImpl",
             @"Profile_KidsProfileAvatarPickerImpl",
             @"HighlightsStats_StatsDetailsPageImpl",
             @"ModalContainerViewController",
             @"PodcastUIPlatform_MemberButtonElementKit",
             @"LiveEvents_MultiEventsBottomSheetPageImpl",
             @"MusicQuiz_",
             @"SubscriptionManagement_AllocationRequestDialogPageImpl",
             @"PromptablePlaylists_",
             @"PromptedPlaylistRefining_",
             @"PersonalizedEpisodes_",
             @"Home_PromptEntryKit",
             @"Blend_SocialPromptingImpl"];
}

static BOOL isContent(UIViewController *controller) {
    NSString *name = NSStringFromClass(controller.class);
    for (NSString *marker in contentMarkers()) {
        if ([name containsString:marker]) return YES;
    }
    return NO;
}

// The first controller inside the sheet's that is one of those pages, looked for through the hosting controllers
// and navigation controllers Spotify wraps it in.
static UIViewController *contentIn(UIViewController *controller, int depth) {
    if (depth > 10) return nil;
    for (UIViewController *child in controller.childViewControllers) {
        if (isContent(child)) return child;
        UIViewController *inner = contentIn(child, depth + 1);
        if (inner) return inner;
    }
    return nil;
}

// Whether a page of Spotify's template that loads its content later is in the sheet: Save in is one, and its
// ATPContainerViewController is only added once the page has loaded.
static BOOL loadingIn(UIViewController *controller, int depth) {
    if (depth > 10) return NO;
    for (UIViewController *child in controller.childViewControllers) {
        if ([NSStringFromClass(child.class) containsString:@"LoadableTemplateViewController"]) return YES;
        if (loadingIn(child, depth + 1)) return YES;
    }
    return NO;
}

static char kPendingPaneKey;

// The sheet Save in is in, while it is up: what the write-time hooks below test a view against.
static __weak UIView *sg_saveInSheet;

// Save in's wrappers are painted an opaque black, which the pane's strip leaves alone and which would make the popup
// near black over the glass. An opaque view with no fill is drawn black too, so the flag goes as well, on the
// wrappers between the page and the sheet's pane (SGRGlass.m's clearListPaint takes the views below the page).
static void clearOpaqueAbove(UIView *view) {
    UIView *pane = SGRSheetPaneOf(view);
    if (!pane) return;
    if (sg_saveInSheet != pane) sg_saveInSheet = pane;
    for (UIView *v = view; v && v != pane; v = v.superview) {
        clearOpaque(v);
        if (!SGKeepsColor(v) && v.layer.backgroundColor && CGColorGetAlpha(v.layer.backgroundColor) > 0.05) v.backgroundColor = UIColor.clearColor;
    }
}

// Glass is the mod's own: a visual effect view or a view of ours (SGLegacyGlassView and its body, rim and dim).
static BOOL isGlass(UIView *view) {
    return [view isKindOfClass:UIVisualEffectView.class] || [NSStringFromClass(view.class) hasPrefix:@"SG"];
}

// Every view below `view`, whatever its width: the opaque flag and a page-black fill on narrow views inside a row
// draw black over the glass too. Glass is skipped, its own dim is black on purpose.
static void clearOpaqueBelow(UIView *view, int depth) {
    if (depth > 24 || isGlass(view)) return;
    clearOpaque(view);
    if (!SGKeepsColor(view) && SGIsBaseSurface(view.layer.backgroundColor)) view.backgroundColor = UIColor.clearColor;
    for (UIView *sub in view.subviews) clearOpaqueBelow(sub, depth + 1);
}

static void clearSaveInPaint(UIView *view) {
    UIView *sheet = sgr_sheetChromeRoot;
    if (view && sheet) SGRClearSheetCellPaint(view, sheet);
    if (view) {
        clearOpaqueAbove(view);
        clearOpaqueBelow(view, 0);
        clearOpaque(SGRSheetPaneOf(view));   // clearOpaqueAbove stops below the pane
    }
}

// Spotify marks Save in's views opaque on every layout, so the flag is kept clear as it is written (as SGRRepaint.x
// does the queue's grey fill), for every view inside this sheet.
static BOOL inSaveIn(UIView *view) {
    UIView *sheet = sg_saveInSheet;
    return sheet && view.window && SGIsInside(view, sheet);
}

%group SGRSaveInOpaque
%hook CALayer
- (void)setOpaque:(BOOL)opaque {
    if (opaque && sg_saveInSheet) {
        UIView *view = (UIView *)self.delegate;
        if ([view isKindOfClass:UIView.class] && view.layer == self && !isGlass(view) && !isGlass(view.superview) && inSaveIn(view)) opaque = NO;
    }
    %orig(opaque);
}
%end
%end

// UIKit gives a sheet back its shadow as it moves between detents; a glassed sheet's is kept off (SGRSheetShadowHeld).
%group SGRSheetShadow
%hook CALayer
- (void)setShadowOpacity:(float)opacity {
    if (opacity > 0 && SGRSheetShadowHeld(self)) opacity = 0;
    %orig(opacity);
}
%end
%end

// The page's own views (ATPMainView, and the strip under the list that holds Done) are repainted on every layout: the
// paint, the opaque flag and the fade behind the button go each time, as in the queue (QueueGlass.x).
static void clearSaveInView(UIView *view) {
    if (view.bounds.size.width < 1) return;
    CGColorRef paint = view.layer.backgroundColor;
    if (paint && CGColorGetAlpha(paint) > 0.05) view.backgroundColor = UIColor.clearColor;
    clearOpaque(view);
    if ([view.layer isKindOfClass:CAGradientLayer.class]) {
        CAGradientLayer *gradient = (CAGradientLayer *)view.layer;
        if (gradient.colors) gradient.colors = nil;
    }
    for (CALayer *layer in view.layer.sublayers) {
        if ([layer isKindOfClass:CAGradientLayer.class] && !layer.hidden) layer.hidden = YES;
    }
    clearOpaqueAbove(view);
}

// Each playlist row of Save in (Encore's ListRow, id=Playlist.Row.AddToPlaylist) draws its own fill as a shape layer the
// size of the row, under the row's views: not a background colour, so no clearing of paint reached it, and the rows, one
// under the next, covered the whole list in black over the glass (a CAShapeLayer 390x64 in
// every row, and a second one inset by 4 at opacity 0, the press highlight, which stays).
static void clearSaveInRow(UIView *row) {
    if (![row.accessibilityIdentifier isEqualToString:@"Playlist.Row.AddToPlaylist"] || !SGRSheetPaneOf(row)) return;
    CGRect bounds = row.layer.bounds;
    for (CALayer *layer in row.layer.sublayers) {
        if (![layer isKindOfClass:CAShapeLayer.class] || !CGRectEqualToRect(layer.frame, bounds)) continue;
        CAShapeLayer *fill = (CAShapeLayer *)layer;
        if (fill.fillColor && CGColorGetAlpha(fill.fillColor) > 0) fill.fillColor = UIColor.clearColor.CGColor;
    }
}

static void chrome(UIViewController *sheet) {
    UIViewController *content = contentIn(sheet, 0);
    UIView *root = content.viewIfLoaded;
    if (root) {
        SGRGlassSheetChrome(root);
        if ([NSStringFromClass(content.class) containsString:@"PlaylistCuration_AddToPlaylistImpl"]) clearSaveInPaint(root);
        return;
    }
    // The content is not in yet: while a loading page is in the sheet the pane goes in anyway, so no grey shows.
    if (loadingIn(sheet, 0)) {
        UIView *pane = SGRFindByIdentifier(sheet.viewIfLoaded, @"sheet-view", &kPendingPaneKey);
        if (pane) {
            SGRGlassSheetChrome(pane);
            clearSaveInPaint(pane);
        }
    }
}

#pragma mark - the share menu and the listening modes picker

// A view of the class whose name ends in `suffix`, near the top of the controller's view.
static UIView *sheetNamed(UIView *root, NSString *suffix, int depth) {
    if (!root || depth > 4) return nil;
    if ([NSStringFromClass(root.class) hasSuffix:suffix]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = sheetNamed(sub, suffix, depth + 1);
        if (found) return found;
    }
    return nil;
}

static void glassNamed(UIViewController *controller, NSString *suffix) {
    UIView *sheet = sheetNamed(controller.viewIfLoaded, suffix, 0);
    if (sheet && sheet.bounds.size.width > 1) SGRGlassSheetView(sheet);
}

static void pickerChrome(UIViewController *controller) {
    glassNamed(controller, @"PlayModePickerView");
}

#pragma mark - the library's Sort by

// The Recents button opens SPTSortingFilteringPickerViewController as a card under its own presentation
// controller. The same picker inside a Navigation sheet (a playlist's, Liked Songs') already has the sheet's pane,
// and a second one would lay glass inside glass.
static void sortChrome(UIViewController *controller) {
    if (SGRSheetPaneOf(controller.viewIfLoaded)) return;
    UIPresentationController *presentation = controller.presentationController;
    if (![NSStringFromClass(presentation.class) isEqualToString:@"SPTSortingFilteringPresentationController"]) return;
    UIView *card = presentation.presentedView;
    if (card.bounds.size.width > 1) SGRGlassSheetView(card);
}

#pragma mark - the podcast speed popup

// PodcastPlaybackSpeed_UIImpl.PlaybackSpeedView has a strip beside it with the grabber and Spotify's Done button;
// Done goes (alpha, since a hidden Encore view can crash its stack), the swipe and the dimmed area close the
// popup. The round speed buttons are glass circles.
static char kDoneKey;

static void hideDone(UIView *sheet) {
    UIView *host = sheet.superview;
    for (UIView *strip in host.subviews) {
        if (strip == sheet || object_getClass(strip) != UIView.class) continue;
        for (UIView *sub in strip.subviews) {
            if (![sub.accessibilityLabel isEqualToString:@"Done"]) continue;
            if (sub.alpha != 0) sub.alpha = 0;
            sub.userInteractionEnabled = NO;
            objc_setAssociatedObject(strip, &kDoneKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
}

static void speedChrome(UIViewController *controller) {
    UIView *sheet = sheetNamed(controller.viewIfLoaded, @"PlaybackSpeedView", 0);
    if (!sheet || sheet.bounds.size.width < 1) return;
    SGRGlassSheetView(sheet);
    hideDone(sheet);
}

// The buttons: a glass circle inside each, and the translucent white Spotify fills them with taken off.
static char kRoundGlassKey;

%group SGRSpeedButtons
%hook SGRRoundButton
- (void)setBackgroundColor:(UIColor *)color {
    %orig(SGIsFaintWhite(color.CGColor) ? UIColor.clearColor : color);
}

- (void)layoutSubviews {
    %orig;
    UIView *button = (UIView *)self;
    if (button.bounds.size.width < 1) return;
    if (SGIsFaintWhite(button.layer.backgroundColor)) button.backgroundColor = UIColor.clearColor;
    SGRGlassInside(button, &kRoundGlassKey, MIN(button.bounds.size.width, button.bounds.size.height));
}
%end
%end

#pragma mark - Report a problem, and Rate show

// Transcript_ReadAlongImpl.ReportReadAlongView: the controller's own view is the pane; its layer mask of Spotify's
// corners would cut the glass, so it goes.
static void reportChrome(UIViewController *controller) {
    UIView *sheet = controller.viewIfLoaded;
    if (!sheet || sheet.bounds.size.width < 1) return;
    if (sheet.layer.mask) sheet.layer.mask = nil;
    SGRGlassSheetView(sheet);
}

// Ratings_CommonImpl's Rate show page, a page sheet: the page loader's view around the controller's is the pane.
// The footer's fade to #121212 would lay a dark bar over the glass, so the gradient is concealed.
static void rateChrome(UIViewController *controller) {
    UIView *pane = controller.viewIfLoaded.superview;
    if (!pane || pane.bounds.size.width < 300) return;
    SGRGlassSheetView(pane);
    SGForEachView(pane, ^(UIView *view) {
        if (![NSStringFromClass(view.class) hasSuffix:@"GradientView"] || view.layer.hidden) return;
        view.layer.hidden = YES;
        if (!view.layer.mask) view.layer.mask = [CALayer layer];
    });
}

// The Rate page is added to the sheet's page loader once it has loaded, so until then the pane is Spotify's #121212.
// As Save in does (chrome, loadingIn), the pane goes in while the spinner shows. A page sheet whose loader holds
// anything but the spinner and the Rate page is left alone.
static BOOL isPageSheet(UIViewController *controller) {
    UIPresentationController *presentation = controller.navigationController.presentationController ?: controller.presentationController;
    Class pageSheet = NSClassFromString(@"_UIPageSheetPresentationController");
    return pageSheet && [presentation isKindOfClass:pageSheet];
}

// Loading, or holding the Rate page: no child of the loader but the spinner, or the one of Ratings_CommonImpl.
static BOOL loaderIsRate(UIViewController *loader) {
    for (UIViewController *child in loader.childViewControllers) {
        NSString *name = NSStringFromClass(child.class);
        if ([name containsString:@"Ratings_CommonImpl"]) return YES;
        if (![name containsString:@"SpinnerLoadingView"]) return NO;
    }
    return YES;
}

// Whether the sheet was opened over a profile page: Edit profile (ProfileEdit.x) opens on the same loader and spinner
// and stays black, so the page it was opened from is the only tell.
static BOOL underneathIsProfile(UIViewController *controller, int depth) {
    if (!controller || depth > 8) return NO;
    if ([NSStringFromClass(controller.class) containsString:@"Profile_CommonImpl"]) return YES;
    for (UIViewController *child in controller.childViewControllers) {
        if (underneathIsProfile(child, depth + 1)) return YES;
    }
    return NO;
}

static BOOL openedFromProfile(UIViewController *loader) {
    UIViewController *under = loader.navigationController.presentingViewController ?: loader.presentingViewController;
    return underneathIsProfile(under, 0);
}

static void loaderChrome(UIViewController *loader) {
    UIView *pane = loader.viewIfLoaded;
    if (!pane || pane.bounds.size.width < 300 || !isPageSheet(loader) || !loaderIsRate(loader)) return;
    if (openedFromProfile(loader)) return;
    // The whole app is presented as a page sheet too, and a page sheet is never as tall as the screen.
    if (pane.bounds.size.height >= UIScreen.mainScreen.bounds.size.height - 1) return;
    if (pane.layer.mask) pane.layer.mask = nil;
    SGRGlassSheetView(pane);
}

#pragma mark - Save in, from the page's own controller

// The page's own controller is passed over too: it is the first to know the content is in.
static void saveInChrome(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    SGRGlassSheetChrome(view);
    clearSaveInPaint(view);
}
#pragma mark - Save in's find bar

// The find field and Sort button over Save in's playlists become glass as the playlist page's find bar does
// (PlaylistHeader.x). The bar is in the page twice (scrolling with the list, and shown while searching), so each is
// looked for from its own root.
static void glassFindBar(UIView *root) {
    static char kFieldKey, kButtonKey, kFieldGlassKey, kButtonGlassKey;
    SGRGlassFlatBox(SGRFindByIdentifier(root, @"Components.Header.UI.Toolbar.SearchField", &kFieldKey), &kFieldGlassKey, NO);
    SGRGlassFlatBox(SGRFindByIdentifier(root, @"Components.Header.UI.Toolbar.ButtonContainer", &kButtonKey), &kButtonGlassKey, NO);
}

// The list's own pass runs on every scroll as well, and the bar is made after the page's first layout.
%group SGRSaveInList
%hook UITableView
- (void)layoutSubviews {
    %orig;
    UIView *list = (UIView *)self;
    if (![list.accessibilityIdentifier isEqualToString:@"AddToPlaylistTableView"]) return;
    glassFindBar(list);
    glassFindBar(list.superview);
    clearOpaque(list);
    if (list.layer.backgroundColor && CGColorGetAlpha(list.layer.backgroundColor) > 0.05) list.backgroundColor = UIColor.clearColor;
    clearOpaqueAbove(list);
}
%end
%end

#pragma mark - the Connect device menu

// A device's menu in the Connect picker (Log out and the like) is pushed onto the picker's stack inside its sheet,
// which does not lay out on a push, so as with Save in the page's own controller puts the pane in and clears the paint.
static void connectMenuChrome(UIViewController *controller) {
    UIView *view = controller.viewIfLoaded;
    if (!view || view.bounds.size.width < 1) return;
    SGRGlassSheetChrome(view);
    clearSaveInPaint(view);
}

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    %init(SGRSheetShadow);
    SGRPassSwiftController(@"NavigationUI_SheetImpl", @"ContainerViewController", ^(UIViewController *c) { chrome(c); });
    SGRPassSwiftController(@"Connect_ContextMenuPageImpl", @"ContextMenuViewController", ^(UIViewController *c) { connectMenuChrome(c); });
    SGRPassSwiftController(@"SmartShuffle_CoreImpl", @"PlayModePickerViewController", ^(UIViewController *c) { pickerChrome(c); });
    SGRPassController(NSClassFromString(@"SPTSortingFilteringPickerViewController"), ^(UIViewController *c) { sortChrome(c); });
    SGRPassSwiftController(@"PodcastPlaybackSpeed_UIImpl", @"PlaybackSpeedViewController", ^(UIViewController *c) { speedChrome(c); });
    SGRPassSwiftController(@"Transcript_ReadAlongImpl", @"ReportReadAlongViewController", ^(UIViewController *c) { reportChrome(c); });
    SGRPassSwiftController(@"Ratings_CommonImpl", @"RatingsAndReviewsRatePodcastViewController", ^(UIViewController *c) { rateChrome(c); });
    SGRPassSwiftController(@"Tome_PageLoaderViewImpl", @"SPTMusicClientPageLoaderView", ^(UIViewController *c) { loaderChrome(c); });
    SGRPassSwiftController(@"Share_MenuImpl", @"ShareMenuViewControllerV2", ^(UIViewController *c) { glassNamed(c, @"ShareMenuSheetView"); });
    Class saveIn = SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPContainerViewController");
    if (saveIn) {
        SGRPassController(saveIn, ^(UIViewController *c) { saveInChrome(c); });
        %init(SGRSaveInList);
        %init(SGRSaveInOpaque);
    }
    SGRPassView(SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPMainView"), ^(UIView *v) { clearSaveInView(v); });
    SGRPassView(SGRSwiftClass(@"PlaylistCuration_AddToPlaylistImpl", @"ATPDoneButtonView"), ^(UIView *v) { clearSaveInView(v); });
    SGRPassView(NSClassFromString(@"_TtCE16Encore_LayoutKitO16EncoreFoundation6Encore7ListRow"), ^(UIView *v) { clearSaveInRow(v); });
    Class round = NSClassFromString(@"_TtCO27PodcastPlaybackSpeed_ECMKit26PodcastDialogPlaybackSpeed11RoundButton");
    if (round) %init(SGRSpeedButtons, SGRRoundButton = round);
}
