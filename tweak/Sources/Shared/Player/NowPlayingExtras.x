// NowPlayingExtras.h says what this is and why it stores nothing of Spotify's.
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <MediaPlayer/MediaPlayer.h>
#import "Core/SGCore.h"
#import "Shared/Haptics/Haptics.h"
#import "Shared/Player/NowPlayingExtras.h"

// Read on whatever thread Spotify sets the info from, written on the main one.
static NSObject *sg_lock;
static NSMutableDictionary<NSString *, NSDictionary *> *sg_extras;  // by owner
static NSMutableDictionary<NSString *, NSString *> *sg_titles;    // by owner
static double sg_elapsed, sg_rate;
static CFAbsoluteTime sg_clockAt;

static void updateCenterClient(MPNowPlayingInfoCenter *center) {
    if (!SGIsLiveContainer()) return;
    NSBundle *host = SGHostBundle();
    NSString *hostID = host.bundleIdentifier;
    if (!hostID.length) return;

    id client = nil;
    if ([center respondsToSelector:@selector(playerPath)]) {
        id playerPath = ((id (*)(id, SEL))objc_msgSend)(center, @selector(playerPath));
        if ([playerPath respondsToSelector:@selector(client)]) {
            client = ((id (*)(id, SEL))objc_msgSend)(playerPath, @selector(client));
        }
    }
    if (!client && [center respondsToSelector:@selector(client)]) {
        client = ((id (*)(id, SEL))objc_msgSend)(center, @selector(client));
    }
    if (client && [client respondsToSelector:@selector(setBundleIdentifier:)]) {
        ((void (*)(id, SEL, id))objc_msgSend)(client, @selector(setBundleIdentifier:), hostID);
    }
}

// `stale` are an owner's old keys: the info the getter gives back can still carry them, and the hook puts
// back only the extras that are current.
static void resend(NSArray *stale) {
    MPNowPlayingInfoCenter *center = MPNowPlayingInfoCenter.defaultCenter;
    NSMutableDictionary *info = [center.nowPlayingInfo mutableCopy];
    if (!info) return;
    [info removeObjectsForKeys:stale];
    @synchronized (sg_lock) {
        if (sg_clockAt > 0) info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(sg_elapsed + sg_rate * (CFAbsoluteTimeGetCurrent() - sg_clockAt));
    }
    center.nowPlayingInfo = info;
}

void SGNowPlayingSetExtras(NSString *owner, NSDictionary *extras, NSString *title) {
    NSDictionary *old;
    @synchronized (sg_lock) {
        old = sg_extras[owner];
        sg_extras[owner] = extras.count ? extras : nil;
        sg_titles[owner] = extras.count ? title : nil;
    }
    if (extras.count) {
        resend(old.allKeys ?: @[]);
        return;
    }
    // Cleared, they are taken off if they are still on: the next track can have the same title, and then
    // the last track's artwork or ISRC rode on its info.
    NSDictionary *info = MPNowPlayingInfoCenter.defaultCenter.nowPlayingInfo;
    for (id key in old) {
        if (![info[key] isEqual:old[key]]) continue;
        resend(old.allKeys);
        return;
    }
}

%hook MPNowPlayingInfoCenter
- (void)setNowPlayingInfo:(NSDictionary *)info {
    updateCenterClient(self);
    NSMutableDictionary *added = nil;
    @synchronized (sg_lock) {
        if (info[MPNowPlayingInfoPropertyElapsedPlaybackTime]) {
            sg_elapsed = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
            // A rate left out runs at 1, as LockScreenLyrics.x reads it.
            NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
            sg_rate = rate ? rate.doubleValue : 1;
            sg_clockAt = CFAbsoluteTimeGetCurrent();
        }
        id title = info[MPMediaItemPropertyTitle];
        for (NSString *owner in sg_extras) {
            if (![title isEqual:sg_titles[owner]]) continue;
            if (!added) added = [NSMutableDictionary dictionary];
            [added addEntriesFromDictionary:sg_extras[owner]];
        }
    }
    if (!added) {
        %orig;
        return;
    }
    NSMutableDictionary *withExtras = [info mutableCopy];
    [withExtras addEntriesFromDictionary:added];
    %orig(withExtras);
}
%end

// Installed only under LiveContainer (%ctor): every other install keeps NSBundle and MediaRemote's clients as they are.
%group SGLiveContainerHooks
%hook NSBundle
- (NSString *)bundleIdentifier {
    if (self == NSBundle.mainBundle) {
        Dl_info info = {0};
        if (dladdr(__builtin_return_address(0), &info) && info.dli_fbase) {
            const char *fname = info.dli_fname;
            if (fname && (strstr(fname, "MediaRemote") ||
                          strstr(fname, "MediaPlayer") ||
                          strstr(fname, "MediaAccessibility") ||
                          strstr(fname, "AVFAudio") ||
                          strstr(fname, "AudioToolbox"))) {
                NSBundle *host = SGHostBundle();
                if (host.bundleIdentifier.length) return host.bundleIdentifier;
            }
        }
    }
    return %orig;
}
%end
%end

%group SGMRClientHooks
%hook MRClient
- (NSString *)bundleIdentifier {
    NSBundle *host = SGHostBundle();
    if (host.bundleIdentifier.length) return host.bundleIdentifier;
    return %orig;
}
%end
%end

%group SGMRNowPlayingClientHooks
%hook MRNowPlayingClient
- (NSString *)bundleIdentifier {
    NSBundle *host = SGHostBundle();
    if (host.bundleIdentifier.length) return host.bundleIdentifier;
    return %orig;
}
%end
%end

%ctor {
    sg_lock = [NSObject new];
    sg_extras = [NSMutableDictionary dictionary];
    sg_titles = [NSMutableDictionary dictionary];
    %init;
    if (!SGIsLiveContainer()) return;
    %init(SGLiveContainerHooks);
    if (objc_getClass("MRClient")) %init(SGMRClientHooks);
    if (objc_getClass("MRNowPlayingClient")) %init(SGMRNowPlayingClientHooks);
}
