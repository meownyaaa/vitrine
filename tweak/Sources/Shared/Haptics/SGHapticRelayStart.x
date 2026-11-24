// Asks for Vitrine Addon as Spotify starts on a jailbroken phone, on its own: Music Haptics asks too, but only once it
// has hooked Spotify's output, and the add-on also draws the lock screen's large cover, which has nothing to do with it.
#import "Core/SGCore.h"
#import "Core/SGRebind.h"
#import "SGHapticRelay.h"

%ctor {
    if (!SGJailbroken()) return;
    dispatch_async(dispatch_get_main_queue(), ^{ SGHapticRelayAsk(); });
}
