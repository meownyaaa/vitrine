// The DJ under Spoof Premium: Spotify offers it only where its playlist (spotify:playlist:37i9dQZF1EYkqdzj48dyYq)
// loads, which the checker below tries first. Answering yes shows the DJ in other countries too; whether it plays
// there is the server's call.
#import "Core/SGCore.h"
#import "AdBlock.h"

%hook _TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl
- (void)isEligibleForDJWithCompletion:(void (^)(BOOL))completion {
    if (completion) completion(YES);
}
%end

%ctor {
    if (!SGHidden(SGKeyFakePremium)) return;
    %init;
    SGRequireClasses(@[@"_TtC16Endless_AIDJImpl26AIDJEligibilityCheckerImpl"]);
}
