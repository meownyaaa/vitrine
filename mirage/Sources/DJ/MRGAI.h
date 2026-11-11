// The AI DJ's model provider, from the user's own API key: which provider the key belongs to (by its
// format), which of its models to use (from the provider's own model list), a chat call and an optional
// text-to-speech call. Only what the caller passes in is sent; the DJ passes track and artist names and
// the user's own request text, nothing else.
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MRGProvider) {
    MRGProviderNone = 0,
    MRGProviderOpenAI,
    MRGProviderGemini,
    MRGProviderAnthropic,
    MRGProviderOpenRouter,
    MRGProviderGroq,
    MRGProviderXAI,
    MRGProviderPerplexity,
    MRGProviderCerebras,
    MRGProviderFireworks,
    MRGProviderTogether,
    MRGProviderDeepSeek,
};

MRGProvider MRGDetectProvider(NSString *key);
NSString *MRGProviderName(MRGProvider p);
BOOL MRGProviderHasTTS(MRGProvider p);   // OpenAI and Gemini

// The saved key's provider, the model in use (the user's pick, else the recommended one) and the
// recommended one. Model lists are kept from the last check.
MRGProvider MRGAIProvider(void);
NSString *MRGAIModel(void);
NSString *MRGAIRecommendedModel(void);
NSArray<NSString *> *MRGAIModels(void);
void MRGAISetModelOverride(NSString *model);   // nil: back to the recommended one
BOOL MRGAIHasOverride(void);

// Checks the key against the provider (its model list, or a tiny request where the list is public), picks
// the recommended model, and saves key, provider and lists on success. The message is user-facing.
void MRGAISetupKey(NSString *key, void (^done)(BOOL ok, NSString *message));
void MRGAIForgetKey(void);

// One chat turn. json: ask for a JSON object back (each provider's JSON mode, where it has one).
void MRGAIChat(NSString *system, NSString *user, BOOL json, void (^done)(NSString *text, NSString *error));

// The provider's speech for a line: audio data AVAudioPlayer can play (MP3 from OpenAI, WAV from Gemini).
void MRGAISpeech(NSString *text, void (^done)(NSData *audio, NSString *error));

// Picking, exposed for the self-test: the best of `ids` for `provider`, or nil.
NSString *MRGAIPickModel(MRGProvider provider, NSArray<NSString *> *ids);
