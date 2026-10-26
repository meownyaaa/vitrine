// Spotify's App Groups and its extension-credentials keychain group, redirected into groups the
// sideload signature really has.
//
// The main app hands the home screen widget everything it shows through UserDefaults suites named
// group.com.spotify.client.widget, .widget.data and .widget.lifecycle. Those groups belong to
// Spotify's team, so a re-signed IPA never has them: its profile carries groups of its own
// (group.<hash>.N from a paid certificate service, something else from AltStore), each process
// then gets a private, empty suite, and the widget stays on its "Open Spotify and play" placeholder.
//
// This dylib is loaded by Spotify and its Widget, Intents and NotificationService extensions
// (scripts/pipeline.sh adds the load command to each extension). In each it maps every group.*
// identifier the process is not entitled to onto a folder inside one group it is entitled to, the
// same folder in every process, so the suites and container files meet again. It is plain runtime
// swizzling, no Substrate, because the extensions carry nothing else of the tweak.
//
// Keychain: the app saves the login the Siri and notification extensions sign in with under
// the access group 8W66MEA7DD.com.spotify.client.extension-credentials, built from Spotify's team id
// in SpotifyShared. A re-signed process is not entitled to it (errSecMissingEntitlement), so Siri asks
// to verify the account (issue #60). Every SPTKeychainManager call builds its query in
// getBaseDictionaryForDomain:key:accessGroup:accessAttr:synchronizable:, and there that group is
// swapped for one the signature has, the same in the app and every extension.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <os/log.h>

typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

@interface NSUserDefaults (SGAppGroups)
- (instancetype)_initWithSuiteName:(NSString *)suiteName container:(NSURL *)container;
@end

static os_log_t sLog;
static NSArray<NSString *> *sEntitled;
static NSURL *(*sOrigContainerURL)(id, SEL, NSString *);
static id (*sOrigInitWithSuiteName)(id, SEL, NSString *);

static NSString *const kCredentialsGroupSuffix = @".com.spotify.client.extension-credentials";
static NSArray<NSString *> *sKeychainEntitled;
static NSString *sKeychainGroup;
static id (*sOrigBaseDictionary)(id, SEL, id, id, NSString *, id, BOOL);

static NSArray<NSString *> *EntitledGroups(CFStringRef entitlement) {
  SecTaskRef task = SecTaskCreateFromSelf(NULL);
  if (!task) return @[];
  CFTypeRef value = SecTaskCopyValueForEntitlement(task, entitlement, NULL);
  CFRelease(task);
  NSArray *groups = CFBridgingRelease(value);
  if (![groups isKindOfClass:NSArray.class]) return @[];
  // Sorted, so the app and its extensions pick the same host group whatever order the signer wrote.
  return [groups sortedArrayUsingSelector:@selector(compare:)];
}

// The folder that stands in for `group`, or nil when the process may use the group as it is (or
// has no group at all to put it in).
static NSURL *RedirectedContainer(NSString *group) {
  if (![group isKindOfClass:NSString.class] || ![group hasPrefix:@"group."]) return nil;
  if ([sEntitled containsObject:group]) return nil;
  NSFileManager *fm = NSFileManager.defaultManager;
  // AltStore and SideStore register the original group with the team appended, which is the
  // real thing already.
  NSString *prefix = [group stringByAppendingString:@"."];
  for (NSString *entitled in sEntitled) {
    if ([entitled hasPrefix:prefix]) return sOrigContainerURL(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:), entitled);
  }
  for (NSString *entitled in sEntitled) {
    NSURL *host = sOrigContainerURL(fm, @selector(containerURLForSecurityApplicationGroupIdentifier:), entitled);
    if (!host) continue;
    NSURL *url = [host URLByAppendingPathComponent:group isDirectory:YES];
    [fm createDirectoryAtURL:[url URLByAppendingPathComponent:@"Library/Preferences" isDirectory:YES]
        withIntermediateDirectories:YES attributes:nil error:NULL];
    return url;
  }
  return nil;
}

static NSURL *SGContainerURL(id self, SEL _cmd, NSString *group) {
  NSURL *url = RedirectedContainer(group);
  return url ?: sOrigContainerURL(self, _cmd, group);
}

// initWithSuiteName: is the public door every UserDefaults(suiteName:) goes through; the container
// variant is what App Group suites resolve to inside Foundation, so it is handed the stand-in.
static id SGInitWithSuiteName(NSUserDefaults *self, SEL _cmd, NSString *suite) {
  NSURL *url = RedirectedContainer(suite);
  if (url && [self respondsToSelector:@selector(_initWithSuiteName:container:)]) {
    os_log(sLog, "[spotifyglass] appgroups: %{public}@ -> %{public}@", suite, url.path);
    return [self _initWithSuiteName:suite container:url];
  }
  return sOrigInitWithSuiteName(self, _cmd, suite);
}

// The group the extension credentials go in: the signer's own copy of Spotify's (AltStore re-teams
// it), else the first entitled one in sorted order. A TEAM.* entry is used as it is, not expanded, so it is
// allowed whether or not securityd matches the wildcard. com.apple.token is CryptoTokenKit's.
static NSString *CredentialsGroup(void) {
  for (NSString *group in sKeychainEntitled) {
    if ([group hasSuffix:kCredentialsGroupSuffix]) return group;
  }
  for (NSString *group in sKeychainEntitled) {
    if (![group isEqualToString:@"com.apple.token"]) return group;
  }
  return nil;
}

static id SGBaseDictionary(id self, SEL _cmd, id domain, id key, NSString *group, id attr, BOOL sync) {
  // Only Spotify's extension credentials group, and only when the signature lacks it: TrollStore keeps
  // Spotify's entitlements and is left alone, and the Watch groups never match the suffix.
  if ([group isKindOfClass:NSString.class] && [group hasSuffix:kCredentialsGroupSuffix] && ![sKeychainEntitled containsObject:group]) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ os_log(sLog, "[spotifyglass] keychain: %{public}@ -> %{public}@", group, sKeychainGroup); });
    group = sKeychainGroup;
  }
  return sOrigBaseDictionary(self, _cmd, domain, key, group, attr, sync);
}

// SpotifyShared is a direct dependency of the app and of every extension, so its classes are
// registered before this constructor runs.
static void InstallKeychainHook(void) {
  sKeychainEntitled = EntitledGroups(CFSTR("keychain-access-groups"));
  sKeychainGroup = CredentialsGroup();
  os_log(sLog, "[spotifyglass] keychain: entitled to %{public}@, credentials in %{public}@",
         [sKeychainEntitled componentsJoinedByString:@", "], sKeychainGroup);
  if (!sKeychainGroup) return;
  Method m = class_getInstanceMethod(objc_getClass("SPTKeychainManagerImpl"),
                                     @selector(getBaseDictionaryForDomain:key:accessGroup:accessAttr:synchronizable:));
  if (!m) {
    os_log(sLog, "[spotifyglass] keychain: no -[SPTKeychainManagerImpl getBaseDictionaryForDomain:...]");
    return;
  }
  sOrigBaseDictionary = (void *)method_setImplementation(m, (IMP)SGBaseDictionary);
}

__attribute__((constructor)) static void SGAppGroupsInit(void) {
  sLog = os_log_create("spotifyglass", "appgroups");
  InstallKeychainHook();
  sEntitled = EntitledGroups(CFSTR("com.apple.security.application-groups"));
  os_log(sLog, "[spotifyglass] appgroups: %{public}@ entitled to %{public}@",
         NSBundle.mainBundle.bundleIdentifier, [sEntitled componentsJoinedByString:@", "]);
  if (sEntitled.count == 0) return;

  Method m = class_getInstanceMethod(NSFileManager.class, @selector(containerURLForSecurityApplicationGroupIdentifier:));
  sOrigContainerURL = (void *)method_setImplementation(m, (IMP)SGContainerURL);
  m = class_getInstanceMethod(NSUserDefaults.class, @selector(initWithSuiteName:));
  sOrigInitWithSuiteName = (void *)method_setImplementation(m, (IMP)SGInitWithSuiteName);
}
