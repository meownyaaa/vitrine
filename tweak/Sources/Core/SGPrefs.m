#import "SGPrefs.h"
#import <os/lock.h>

// Hooks read switches on every layout and frame, and a defaults read takes CFPreferences' lock: each key's
// stored value (NSNull for none) is kept after its first read and all are dropped whenever the defaults
// change, so a write still applies to the next read.
static os_unfair_lock memoLock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary<NSString *, id> *memo;
static NSUInteger memoGeneration;
// Set on the thread inside SGPrefsWriteUnmemoized, whose write changes nothing the memo holds.
static _Thread_local BOOL writingUnmemoized;

void SGPrefsChanged(void) {
    if (writingUnmemoized) return;
    os_unfair_lock_lock(&memoLock);
    [memo removeAllObjects];
    memoGeneration++;
    os_unfair_lock_unlock(&memoLock);
}

static id stored(NSString *key) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        memo = [NSMutableDictionary dictionary];
        // Posted on the writing thread, which a main-queue observer would leave waiting on main.
        [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) { SGPrefsChanged(); }];
    });
    os_unfair_lock_lock(&memoLock);
    id value = memo[key];
    NSUInteger generation = memoGeneration;
    os_unfair_lock_unlock(&memoLock);
    if (value) return value == NSNull.null ? nil : value;
    value = [NSUserDefaults.standardUserDefaults objectForKey:key];
    os_unfair_lock_lock(&memoLock);
    // A write during the read dropped the memo, and the value read may predate it.
    if (generation == memoGeneration) memo[key] = value ?: NSNull.null;
    os_unfair_lock_unlock(&memoLock);
    return value;
}

void SGPrefsWriteUnmemoized(void (^write)(void)) {
    BOOL was = writingUnmemoized;
    writingUnmemoized = YES;
    write();
    writingUnmemoized = was;
}

BOOL SGFlag(NSString *key, BOOL fallback) {
    id value = stored(key);
    if (value) return [value boolValue];
    return fallback && ![stored(SGKeyStock) boolValue];
}

BOOL SGEnabled(NSString *key) {
    return SGFlag(key, YES);
}

BOOL SGHidden(NSString *key) {
    return SGFlag(key, NO);
}

void SGSetEnabled(NSString *key, BOOL on) {
    [NSUserDefaults.standardUserDefaults setBool:on forKey:key];
    SGPrefsChanged();
}

NSInteger SGInt(NSString *key, NSInteger fallback) {
    id value = stored(key);
    return value ? [value integerValue] : fallback;
}

NSString *SGString(NSString *key) {
    id value = stored(key);
    if ([value isKindOfClass:NSString.class]) return value;
    return [value isKindOfClass:NSNumber.class] ? [value stringValue] : nil;
}

NSArray *SGArray(NSString *key) {
    id value = stored(key);
    return [value isKindOfClass:NSArray.class] ? value : nil;
}

void SGSetInt(NSString *key, NSInteger value) {
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:key];
    SGPrefsChanged();
}

NSString *const SGFlagOverridePrefix = @"spotifyglass.flag.";

id SGFlagOverride(NSString *key) {
    return [NSUserDefaults.standardUserDefaults objectForKey:[SGFlagOverridePrefix stringByAppendingString:key]];
}

void SGSetFlagOverride(NSString *key, id value) {
    key = [SGFlagOverridePrefix stringByAppendingString:key];
    if (value) [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
}

void SGMigrateKey(NSString *from, NSString *to) {
    NSUserDefaults *store = NSUserDefaults.standardUserDefaults;
    id value = [store objectForKey:from];
    if (!value || [store objectForKey:to]) return;
    [store setObject:value forKey:to];
    [store removeObjectForKey:from];
}

void SGRestartSpotify(void) {
    [NSUserDefaults.standardUserDefaults synchronize];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ exit(0); });
}
