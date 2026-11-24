// How long a toast stays is Spotify's own timer (presentationTimer of SPTSnackbarInternalPresenterImplementation, 9.1.78),
// scheduled in the run loop's default mode: while a finger held the screen (a list being dragged, the run loop then in
// UITrackingRunLoopMode) it did not fire, and the toast stayed until the finger was lifted. It is put in the common modes
// as well, so the toast goes when its time is up whatever the finger does. Spotify's bug in either look and on every iOS.
// Spotify sets the timer through its setter (the toast leaves under a held finger on the phone); were it set another way,
// nothing here runs and the toast waits for the finger, as before.
#import "Core/SGCore.h"
#import <objc/runtime.h>

%hook SPTSnackbarInternalPresenterImplementation
- (void)setPresentationTimer:(NSTimer *)timer {
    %orig;
    if (timer.isValid) [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
}
%end

%ctor {
    Class presenter = objc_getClass("SPTSnackbarInternalPresenterImplementation");
    if (!presenter || !class_getInstanceMethod(presenter, @selector(setPresentationTimer:))) {
        SGLog(@"toasts: Spotify's toast timer was not found, a toast still waits for a held finger to lift");
        return;
    }
    %init;
}
