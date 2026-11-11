// The DJ's voice: which engine speaks (the phone's own voices, the AI provider's speech, ElevenLabs, or none), which
// voice of it, how fast and how high, and a speaker that says a line with any of them (falling back to the phone's
// voice when a network voice fails). Settings → Mirage → AI DJ → Voice.
#import <AVFoundation/AVFoundation.h>

typedef NS_ENUM(NSInteger, MRGVoiceEngine) {
    MRGVoiceEnginePhone = 0,
    MRGVoiceEngineProvider = 1,   // the AI provider's speech (OpenAI, Gemini, xAI, Groq)
    MRGVoiceEngineEleven = 2,     // ElevenLabs, with its own key
    MRGVoiceEngineOff = 3,
};

MRGVoiceEngine MRGVoiceGetEngine(void);
void MRGVoiceSetEngine(MRGVoiceEngine e);
double MRGVoiceSpeed(void);            // 0.6 … 1.5, 1 = normal
void MRGVoiceSetSpeed(double s);
double MRGVoicePitch(void);            // 0.75 … 1.5 (iPhone voices; a "lower/higher register" instruction for styled engines)
void MRGVoiceSetPitch(double p);
double MRGVoiceWarmth(void);           // 0 … 1 (styled engines: OpenAI gpt-4o-mini-tts, Gemini)
void MRGVoiceSetWarmth(double v);
double MRGVoiceBreathiness(void);      // 0 … 1 (styled engines)
void MRGVoiceSetBreathiness(double v);
double MRGVoicePause(void);            // seconds between sentences, 0 … 1.5
void MRGVoiceSetPause(double v);
NSString *MRGVoiceStyleText(void);     // the listener's own "voice style" instruction, or nil
void MRGVoiceSetStyleText(NSString *t);
NSString *MRGVoiceInstructions(void);  // style text + words for the sliders, sent as TTS instructions where supported
double MRGElevenStability(void);
void MRGElevenSetStability(double v);
double MRGElevenSimilarity(void);
void MRGElevenSetSimilarity(double v);

// Presets: id, name, blurb, and the settings they set (speed, pitch, warmth, breath, pause, style, persona, a voice
// per engine). Apply returns what voices it picked (for the UI), or nil. Editing a slider makes it "Custom".
NSArray<NSDictionary *> *MRGVoicePresets(void);
NSString *MRGVoiceApplyPreset(NSString *presetID);
NSString *MRGVoicePresetID(void);      // nil: custom
void MRGVoiceMarkCustom(void);

// Phone voices: English and the phone's language, best first (personal, Premium, Enhanced, default).
NSArray<AVSpeechSynthesisVoice *> *MRGVoicePhoneVoices(void);
AVSpeechSynthesisVoice *MRGVoicePhoneVoice(void);   // the chosen one, else the best installed
void MRGVoiceSetPhoneVoice(NSString *identifier);   // nil: automatic
NSString *MRGVoiceQualityName(AVSpeechSynthesisVoice *v);

NSString *MRGVoiceProviderVoice(void);              // nil: the provider's default
void MRGVoiceSetProviderVoice(NSString *voiceID);

// ElevenLabs: key check (GET /v1/voices) and its voices, kept from the last check: id, name, category.
BOOL MRGElevenHasKey(void);
void MRGElevenSetKey(NSString *key, void (^done)(BOOL ok, NSString *message));
void MRGElevenRefreshVoices(void (^done)(NSArray<NSDictionary *> *voices, NSString *error));
NSArray<NSDictionary *> *MRGElevenVoices(void);
NSString *MRGElevenVoice(void);
void MRGElevenSetVoice(NSString *voiceID);
NSDictionary *MRGElevenNeedsAdd(void);   // a preset's voice missing from the account: {id, name, error?}, or nil
void MRGElevenAddShared(NSString *voiceID, NSString *name, void (^done)(BOOL ok, NSString *message));

// A short summary for the settings row ("Ava (Premium)", "OpenAI · ash", "Off").
NSString *MRGVoiceSummary(void);

@interface MRGVoiceSpeaker : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly, getter=isSpeaking) BOOL speaking;
// Says `text` with the current settings; `engine`/`voice` override them for previews (pass -1 / nil to use settings).
- (void)speak:(NSString *)text engine:(NSInteger)engine voice:(NSString *)voice started:(void (^)(void))started finished:(void (^)(void))finished;
- (void)stop;
@end
