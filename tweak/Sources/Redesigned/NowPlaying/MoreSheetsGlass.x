// Redesign, iOS < 26: glass for Spotify's bottom sheets that need nothing but the pane. Each is hosted by its own
// controller in the same Navigation sheet (id=sheet-view, #1F1F1F) as the queue, and SGRGlassSheetChrome puts the
// queue's pane behind it and clears the grey of the wrappers and rows. A controller whose view is not inside a
// "sheet-view" is left as it is (SGRGlassSheetChrome returns at once).
//
// The sleep timer has one more #1F1F1F view over the whole of it (id=sleep_timer_options), cleared with the rest.
// The Connect volume sheet for another device is a SwiftUI hosting controller with no BottomSheetViewController;
// SGRSheetPopups.x gives that one its pane by the hosted controller's name.
#import "Core/SGCore.h"
#import "Redesigned/Kit/SGRKit.h"

%ctor {
    if (!SGRedesignedUI() || !SGBelowiOS26()) return;
    SGRPassControllersNamed(@[
        @"_TtC30PlaybackControl_SleepTimerImpl21OptionsViewController",
        @"_TtC20Connect_VolumeUXImpl25BottomSheetViewController",
        @"_TtC32Artist_ArtistAttributionPageImpl42ArtistAttributionBottomSheetViewController",
        @"_TtC46MusicPlaybackSpeed_SpeedControlBottomSheetImpl37SpeedControlBottomSheetViewController",
        @"_TtC34NowPlaying_ContextMenuSettingsImpl27AudioSettingsViewController",
        @"_TtC34NowPlaying_ContextMenuSettingsImpl27VideoSettingsViewController",
        @"_TtC32EpisodeChapters_ChaptersListImpl30ChaptersListViewControllerImpl",
        @"_TtC37Audiobook_ChaptersBottomSheetPageImpl33ChaptersBottomSheetViewController",
        @"_TtC20Lyrics_SelectionImpl26LyricsPickerViewController",
        @"_TtC29Lyrics_LanguagePickerPageImpl39TranslationLanguagePickerViewController",
        @"_TtC41Reporting_ReportActionContextMenuItemImpl29ReportSheetPageViewController",
        @"_TtC26NavigationUI_InfoSheetImpl23InfoSheetViewController",
        @"_TtC33AlignedCuration_FirstSavePageImpl28FirstSaveSheetViewController",
        @"_TtC39Collection_SnoozeRecommendationPageImpl34SnoozeRecommendationViewController",
        @"_TtC29MarkAsPlayed_MarkAsPlayedImpl26MarkAsPlayedViewController",
        @"_TtC46PlaylistCollaboration_PlaylistInviteDialogImpl34PlaylistInviteDialogViewController",
        @"_TtC33Betamax_AudioLanguageSelectorImpl35AudioLanguageSelectorViewController",
        @"_TtC21Betamax_SubtitlesImpl32SubtitlesSelectionViewController",
    ], ^(UIViewController *controller) {
        UIView *root = controller.viewIfLoaded;
        if (root) SGRGlassSheetChrome(root);
    });
}
