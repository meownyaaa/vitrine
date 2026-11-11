// Secrets Mirage keeps (the AI provider's key, the optional ElevenLabs key) in the keychain (this app's own, as
// sideloaded: the signing team's access group), never in NSUserDefaults. Readable after the first unlock so the DJ
// can talk with the phone locked.
#import <Foundation/Foundation.h>

NSString *MRGKeychainAPIKey(void);
BOOL MRGKeychainSetAPIKey(NSString *key);   // nil or empty deletes it
// Any other secret, by account name ("elevenlabs-key").
NSString *MRGKeychainGet(NSString *account);
BOOL MRGKeychainSet(NSString *account, NSString *value);   // nil or empty deletes it
