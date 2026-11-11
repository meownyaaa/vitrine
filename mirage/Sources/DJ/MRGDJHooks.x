// Where Mirage DJ shows up in Spotify: the floating DJ pill on Home (Home_FunkisPageImpl.FunkisViewController,
// the same page MRGBackgrounds.x gives a background), laid out with the page, on or off by its setting.
#import "MRGDJView.h"
#import "MRGPrefs.h"

%hook _TtC19Home_FunkisPageImpl20FunkisViewController
- (void)viewDidLayoutSubviews { %orig; MRGPlaceDJPill(((UIViewController *)self).viewIfLoaded); }
- (void)viewDidAppear:(BOOL)animated { %orig; MRGPlaceDJPill(((UIViewController *)self).viewIfLoaded); }
%end

%ctor {
    if (NSClassFromString(@"_TtC19Home_FunkisPageImpl20FunkisViewController")) %init;
}
