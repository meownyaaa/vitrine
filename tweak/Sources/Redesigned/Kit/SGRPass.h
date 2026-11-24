// Passes over Spotify's controllers and views, again after a delay: what it builds or paints back after the first
// layout (a sheet's rows, its grey) is caught on a later pass.
//
// Threading: main thread only.
#import <UIKit/UIKit.h>

typedef void (^SGRControllerPass)(UIViewController *controller);

// The delays SGRPassController repeats a pass after, in seconds.
#define SGRSettleDelays @[@0.0, @0.25, @0.6]

// Runs `pass` on the controller after each delay (seconds), while it lives.
void SGRRepeatPass(UIViewController *controller, NSArray<NSNumber *> *delays, SGRControllerPass pass);

// Runs `pass` on the view after each delay (seconds), while it is in a window.
void SGRRepeatViewPass(UIView *view, NSArray<NSNumber *> *delays, void (^pass)(UIView *view));

// Runs `follow` with `scroll` whenever its content offset changes, by an observer that lives as long as `scroll` does.
// One per `scroll` and `key`: a call that finds one in place does nothing.
void SGRFollowOffset(UIScrollView *scroll, const void *key, void (^follow)(UIScrollView *scroll));

// Runs `pass` on every controller of `cls` (and its subclasses) as it will appear, after each of its layouts, and
// as it has appeared and after SGRSettleDelays. Hooks the class's own methods, so it runs whether or not a
// subclass calls super. Nothing when `cls` is nil.
void SGRPassController(Class cls, SGRControllerPass pass);

// Runs `going` on every controller of `cls` (and its subclasses) as it will disappear.
void SGRPassControllerGoing(Class cls, SGRControllerPass going);

// Runs `pass` on every view of `cls` (and its subclasses) after each of its layouts and as it moves to or out of a
// window. Hooks the class's own methods, as SGRPassController does. Nothing when `cls` is nil.
void SGRPassView(Class cls, void (^pass)(UIView *view));

// The same for each class named, by its runtime name; a name the app does not have is logged.
void SGRPassControllersNamed(NSArray<NSString *> *names, SGRControllerPass pass);

// The same for a Swift class by module and name (SGRSwiftClass); logged when the app does not have it.
void SGRPassSwiftController(NSString *module, NSString *name, SGRControllerPass pass);
