// Redesign, iOS < 26: the system's alert and action sheet, drawn the way Telegram draws its own. Telegram's
// AlertScreen is a 300pt glass card with 35pt corners, a bold 17pt title over 15pt text, and capsule buttons 48pt
// tall: the main one filled with the accent, the rest a 10% white fill, a destructive one red. This reads the
// title, message, text fields and actions off a UIAlertController and shows them that way; the controller itself
// is never put on screen, so its handlers and its text fields work as they always did.
//
// The glass is the redesign's own pane (SGRGlass.h: the legacy glass below iOS 26, the heavy body and the rim of a
// sheet), so an alert matches the queue and the ⋯ menu.
//
// Metrics and colors are ported from Telegram-iOS's AlertComponent (GPLv2); no Telegram code is kept verbatim.
#import <UIKit/UIKit.h>
#import "Settings/SGPageStyle.h"

@interface SGRAlertScreen : UIViewController <SGAlertScreen, UIGestureRecognizerDelegate>

// Whether `alert` can be shown this way: a plain alert or action sheet, not one that carries a content controller
// of its own or an iPad popover, and on an OS where the actions' handlers can be read.
+ (BOOL)canShow:(UIAlertController *)alert;
// Whether this OS keeps the actions' handlers where they can be read: without them no button could do anything,
// and the system's alert stays.
+ (BOOL)handlersReadable;

- (instancetype)initWithAlert:(UIAlertController *)alert;

@end
