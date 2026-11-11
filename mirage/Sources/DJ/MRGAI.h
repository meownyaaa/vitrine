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
    MRGProviderMistral,     // no key prefix: picked by hand
};

MRGProvider MRGDetectProvider(NSString *key);   // None when the format says nothing (Mistral, unknown)
NSString *MRGProviderName(MRGProvider p);
NSArray<NSNumber *> *MRGAllProviders(void);     // for choosing by hand
BOOL MRGProviderHasTTS(MRGProvider p);          // OpenAI, Gemini, xAI, Groq (speech endpoints in their docs)
BOOL MRGProviderHasTools(MRGProvider p);        // function calling in the chat API Mirage uses (not Perplexity's)

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
// The same with the provider chosen by hand (None: from the key's format). Errors carry the provider's HTTP status
// and its own message.
void MRGAISetupKeyAs(NSString *key, MRGProvider provider, void (^done)(BOOL ok, NSString *message));
void MRGAIForgetKey(void);

// One chat turn. json: ask for a JSON object back (each provider's JSON mode, where it has one).
void MRGAIChat(NSString *system, NSString *user, BOOL json, void (^done)(NSString *text, NSString *error));

// The provider's speech for a line in `voice` (nil: its default), at `speed` (1 = normal): audio data AVAudioPlayer
// can play (MP3 from OpenAI and xAI, WAV from Gemini and Groq).
// instructions: how to say it (OpenAI gpt-4o-mini-tts "instructions", a style prompt for Gemini); nil for the default.
void MRGAISpeech(NSString *text, NSString *voice, double speed, NSString *instructions, void (^done)(NSData *audio, NSString *error));
// The provider's voices, from its docs or its own voice list (xAI's GET /v1/tts/voices): id, name.
void MRGAIProviderVoices(void (^done)(NSArray<NSDictionary *> *voices));

// A chat turn with tools (function calling), for the DJ chat. Messages are Mirage's own shape:
//   {role: "user", content}  {role: "assistant", content, tool_calls: [{id, name, arguments (dict)}], raw}
//   {role: "tool", tool_call_id, name, content (JSON string)}
// tools: [{name, description, parameters (JSON schema)}]. `done` gets the assistant message in the same shape.
void MRGAIChatTools(NSString *system, NSArray<NSDictionary *> *messages, NSArray<NSDictionary *> *tools,
                    void (^done)(NSDictionary *assistant, NSString *error));

// Picking, exposed for the self-test: the best of `ids` for `provider`, or nil.
NSString *MRGAIPickModel(MRGProvider provider, NSArray<NSString *> *ids);

// Tool calls a model wrote as text (Harmony, <tool_call>, JSON, name(args), "name: key: value"), for the names given;
// *cleaned gets the text without them.
NSArray<NSDictionary *> *MRGParseTextToolCalls(NSString *text, NSSet<NSString *> *names, NSString **cleaned);
