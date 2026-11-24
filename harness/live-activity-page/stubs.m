// The activity's and the sleep timer's side of the page (LiveActivity.x and SleepTimer.m in the tweak): the switch is
// logged, the fade's names are the tweak's.
#import "Core/SGCore.h"
#import "Shared/LiveActivity/LiveActivity.h"
#import "Shared/Player/SleepTimer.h"

void SGSetLiveActivityEnabled(BOOL on) {
    NSLog(@"[harness] the Live Activity is switched %@", on ? @"on" : @"off");
}

NSArray<NSString *> *SGSleepTimerFadeNames(void) {
    return @[@"Off", @"10 s", @"30 s", @"1 minute", @"2 minutes"];
}

NSInteger SGSleepTimerFadeChoice(void) {
    return SGInt(SGKeySleepTimerFade, 1);
}

// Redesigned/Pages/ModPageBar.x, the bar below iOS 26 over a page of the mod's on Spotify's stack: none here.
void SGDressPageBar(UIViewController *page) {}
void SGUndressPageBar(UIViewController *page) {}
void SGPlacePageBar(UIViewController *page) {}
