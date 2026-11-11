// Mirage preferences: NSUserDefaults keys under "mirage.", read live.
#import <UIKit/UIKit.h>

typedef NS_OPTIONS(NSUInteger, MRGScreen) {
    MRGScreenHome       = 1 << 0,
    MRGScreenNowPlaying = 1 << 1,
    MRGScreenLibrary    = 1 << 2,
    MRGScreenEverywhere = 1 << 3,
    MRGScreenDrawer     = 1 << 4,   // the side drawer, opted in on its own (Everywhere skips it)
};

typedef NS_ENUM(NSInteger, MRGScaleMode) {
    MRGScaleFill = 0,    // aspect fill (crop)
    MRGScaleFit = 1,     // aspect fit (letterbox)
    MRGScaleStretch = 2, // stretch to the screen
};

typedef NS_ENUM(NSInteger, MRGMediaKind) {
    MRGMediaNone = 0,
    MRGMediaImage = 1,
    MRGMediaVideo = 2, // MP4/MOV, and GIFs converted to MP4 at import
};

extern NSString *const MRGSettingsChangedNotification;

BOOL MRGBackgroundEnabled(void);
void MRGSetBackgroundEnabled(BOOL on);
double MRGBlur(void);          // 0...1
void MRGSetBlur(double v);
double MRGDim(void);           // 0...0.9
void MRGSetDim(double v);
MRGScaleMode MRGScale(void);
void MRGSetScale(MRGScaleMode m);
MRGScreen MRGScreens(void);
void MRGSetScreens(MRGScreen s);
BOOL MRGClearPages(void);      // make Spotify's own full-screen page fills transparent
void MRGSetClearPages(BOOL on);
BOOL MRGWantsScreen(MRGScreen s);
BOOL MRGProfileGlow(void);     // profile page: the dominant color as a glow around the picture, not page-wide
void MRGSetProfileGlow(BOOL on);
typedef NS_ENUM(NSInteger, MRGTopFadeMode) {
    MRGTopFadeOff = 0,    // Spotify's dark scrim behind the status bar and header gone
    MRGTopFadeSoft = 1,   // a third of it (default)
    MRGTopFadeFull = 2,   // Spotify's own, untouched
};
MRGTopFadeMode MRGTopFade(void);
void MRGSetTopFade(MRGTopFadeMode m);

// Media in Documents/Mirage/.
MRGMediaKind MRGCurrentKind(void);
NSURL *MRGCurrentMediaURL(void);
NSURL *MRGMediaDirectory(void);
void MRGSetCurrentMedia(NSURL *fileInMediaDirectory, MRGMediaKind kind);
void MRGRemoveCurrentMedia(void);

void MRGPostChange(void);
