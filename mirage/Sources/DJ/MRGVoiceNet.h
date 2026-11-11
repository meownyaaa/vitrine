// Free and cheap voices for the DJ, next to the iPhone, AI provider and ElevenLabs engines:
//  - Free (Microsoft Edge voices, unofficial): the neural voices of Edge's "Read aloud", over the websocket Edge itself
//    uses (speech.platform.bing.com, what the edge-tts project calls). No key, no account. Unofficial: Microsoft can
//    change or block it at any time, and it takes only plain text with speed, pitch and volume (no styles or breaks).
//  - Qwen (Alibaba Cloud Model Studio, DashScope intl, Singapore): qwen3-tts-instruct-flash with a style instruction,
//    falling back to qwen3-tts-flash, with the listener's own DashScope key. Billed per character after a free quota.
#import <Foundation/Foundation.h>

// Edge: voices (id = ShortName, name, detail) and the chosen one.
NSArray<NSDictionary *> *MRGEdgeVoices(void);
NSString *MRGEdgeVoice(void);
void MRGEdgeSetVoice(NSString *voiceID);
// MP3 audio for `text` (plain text; "..." for pauses). speed 1 = normal; pitch 1 = normal.
void MRGEdgeSpeech(NSString *text, NSString *voice, double speed, double pitch, void (^done)(NSData *audio, NSString *error));
NSString *MRGEdgeToken(double unixTime);   // Sec-MS-GEC v2, exposed for the self-test

// Qwen: key (keychain), voices (id, name, detail) and the chosen one.
BOOL MRGQwenHasKey(void);
void MRGQwenSetKey(NSString *key, void (^done)(BOOL ok, NSString *message));
NSArray<NSDictionary *> *MRGQwenVoices(void);
NSString *MRGQwenVoice(void);
void MRGQwenSetVoice(NSString *voiceID);
// WAV audio; instructions (how to say it) go to the instruct model.
void MRGQwenSpeech(NSString *text, NSString *voice, NSString *instructions, void (^done)(NSData *audio, NSString *error));
