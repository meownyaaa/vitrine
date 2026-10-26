// Batch translation of albums and playlists from the ellipsis menu.
#import <UIKit/UIKit.h>

@class UIViewController;

typedef NS_ENUM(NSInteger, SGBatchTranslationEngine) {
    SGBatchTranslationEngineAI,
    SGBatchTranslationEngineOnDevice,
    SGBatchTranslationEngineAppleIntelligence
};

// Starts batch translation for the given album or playlist URI.
void SGBatchTranslateURI(NSString *uri, SGBatchTranslationEngine engine, UIWindow *window);

// Installs the batch translation row into the context menu sheet's table footer.
void SGBatchTranslationInstall(UIViewController *menu);

// Records the source button/view that was tapped to open the menu.
void SGBatchTranslationMarkSource(UIView *view);

// Whether a batch translation is currently running.
BOOL SGBatchTranslationIsRunning(void);
