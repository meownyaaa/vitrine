#import "MRGKeychain.h"
#import <Security/Security.h>

static NSString *const kService = @"com.x4nzz.mirage.dj";
static NSString *const kAccount = @"api-key";

static NSMutableDictionary *baseQuery(NSString *account) {
    return [@{(id)kSecClass: (id)kSecClassGenericPassword,
              (id)kSecAttrService: kService,
              (id)kSecAttrAccount: account} mutableCopy];
}

// A sideloading signer that leaves out the keychain entitlement makes every keychain call fail
// (errSecMissingEntitlement): the key then goes to a file only this app can read, protected until first unlock.
static NSURL *fallbackFile(NSString *account) {
    NSURL *lib = [NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dir = [lib URLByAppendingPathComponent:@"Mirage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir URLByAppendingPathComponent:[account isEqualToString:kAccount] ? @"dj.key" : [account stringByAppendingString:@".key"]];
}

NSString *MRGKeychainGet(NSString *account) {
    NSMutableDictionary *q = baseQuery(account);
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef out = NULL;
    if (SecItemCopyMatching((CFDictionaryRef)q, &out) != errSecSuccess || !out) {
        NSData *file = [NSData dataWithContentsOfURL:fallbackFile(account)];
        NSString *key = file ? [[NSString alloc] initWithData:file encoding:NSUTF8StringEncoding] : nil;
        return key.length ? key : nil;
    }
    NSData *data = (__bridge_transfer NSData *)out;
    NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return key.length ? key : nil;
}

BOOL MRGKeychainSet(NSString *account, NSString *key) {
    SecItemDelete((CFDictionaryRef)baseQuery(account));
    [NSFileManager.defaultManager removeItemAtURL:fallbackFile(account) error:nil];
    if (!key.length) return YES;
    NSMutableDictionary *q = baseQuery(account);
    q[(id)kSecValueData] = [key dataUsingEncoding:NSUTF8StringEncoding];
    q[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    if (SecItemAdd((CFDictionaryRef)q, NULL) == errSecSuccess) return YES;
    return [[key dataUsingEncoding:NSUTF8StringEncoding] writeToURL:fallbackFile(account)
            options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication error:nil];
}

NSString *MRGKeychainAPIKey(void) { return MRGKeychainGet(kAccount); }
BOOL MRGKeychainSetAPIKey(NSString *key) { return MRGKeychainSet(kAccount, key); }
