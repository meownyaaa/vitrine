// Free voices for the DJ, next to the iPhone, AI provider and ElevenLabs engines:
//  - Free (Microsoft Edge voices, unofficial): the neural voices of Edge's "Read aloud", over the websocket Edge itself
//    uses (speech.platform.bing.com, what the edge-tts project calls). No key, no account. Unofficial: Microsoft can
//    change or block it at any time, and it takes only plain text with speed, pitch and volume (no styles or breaks).
#import <Foundation/Foundation.h>

// Edge: voices (id = ShortName, name, detail) and the chosen one.
NSArray<NSDictionary *> *MRGEdgeVoices(void);
NSString *MRGEdgeVoice(void);
void MRGEdgeSetVoice(NSString *voiceID);
// MP3 audio for `text` (plain text; "..." for pauses). speed 1 = normal; pitch 1 = normal; loudness from
// mirage.dj.edgeVolume (1 = normal), set by the presets.
void MRGEdgeSpeech(NSString *text, NSString *voice, double speed, double pitch, void (^done)(NSData *audio, NSString *error));
NSString *MRGEdgeToken(double unixTime);   // Sec-MS-GEC v2, exposed for the self-test
