#import <CommonCrypto/CommonDigest.h>
#import <NaturalLanguage/NaturalLanguage.h>
#import <Security/Security.h>
#import "Core/SGCore.h"
#import "Settings/SGModPage.h"
#import "Settings/SGPageStyle.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/LocalFiles/LocalFiles.h"
#import "Headers/SPTPlayer.h"
#import "LyricsTranslation.h"

static NSString *const kDefaultPrompt =
    @"Translate the lines of this song into {language}: exactly {count} translations, one per input line and in "
    @"the same order. Translate the meaning naturally, keep each line short like a lyric, and keep an empty line "
    @"empty. A line already in {language} stays as it is.";
static NSString *const kDefaultBatchPrompt =
    @"Translate the lyrics of these {count} songs into {language}. Translate the meaning naturally as sung, "
    @"keep each line short like a lyric, and keep empty lines empty. Lines already in {language} stay as they are. "
    @"Return a JSON object with the exact same track IDs as keys, mapping each to an array of translated lines in the exact same order.";
static NSString *const kOpenAIDefaultURL = @"https://api.openai.com/v1";
// The OpenAI-compatible server is kept beside its key, never in the settings: a settings file from someone
// else could otherwise point a key stored here at their own server.
static NSString *const kKeyAccount = @"api-key", *const kServerAccount = @"server";
// A macro, not a constant: the provider table below needs a literal.
#define kLinesFormat @"Answer with a JSON object whose \"lines\" array holds the {count} translations as strings."


#pragma mark - the providers

// One entry per provider: adding one is a row here, its request and its reply's reader.
typedef struct {
    // Literals only, which live as long as the app.
    __unsafe_unretained NSString *tag, *name, *company, *service, *keyNote, *format;
    // Presets, nil-ended, the first being the default; none: the user names the model.
    __unsafe_unretained NSString *models[4], *modelNames[4];
    BOOL modelInURL;   // the id goes into the URL's path, so only the characters of an id are let through
    // Words of a 400 that send the plain request instead: the optional fields a model may not know.
    __unsafe_unretained NSString *plainWhen[4];
    NSMutableURLRequest *(*request)(NSString *model, NSString *prompt, NSString *key, BOOL plain);
    // The answer's text, or nil and in `stopped` why the model stopped short.
    NSString *(*answer)(NSDictionary *reply, NSString *speaker, NSString **stopped);
} SGAIProvider;

static NSString *filtered(NSString *speaker) { return [NSString stringWithFormat:@"%@'s filters blocked this song's lyrics.", speaker]; }
static NSString *tooLong(NSString *speaker) { return [NSString stringWithFormat:@"The song is too long for one answer from %@.", speaker]; }
static NSString *declined(NSString *speaker) { return [NSString stringWithFormat:@"%@ declined to translate the song.", speaker]; }

static id dig(id root, NSArray *path) {
    for (id step in path) {
        if ([step isKindOfClass:NSNumber.class]) root = [root isKindOfClass:NSArray.class] && [root count] > [step unsignedIntegerValue] ? root[[step unsignedIntegerValue]] : nil;
        else root = [root isKindOfClass:NSDictionary.class] ? root[step] : nil;
    }
    return root;
}

static NSString *string(id value) {
    return [value isKindOfClass:NSString.class] ? value : nil;
}

static const NSInteger kDefaultAITimeout = 120;

static NSTimeInterval aiTimeout(void) {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:SGKeyAITimeout];
    return seconds > 0 ? seconds : kDefaultAITimeout;
}

static NSMutableURLRequest *post(NSString *url, NSDictionary *body) {
    NSURL *endpoint = url ? [NSURL URLWithString:url] : nil;
    if (!endpoint) return nil;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:endpoint];
    request.HTTPMethod = @"POST";
    request.timeoutInterval = aiTimeout();
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    return request;
}

// What OpenAI's strict schema and Anthropic's ask for: an object at the top, the lines under "lines".
static NSDictionary *linesSchema(void) {
    return @{@"type": @"object", @"properties": @{@"lines": @{@"type": @"array", @"items": @{@"type": @"string"}}},
             @"required": @[@"lines"], @"additionalProperties": @NO};
}

static NSString *geminiThinkingLevel(void) {
    // Only the menu's levels: a stored "minimal" from an early build of this row would make 3.8 Flash answer 400 every ask.
    NSString *level = [NSUserDefaults.standardUserDefaults stringForKey:SGKeyAIThinking];
    return [@[@"medium", @"high"] containsObject:level] ? level : @"low";
}

// Gemini: generateContent, the key in x-goog-api-key, a bare array forced by responseSchema.
static NSMutableURLRequest *geminiRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    // Lyrics are often explicit, and translating them is what the user asked for, so every filter that can
    // be lowered is. Recitation cannot be switched off, and is named when it stops an answer.
    NSMutableArray *safety = [NSMutableArray array];
    for (NSString *category in @[@"HARM_CATEGORY_HARASSMENT", @"HARM_CATEGORY_HATE_SPEECH",
                                 @"HARM_CATEGORY_SEXUALLY_EXPLICIT", @"HARM_CATEGORY_DANGEROUS_CONTENT"]) {
        [safety addObject:@{@"category": category, @"threshold": @"BLOCK_NONE"}];
    }
    NSMutableDictionary *config = [@{@"responseMimeType": @"application/json",
                                     @"responseSchema": @{@"type": @"ARRAY", @"items": @{@"type": @"STRING"}}} mutableCopy];
    // Gemini 3 thinks at length by default, which a whole song's translation does not need and which made it
    // slow enough to time out. Plain: a model named in Other… that does not know the field.
    if (!plain) config[@"thinkingConfig"] = @{@"thinkingLevel": geminiThinkingLevel()};
    NSMutableURLRequest *request = post([NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:generateContent", model],
                                        @{@"contents": @[@{@"parts": @[@{@"text": prompt}]}], @"safetySettings": safety, @"generationConfig": config});
    [request setValue:key forHTTPHeaderField:@"x-goog-api-key"];
    return request;
}

// Why Gemini stopped short, as finishReason or promptFeedback.blockReason name it.
static NSString *geminiStop(NSString *reason, NSString *speaker) {
    if ([reason isEqualToString:@"RECITATION"]) return [NSString stringWithFormat:@"%@ stopped because its answer repeated published lyrics.", speaker];
    if ([@[@"SAFETY", @"PROHIBITED_CONTENT", @"BLOCKLIST", @"SPII"] containsObject:reason]) return filtered(speaker);
    if ([reason isEqualToString:@"MAX_TOKENS"]) return tooLong(speaker);
    return [NSString stringWithFormat:@"%@ stopped before translating the song (%@).", speaker, reason];
}

static NSString *geminiAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *blocked = string(dig(reply, @[@"promptFeedback", @"blockReason"]));
    NSString *finished = string(dig(reply, @[@"candidates", @0, @"finishReason"]));
    if (blocked) *stopped = geminiStop(blocked, speaker);
    else if (finished && ![finished isEqualToString:@"STOP"]) *stopped = geminiStop(finished, speaker);
    if (*stopped) return nil;
    NSArray *parts = dig(reply, @[@"candidates", @0, @"content", @"parts"]);
    if (![parts isKindOfClass:NSArray.class]) return nil;
    for (id part in parts) {
        if ([part isKindOfClass:NSDictionary.class]) {
            NSNumber *thought = part[@"thought"];
            if (thought && [thought boolValue]) continue;
            NSString *t = string(part[@"text"]);
            if (t.length) return t;
        }
    }
    for (NSInteger i = (NSInteger)parts.count - 1; i >= 0; i--) {
        id part = parts[i];
        NSString *t = string(part[@"text"]);
        if (t.length) return t;
    }
    return nil;
}

// A server URL as typed or stored: http or https with a host, no user, password or query (which could carry a
// secret into the log and the key row), and without /chat/completions if it was pasted whole.
NSString *SGAIServerIn(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSURLComponents *url = trimmed.length ? [NSURLComponents componentsWithString:trimmed] : nil;
    NSString *scheme = url.scheme.lowercaseString;
    if (!url.host.length || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"])
        || url.user || url.password || url.query || url.fragment) return nil;
    NSString *path = url.path;
    if ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
    if ([path hasSuffix:@"/chat/completions"]) path = [path substringToIndex:path.length - 17];
    url.path = path;
    return url.string;
}

static const SGAIProvider *providerFor(NSString *tag);
static NSString *storedSecret(const SGAIProvider *p, NSString *account);

// Unset: OpenAI's own. Set to something unusable: none, so a key meant for another server never goes to OpenAI.
static NSString *openAIServer(void) {
    NSString *stored = storedSecret(providerFor(@"openai"), kServerAccount);
    return stored.length ? SGAIServerIn(stored) : kOpenAIDefaultURL;
}

// OpenAI-compatible: chat completions with a bearer key, the lines forced into {"lines": [...]} by a strict
// schema. Plain: no schema and no reasoning effort, for servers and models that take neither.
static NSMutableURLRequest *openAIRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    NSString *server = openAIServer();
    NSMutableDictionary *body = [@{@"model": model, @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
    if (!plain) {
        body[@"response_format"] = @{@"type": @"json_schema",
                                     @"json_schema": @{@"name": @"translation", @"strict": @YES, @"schema": linesSchema()}};
        body[@"reasoning_effort"] = @"low";
    }
    NSMutableURLRequest *request = post(server ? [server stringByAppendingString:@"/chat/completions"] : nil, body);
    [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    return request;
}

static NSString *openAIAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *finished = string(dig(reply, @[@"choices", @0, @"finish_reason"]));
    if (string(dig(reply, @[@"choices", @0, @"message", @"refusal"])).length) *stopped = declined(speaker);
    else if ([finished isEqualToString:@"length"]) *stopped = tooLong(speaker);
    else if ([finished isEqualToString:@"content_filter"]) *stopped = filtered(speaker);
    return *stopped ? nil : string(dig(reply, @[@"choices", @0, @"message", @"content"]));
}

// Anthropic: the Messages API, the lines forced by output_config.format, thinking kept short by a low effort.
// max_tokens is required; output is billed as made, so a high cap costs nothing. Plain: without output_config,
// for a model that knows neither field.
static NSMutableURLRequest *anthropicRequest(NSString *model, NSString *prompt, NSString *key, BOOL plain) {
    NSMutableDictionary *body = [@{@"model": model, @"max_tokens": @16000,
                                   @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
    if (!plain) body[@"output_config"] = @{@"effort": @"low", @"format": @{@"type": @"json_schema", @"schema": linesSchema()}};
    NSMutableURLRequest *request = post(@"https://api.anthropic.com/v1/messages", body);
    [request setValue:key forHTTPHeaderField:@"x-api-key"];
    [request setValue:@"2026-10-21" forHTTPHeaderField:@"anthropic-version"];
    return request;
}

static NSString *anthropicAnswer(NSDictionary *reply, NSString *speaker, NSString **stopped) {
    NSString *finished = string(reply[@"stop_reason"]);
    if ([finished isEqualToString:@"refusal"]) *stopped = declined(speaker);
    else if ([finished isEqualToString:@"max_tokens"]) *stopped = tooLong(speaker);
    if (*stopped) return nil;
    NSMutableString *text = [NSMutableString string];
    id blocks = reply[@"content"];
    for (id block in [blocks isKindOfClass:NSArray.class] ? blocks : @[]) {
        if ([string(dig(block, @[@"type"])) isEqualToString:@"text"]) [text appendString:string(dig(block, @[@"text"])) ?: @""];
    }
    return text.length ? text : nil;
}

static const SGAIProvider kProviders[] = {
    {@"gemini", @"Gemini", @"Google", @"Vitrine.Gemini",
     @"Translate with Gemini sends the song's lyrics to Google, on your own key from Google AI Studio. The key stays on this iPhone.",
     @"Answer with a JSON array of the {count} translations as strings.",
     // A pinned id first, the one users report working. gemini-flash-latest follows each Flash release, preview
     // ones included, with notice only by email to the key's owner, so it is offered but not the default.
     {@"gemini-3.8-flash", @"gemini-3.5-flash-lite", @"gemini-flash-latest"}, {@"3.8 Flash", @"3.5 Flash-Lite", @"Flash (latest)"},
     YES, {@"thinking"}, geminiRequest, geminiAnswer},
    {@"openai", @"OpenAI-compatible", nil, @"Vitrine.OpenAI",
     @"Sends the song's lyrics to the server below: OpenAI's own unless you name another, such as OpenRouter, or an "
     @"Ollama on your network (http works for local addresses). The key stays on this iPhone; for a server without "
     @"keys, copy any word and paste that.",
     kLinesFormat,
     {nil}, {nil}, NO, {@"response_format", @"json_schema", @"reasoning"}, openAIRequest, openAIAnswer},
    {@"anthropic", @"Anthropic", @"Anthropic", @"Vitrine.Anthropic",
     @"Translate with Anthropic sends the song's lyrics to Anthropic, on your own key from the Claude Console. The key stays on this iPhone.",
     kLinesFormat,
     // The cheapest first: the reason a model is picked at all is what translating costs. Not the 5.5 models,
     // whose safety classifiers stop at lyrics with a refusal; Other… still names any model. Haiku 4.5 has no
     // effort, so its first request comes back once and is sent plain.
     {@"claude-haiku-4-5", @"claude-sonnet-4-6"}, {@"Haiku 4.5", @"Sonnet 4.6"},
     NO, {@"output_config", @"effort", @"json_schema"}, anthropicRequest, anthropicAnswer},
};
static const NSUInteger kProviderCount = sizeof(kProviders) / sizeof(kProviders[0]);

static const SGAIProvider *providerFor(NSString *tag) {
    for (NSUInteger i = 0; i < kProviderCount; i++) if ([kProviders[i].tag isEqualToString:tag]) return &kProviders[i];
    return NULL;
}

// The chosen one; unset or unknown (a restored backup): Gemini, the first.
static const SGAIProvider *chosen(void) {
    return providerFor([NSUserDefaults.standardUserDefaults stringForKey:SGKeyAITranslator]) ?: &kProviders[0];
}

static BOOL isOpenAI(const SGAIProvider *p) { return [p->tag isEqualToString:@"openai"]; }

static NSString *serverHost(void) {
    return [NSURL URLWithString:openAIServer() ?: @""].host;
}

// Who the messages name: the provider, or for an OpenAI-compatible one its server's host.
static NSString *speaker(const SGAIProvider *p) {
    return isOpenAI(p) ? serverHost() ?: @"The server" : p->name;
}

#pragma mark - the keys

static NSDictionary *keyQuery(const SGAIProvider *p, NSString *account) {
    return @{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
             (__bridge id)kSecAttrService: p->service, (__bridge id)kSecAttrAccount: account};
}

static NSString *storedSecret(const SGAIProvider *p, NSString *account) {
    NSMutableDictionary *query = [keyQuery(p, account) mutableCopy];
    query[(__bridge id)kSecReturnData] = @YES;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
    CFTypeRef data = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &data) != errSecSuccess || !data) return nil;
    NSString *value = [[NSString alloc] initWithData:(__bridge_transfer NSData *)data encoding:NSUTF8StringEncoding];
    return value.length ? value : nil;
}

static void storeSecret(const SGAIProvider *p, NSString *account, NSString *value) {
    SecItemDelete((__bridge CFDictionaryRef)keyQuery(p, account));
    if (!value.length) return;
    NSMutableDictionary *item = [keyQuery(p, account) mutableCopy];
    item[(__bridge id)kSecValueData] = [value dataUsingEncoding:NSUTF8StringEncoding];
    item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    if (status != errSecSuccess) SGLog(@"ai: the %@ %@ could not be kept (%d)", p->tag, account, (int)status);
}


#pragma mark - the model and the prompt

static NSString *storedString(NSString *key) {
    NSString *value = [NSUserDefaults.standardUserDefaults stringForKey:key];
    return value.length ? value : nil;
}

static NSString *modelKey(const SGAIProvider *p) {
    return [NSString stringWithFormat:@"spotifyglass.lyrics.%@.model", p->tag];
}

// A model id as the provider writes them, or nil: Gemini's goes into the request's URL, and a restored backup
// can bring any text under its key. Ids in the body may have / and : (OpenRouter's, Ollama's).
static NSString *modelIDIn(NSString *text, const SGAIProvider *p) {
    static NSCharacterSet *strict, *loose;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *idChars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_";
        strict = [NSCharacterSet characterSetWithCharactersInString:idChars].invertedSet;
        loose = [NSCharacterSet characterSetWithCharactersInString:[idChars stringByAppendingString:@"/:@"]].invertedSet;
    });
    NSString *modelID = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (p->modelInURL && [modelID hasPrefix:@"models/"]) modelID = [modelID substringFromIndex:7];
    return modelID.length && modelID.length <= 200 && [modelID rangeOfCharacterFromSet:p->modelInURL ? strict : loose].location == NSNotFound ? modelID : nil;
}

static NSString *model(const SGAIProvider *p) {
    return modelIDIn(storedString(modelKey(p)), p) ?: p->models[0];
}

static NSString *promptTemplate(void) {
    return storedString(SGKeyAIPrompt) ?: kDefaultPrompt;
}

NSString *SGLyricsBatchPromptTemplate(void) {
    return storedString(SGKeyLyricsBatchPrompt) ?: kDefaultBatchPrompt;
}

NSUInteger SGLyricsBatchSize(void) {
    NSNumber *val = [NSUserDefaults.standardUserDefaults objectForKey:SGKeyLyricsBatchSize];
    if (!val) return 20;
    NSInteger n = val.integerValue;
    if (n == 0) return 0;
    if (n == 10 || n == 20 || n == 30 || n == 40 || n == 50) return (NSUInteger)n;
    return 20;
}

BOOL SGLyricsBatchSkipSaved(void) {
    return SGFlag(SGKeyLyricsBatchSkipSaved, YES);
}

static BOOL hasWords(SGKaraokeLine *line) {
    NSString *text = SGKaraokeLineText(line);
    return text.length > 0 && ![text isEqualToString:@"♪"];
}

static NSUInteger otherScriptLetters(NSString *text, BOOL latinTarget) {
    __block NSUInteger count = 0;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        UTF32Char c = 0;
        if (![character getBytes:&c maxLength:sizeof(c) usedLength:NULL encoding:NSUTF32LittleEndianStringEncoding options:0
                           range:NSMakeRange(0, character.length) remainingRange:NULL]) return;
        if (![NSCharacterSet.letterCharacterSet longCharacterIsMember:c]) return;
        BOOL latin = c < 0x250 || (c >= 0x1E00 && c < 0x1F00);
        if (latin != latinTarget) count++;
    }];
    return count;
}

static NSUInteger romanizedKoreanWords(NSString *text) {
    NSUInteger count = 0;
    for (NSString *word in [text componentsSeparatedByCharactersInSet:NSCharacterSet.letterCharacterSet.invertedSet]) {
        if ([word containsString:@"eo"] || [word containsString:@"eu"]) count++;
    }
    return count;
}

BOOL SGKaraokeInAnotherLanguage(NSArray<SGKaraokeLine *> *lines, NSString *language) {
    if (!lines.count || !language.length) return NO;
    NSString *(^code)(NSString *) = ^NSString *(NSString *tag) {
        return [tag componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"-_"]].firstObject.lowercaseString;
    };
    NSString *target = code(language);
    NSString *targetScript = [NSOrthography defaultOrthographyForLanguage:language].dominantScript;
    NSUInteger distinct = 0, sure = 0, foreign = 0, otherScript = 0;
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    NLLanguageRecognizer *recognizer = [NLLanguageRecognizer new];
    for (SGKaraokeLine *line in lines) {
        NSString *text = hasWords(line) ? SGKaraokeLineText(line).lowercaseString : nil;
        if (!text.length || [seen containsObject:text]) continue;
        [seen addObject:text];
        distinct++;
        BOOL lettersOther = otherScriptLetters(text, [targetScript isEqualToString:@"Latn"]) >= 2;
        if (lettersOther) otherScript++;
        [recognizer reset];
        [recognizer processString:text];
        NSDictionary<NLLanguage, NSNumber *> *guess = [recognizer languageHypothesesWithMaximum:1];
        NLLanguage found = guess.allKeys.firstObject;
        BOOL confident = found && guess[found].doubleValue >= 0.8, inTarget = confident && [code(found) isEqualToString:target];
        if (!lettersOther && !inTarget && romanizedKoreanWords(text) >= 2) otherScript++;
        if (!confident) continue;
        sure++;
        if (inTarget) continue;
        foreign++;
        if (!lettersOther && ![[NSOrthography defaultOrthographyForLanguage:found].dominantScript isEqualToString:targetScript]) otherScript++;
    }
    return !sure || foreign * 5 >= MAX(distinct, 5) || otherScript >= 2;
}

// The first 8 hex digits of the template's SHA-256, for the log: which prompt went, never what the lyrics were.
static NSString *fingerprint(NSString *text) {
    NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    return [NSString stringWithFormat:@"%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3]];
}

BOOL SGAITranslatorReady(void) {
    const SGAIProvider *p = chosen();
    return storedSecret(p, kKeyAccount) && model(p) && (!isOpenAI(p) || openAIServer());
}

NSString *SGAITranslatorName(void) {
    const SGAIProvider *p = chosen();
    return isOpenAI(p) && model(p) ? model(p) : p->name;
}

NSString *SGAITranslatorRecipient(void) {
    const SGAIProvider *p = chosen();
    return p->company ?: speaker(p);
}

SGTranslationSource *SGAITranslatorSource(void) {
    const SGAIProvider *p = chosen();
    return [SGTranslationSource by:p->tag model:model(p) made:nil];
}

@implementation SGTranslationSource

+ (instancetype)by:(NSString *)by model:(NSString *)model made:(NSDate *)made {
    SGTranslationSource *source = [self new];
    source->_by = [by copy];
    source->_model = [model copy];
    source->_made = made;
    return source;
}

- (NSString *)name {
    const SGAIProvider *p = providerFor(_by);
    if (p) return _model.length ? [NSString stringWithFormat:@"%@ (%@)", p->name, _model] : p->name;
    if ([_by isEqualToString:SGTranslatedOnDevice]) return @"Translate on iPhone";
    if ([_by isEqualToString:SGTranslatedByAppleIntelligence]) return @"Apple Intelligence";
    return @"Unknown";
}

// Asking the iPhone again costs nothing, and its translation is the same.
- (BOOL)deletable {
    return ![_by isEqualToString:SGTranslatedOnDevice] && ![_by isEqualToString:SGTranslatedByAppleIntelligence];
}
@end

#pragma mark - asking

NSString *SGLyricsSongName(NSString *trackID) {
    NSDictionary *local = trackID ? SGLocalFileInfo(trackID) : nil;
    SPTPlayerTrack *track = trackID && !local ? SGKaraokeTrackFor(trackID) : nil;
    NSString *title = local ? local[@"title"] : track.trackTitle, *artist = local ? local[@"artist"] : track.artistName;
    if (![title isKindOfClass:NSString.class] || !title.length) return nil;
    return [artist isKindOfClass:NSString.class] && artist.length ? [NSString stringWithFormat:@"“%@” by %@", title, artist]
                                                                     : [NSString stringWithFormat:@"“%@”", title];
}

NSString *SGLyricsTranslationTarget(void) {
    return SGLyricsTranslationLanguage() ?: NSLocale.preferredLanguages.firstObject ?: @"en";
}

NSURLRequest *SGAITranslationRequest(NSString *provider, NSString *modelID, NSString *prompt, NSString *key, BOOL plain) {
    const SGAIProvider *p = providerFor(provider);
    return p && modelID && key ? p->request(modelID, prompt, key, plain) : nil;
}

// The lines out of an answer: a bare array or {"lines": [...]}, whichever the request forced or the prompt asked
// for, and inside a Markdown fence or a sentence when a model without a schema added one.
static id linesIn(NSString *text) {
    if (!text) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!parsed) {
        NSRange open = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"[{"]];
        NSRange close = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"]}"] options:NSBackwardsSearch];
        if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
            NSString *inner = [text substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
            parsed = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        }
    }
    if ([parsed isKindOfClass:NSDictionary.class]) parsed = parsed[@"lines"];
    return [parsed isKindOfClass:NSArray.class] ? parsed : nil;
}

NSArray<NSString *> *SGAITranslationsIn(NSString *provider, id root, NSInteger status, NSError *error, NSUInteger count, NSString **problem) {
    const SGAIProvider *p = providerFor(provider) ?: &kProviders[0];
    NSString *who = speaker(p);
    NSDictionary *reply = [root isKindOfClass:NSDictionary.class] ? root : nil;
    NSString *stopped = nil;
    NSArray *lines = status == 200 ? linesIn(p->answer(reply, who, &stopped)) : nil;
    if (lines.count == count) {
        NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:count];
        for (id line in lines) [clean addObject:[line isKindOfClass:NSString.class] ? line : @""];
        return clean;
    }
    // {"error": {"message": ...}} from all three; a bare string from some compatible servers.
    NSString *says = string(dig(reply, @[@"error", @"message"])) ?: string(reply[@"error"]);
    if (error) {
        *problem = error.code == NSURLErrorTimedOut
            ? [NSString stringWithFormat:@"%@ timed out. Try a longer timeout on the Lyrics page.", who]
            : [NSString stringWithFormat:@"%@ could not be reached.", who];
    } else if (status == 401 || status == 403 || (status == 400 && [says localizedCaseInsensitiveContainsString:@"API key"])) {
        *problem = [NSString stringWithFormat:@"%@ turned the key down. Check it on the Lyrics page.", who];
    } else if (status == 400 || status == 404) {
        *problem = says.length ? [NSString stringWithFormat:@"%@ did not take the request: %@", who, says]
                               : [NSString stringWithFormat:@"%@ did not take the request (%ld).", who, (long)status];
    } else if (status == 429) {
        *problem = [NSString stringWithFormat:@"%@'s limit for this key is reached for now.", who];
    } else if (status >= 500) {
        *problem = [NSString stringWithFormat:@"%@ is busy right now. Try again in a minute.", who];
    } else if (status != 200) {
        *problem = [NSString stringWithFormat:@"%@ did not translate the song (%ld).", who, (long)status];
    } else if (stopped) {
        *problem = stopped;
    } else if (lines) {
        *problem = [NSString stringWithFormat:@"%@ answered %lu lines for the song's %lu. Try again.", who,
                    (unsigned long)lines.count, (unsigned long)count];
    } else {
        *problem = [NSString stringWithFormat:@"%@'s answer could not be read. Try again.", who];
    }
    return nil;
}

// The providers' advice for a busy model or a full minute's quota (408, 429, 5xx): ask again after about 1, 2
// and 4 s, spread a little so phones do not all come back at once. A key turned down or a request that timed
// out is not asked again. plain is the same request without the optional fields, sent once if a 400 names one.
static void send(const SGAIProvider *p, NSURLRequest *request, NSURLRequest *plain, NSUInteger attempt,
                 void (^finished)(NSData *data, NSInteger status, NSError *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSString *reply = status == 400 && data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        for (NSUInteger i = 0; plain && reply && i < 4 && p->plainWhen[i]; i++) {
            if (![reply localizedCaseInsensitiveContainsString:p->plainWhen[i]]) continue;
            SGLog(@"ai: %@ turned down %@, asking without the optional fields", p->tag, p->plainWhen[i]);
            send(p, plain, nil, attempt, finished);
            return;
        }
        if (attempt < 3 && !error && (status == 408 || status == 429 || status >= 500)) {
            double delay = (double)(1 << attempt) * (0.75 + arc4random_uniform(500) / 1000.0);
            SGLog(@"ai: %ld, asking again in %.1f s", (long)status, delay);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                send(p, request, plain, attempt + 1, finished);
            });
            return;
        }
        finished(data, status, error);
    }] resume];
}

// Per launch, by "track|language|" and then the provider, server, model, Gemini's thinking and prompt: a translation asked again
// after any of them changed is a new one.
static NSMutableDictionary<NSString *, NSArray<NSString *> *> *sg_done;

void SGLyricsForgetAITranslation(NSString *trackID, NSString *languageTag) {
    if (!trackID) {
        [sg_done removeAllObjects];
        return;
    }
    NSString *song = [NSString stringWithFormat:@"%@|%@|", trackID, languageTag];
    for (NSString *memo in sg_done.allKeys) if ([memo hasPrefix:song]) [sg_done removeObjectForKey:memo];
}

void SGLyricsTranslateWithAI(NSString *trackID, NSArray<SGKaraokeLine *> *lines, NSString *languageTag,
                             void (^done)(NSArray<NSString *> *translations, NSString *error)) {
    const SGAIProvider *p = chosen();
    NSString *key = storedSecret(p, kKeyAccount), *modelID = model(p), *template = promptTemplate();
    if (!key || !modelID) {
        done(nil, [NSString stringWithFormat:@"Add a %@ API key%@ in Mod Settings > Lyrics first.", p->name, modelID ? @"" : @" and choose a model"]);
        return;
    }
    if (!sg_done) sg_done = [NSMutableDictionary dictionary];
    NSString *memo = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%@", trackID, languageTag, p->tag,
                      isOpenAI(p) ? openAIServer() : @"", modelID,
                      [p->tag isEqualToString:@"gemini"] ? geminiThinkingLevel() : @"", template];
    if (trackID && sg_done[memo].count == lines.count) {
        done(sg_done[memo], nil);
        return;
    }
    NSMutableArray<NSString *> *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [texts addObject:SGKaraokeLineText(line) ?: @""];
    // By the whole tag, so the script stays: zh-Hant is "Chinese, Traditional" where its language alone is "Chinese".
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLocaleIdentifier:languageTag] ?: languageTag;
    NSData *input = [NSJSONSerialization dataWithJSONObject:texts options:0 error:nil];
    // Filled in by replacing, never as a format: the template is the user's own text. The provider's own
    // sentence on the answer's shape follows it, so an edited prompt cannot ask for the wrong one.
    NSString *instructions = [NSString stringWithFormat:@"%@ %@", template, p->format];
    instructions = [[instructions stringByReplacingOccurrencesOfString:@"{language}" withString:language]
                    stringByReplacingOccurrencesOfString:@"{count}" withString:@(texts.count).stringValue];
    NSString *prompt = [NSString stringWithFormat:@"%@\n\n%@", instructions, [[NSString alloc] initWithData:input encoding:NSUTF8StringEncoding]];
    NSURLRequest *request = p->request(modelID, prompt, key, NO), *plain = p->request(modelID, prompt, key, YES);
    if (!request) {
        done(nil, @"The server URL is invalid. Check it in Mod Settings > Lyrics.");
        return;
    }
    SGLog(@"ai: asking %@ %@ at %@, prompt %@%@", p->tag, modelID, request.URL.host, fingerprint(template),
          storedString(SGKeyAIPrompt) ? @" (edited)" : @"");
    send(p, request, plain, 0, ^(NSData *data, NSInteger status, NSError *error) {
        id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *problem = nil;
        NSArray *translations = SGAITranslationsIn(p->tag, root, status, error, texts.count, &problem);
        SGLog(@"ai: %@ %@ lines into %@: %@", p->tag, @(texts.count), languageTag, translations ? @"translated" : problem);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (translations && trackID) sg_done[memo] = translations;
            done(translations, problem);
        });
    });
}

static NSDictionary *batchMapIn(NSString *text) {
    if (!text.length) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[text dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (!parsed) {
        for (NSString *bracket in @[@"{", @"["]) {
            NSString *closeBracket = [bracket isEqualToString:@"{"] ? @"}" : @"]";
            NSRange open = [text rangeOfString:bracket], close = [text rangeOfString:closeBracket options:NSBackwardsSearch];
            if (open.location != NSNotFound && close.location != NSNotFound && close.location > open.location) {
                NSString *inner = [text substringWithRange:NSMakeRange(open.location, close.location - open.location + 1)];
                parsed = [NSJSONSerialization JSONObjectWithData:[inner dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
                if (parsed) break;
            }
        }
    }
    if ([parsed isKindOfClass:NSDictionary.class]) {
        for (NSString *key in @[@"songs", @"tracks", @"translations", @"results", @"data"]) {
            if ([parsed[key] isKindOfClass:NSDictionary.class]) return parsed[key];
        }
        return parsed;
    }
    if ([parsed isKindOfClass:NSArray.class]) {
        NSMutableDictionary *mapped = [NSMutableDictionary dictionary];
        for (NSUInteger i = 0; i < [parsed count]; i++) {
            id item = parsed[i];
            if ([item isKindOfClass:NSDictionary.class]) {
                NSString *tID = item[@"track"] ?: item[@"id"] ?: item[@"track_id"] ?: item[@"uri"] ?: @(i).stringValue;
                id lines = item[@"lines"] ?: item[@"translations"] ?: item[@"translation"];
                if (lines) mapped[tID] = lines;
                else mapped[@(i).stringValue] = item;
            } else if ([item isKindOfClass:NSArray.class]) {
                mapped[@(i).stringValue] = item;
            }
        }
        return mapped;
    }
    return nil;
}

static NSURLRequest *batchRequest(const SGAIProvider *p, NSString *modelID, NSString *prompt, NSString *key, BOOL plain, BOOL stream) {
    if ([p->tag isEqualToString:@"gemini"]) {
        NSMutableArray *safety = [NSMutableArray array];
        for (NSString *category in @[@"HARM_CATEGORY_HARASSMENT", @"HARM_CATEGORY_HATE_SPEECH",
                                     @"HARM_CATEGORY_SEXUALLY_EXPLICIT", @"HARM_CATEGORY_DANGEROUS_CONTENT"]) {
            [safety addObject:@{@"category": category, @"threshold": @"BLOCK_NONE"}];
        }
        NSMutableDictionary *config = [@{@"responseMimeType": @"application/json"} mutableCopy];
        if (!plain) config[@"thinkingConfig"] = @{@"thinkingLevel": geminiThinkingLevel()};
        NSString *action = stream ? @"streamGenerateContent?alt=sse" : @"generateContent";
        NSMutableURLRequest *req = post([NSString stringWithFormat:@"https://generativelanguage.googleapis.com/v1beta/models/%@:%@", modelID, action],
                                        @{@"contents": @[@{@"parts": @[@{@"text": prompt}]}], @"safetySettings": safety, @"generationConfig": config});
        [req setValue:key forHTTPHeaderField:@"x-goog-api-key"];
        return req;
    }
    if ([p->tag isEqualToString:@"openai"]) {
        NSString *server = openAIServer();
        NSMutableDictionary *body = [@{@"model": modelID, @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
        if (stream) body[@"stream"] = @YES;
        if (!plain) {
            body[@"response_format"] = @{@"type": @"json_object"};
            body[@"reasoning_effort"] = @"low";
        }
        NSMutableURLRequest *req = post(server ? [server stringByAppendingString:@"/chat/completions"] : nil, body);
        [req setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
        return req;
    }
    if ([p->tag isEqualToString:@"anthropic"]) {
        NSMutableDictionary *body = [@{@"model": modelID, @"max_tokens": @16000,
                                       @"messages": @[@{@"role": @"user", @"content": prompt}]} mutableCopy];
        if (stream) body[@"stream"] = @YES;
        if (!plain) body[@"output_config"] = @{@"effort": @"low"};
        NSMutableURLRequest *req = post(@"https://api.anthropic.com/v1/messages", body);
        [req setValue:key forHTTPHeaderField:@"x-api-key"];
        [req setValue:@"2026-10-21" forHTTPHeaderField:@"anthropic-version"];
        return req;
    }
    return p->request(modelID, prompt, key, plain);
}

// Scans the accumulated JSON stream for any song keys whose `[...]` array has fully closed,
// and emits each completed song once via `onSong`.
static void scanCompletedSongsInStream(NSString *accumulated,
                                       NSDictionary<NSString *, NSArray<NSString *> *> *songs,
                                       NSMutableSet<NSString *> *emitted,
                                       NSMutableDictionary<NSString *, NSArray<NSString *> *> *streamedResults,
                                       void (^onSong)(NSString *trackKey, NSArray<NSString *> *lines)) {
    if (!accumulated.length) return;
    NSUInteger len = accumulated.length;
    for (NSString *trackKey in songs) {
        if ([emitted containsObject:trackKey]) continue;
        NSString *bareID = [trackKey hasPrefix:@"spotify:track:"] ? [trackKey substringFromIndex:@"spotify:track:".length] : trackKey;
        NSString *uriID = [@"spotify:track:" stringByAppendingString:bareID];
        
        NSRange keyRange = [accumulated rangeOfString:[NSString stringWithFormat:@"\"%@\"", trackKey]];
        if (keyRange.location == NSNotFound) {
            keyRange = [accumulated rangeOfString:[NSString stringWithFormat:@"\"%@\"", bareID]];
        }
        if (keyRange.location == NSNotFound) {
            keyRange = [accumulated rangeOfString:[NSString stringWithFormat:@"\"%@\"", uriID]];
        }
        if (keyRange.location == NSNotFound) continue;
        
        NSUInteger pos = NSMaxRange(keyRange);
        // Find opening '[' after ':' (skipping optional wrapper object like {"lines": [)
        NSUInteger arrayStart = NSNotFound;
        BOOL passedColon = NO;
        while (pos < len) {
            unichar c = [accumulated characterAtIndex:pos];
            if (c == ':') {
                passedColon = YES;
            } else if (passedColon) {
                if (c == '[') { arrayStart = pos; break; }
                if (c == ',' || c == ']') break;
            }
            pos++;
        }
        if (arrayStart == NSNotFound) continue;
        
        // Scan string-aware brackets to find matching ']'
        NSInteger depth = 0;
        BOOL inString = NO;
        BOOL escaped = NO;
        NSUInteger arrayEnd = NSNotFound;
        for (NSUInteger i = arrayStart; i < len; i++) {
            unichar c = [accumulated characterAtIndex:i];
            if (escaped) {
                escaped = NO;
                continue;
            }
            if (c == '\\' && inString) {
                escaped = YES;
                continue;
            }
            if (c == '"') {
                inString = !inString;
                continue;
            }
            if (!inString) {
                if (c == '[') depth++;
                else if (c == ']') {
                    depth--;
                    if (depth == 0) {
                        arrayEnd = i;
                        break;
                    }
                }
            }
        }
        if (arrayEnd != NSNotFound) {
            NSString *slice = [accumulated substringWithRange:NSMakeRange(arrayStart, arrayEnd - arrayStart + 1)];
            id parsed = [NSJSONSerialization JSONObjectWithData:[slice dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
            if ([parsed isKindOfClass:NSArray.class]) {
                NSMutableArray<NSString *> *clean = [NSMutableArray arrayWithCapacity:[parsed count]];
                for (id l in parsed) [clean addObject:[l isKindOfClass:NSString.class] ? l : [l description]];
                [emitted addObject:trackKey];
                NSArray<NSString *> *expected = songs[trackKey];
                if (expected && clean.count == expected.count) {
                    streamedResults[trackKey] = clean;
                    streamedResults[bareID] = clean;
                    if (onSong) {
                        NSArray<NSString *> *copyLines = [clean copy];
                        dispatch_async(dispatch_get_main_queue(), ^{
                            onSong(trackKey, copyLines);
                        });
                    }
                }
            }
        }
    }
}

@interface SGAIBatchStreamDelegate : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, assign) const SGAIProvider *provider;
@property (nonatomic, copy) NSDictionary<NSString *, NSArray<NSString *> *> *songs;
@property (nonatomic, copy) void (^onPhase)(NSString *phase);
@property (nonatomic, copy) void (^onSong)(NSString *trackKey, NSArray<NSString *> *lines);
@property (nonatomic, copy) void (^completion)(NSData *rawData, NSString *accumulatedText, NSDictionary<NSString *, NSArray<NSString *> *> *streamedResults, NSString *stopReason, NSInteger status, NSError *error);
@end

@implementation SGAIBatchStreamDelegate {
    NSMutableData *_rawBuffer;
    NSMutableData *_utf8Buffer;
    NSMutableString *_accumulatedText;
    NSMutableSet<NSString *> *_emittedSongs;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_streamedResults;
    NSString *_stopReason;
    NSInteger _statusCode;
    BOOL _reportedThinking;
    BOOL _reportedWriting;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _rawBuffer = [NSMutableData data];
    _utf8Buffer = [NSMutableData data];
    _accumulatedText = [NSMutableString string];
    _emittedSongs = [NSMutableSet set];
    _streamedResults = [NSMutableDictionary dictionary];
    return self;
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if ([response isKindOfClass:NSHTTPURLResponse.class]) {
        _statusCode = ((NSHTTPURLResponse *)response).statusCode;
    }
    completionHandler(NSURLSessionResponseAllow);
}

- (void)processSSEEventLine:(NSString *)line {
    NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![trimmed hasPrefix:@"data:"]) return;
    NSString *payload = [[trimmed substringFromIndex:5] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!payload.length || [payload isEqualToString:@"[DONE]"]) return;
    
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![json isKindOfClass:NSDictionary.class]) return;
    
    BOOL sawThought = NO;
    NSMutableString *deltaText = [NSMutableString string];
    NSString *tag = self.provider->tag;
    
    if ([tag isEqualToString:@"gemini"]) {
        NSString *blocked = string(dig(json, @[@"promptFeedback", @"blockReason"]));
        if (blocked.length) _stopReason = blocked;
        NSArray *candidates = json[@"candidates"];
        NSDictionary *first = [candidates isKindOfClass:NSArray.class] ? candidates.firstObject : nil;
        NSString *finish = [first isKindOfClass:NSDictionary.class] ? string(first[@"finishReason"]) : nil;
        if (finish.length && ![finish isEqualToString:@"STOP"]) _stopReason = finish;
        NSArray *parts = [first isKindOfClass:NSDictionary.class] ? first[@"content"][@"parts"] : nil;
        if ([parts isKindOfClass:NSArray.class]) {
            for (NSDictionary *part in parts) {
                if (![part isKindOfClass:NSDictionary.class]) continue;
                if ([part[@"thought"] respondsToSelector:@selector(boolValue)] && [part[@"thought"] boolValue]) {
                    sawThought = YES;
                } else if ([part[@"text"] isKindOfClass:NSString.class]) {
                    [deltaText appendString:part[@"text"]];
                }
            }
        }
    } else if ([tag isEqualToString:@"openai"]) {
        NSArray *choices = json[@"choices"];
        NSDictionary *first = [choices isKindOfClass:NSArray.class] ? choices.firstObject : nil;
        NSString *finish = [first isKindOfClass:NSDictionary.class] ? string(first[@"finish_reason"]) : nil;
        if (finish.length && ![finish isEqualToString:@"stop"]) _stopReason = finish;
        NSDictionary *delta = [first isKindOfClass:NSDictionary.class] ? first[@"delta"] : nil;
        if ([delta isKindOfClass:NSDictionary.class]) {
            if ([delta[@"reasoning_content"] isKindOfClass:NSString.class] || [delta[@"reasoning"] isKindOfClass:NSString.class]) {
                sawThought = YES;
            }
            if ([delta[@"content"] isKindOfClass:NSString.class]) {
                [deltaText appendString:delta[@"content"]];
            }
        }
    } else if ([tag isEqualToString:@"anthropic"]) {
        NSDictionary *delta = json[@"delta"];
        NSString *stop = ([delta isKindOfClass:NSDictionary.class] ? string(delta[@"stop_reason"]) : nil) ?: string(json[@"stop_reason"]);
        if (stop.length && ![stop isEqualToString:@"end_turn"]) _stopReason = stop;
        if ([delta isKindOfClass:NSDictionary.class]) {
            NSString *type = delta[@"type"];
            if ([type isEqualToString:@"thinking_delta"] || [delta[@"thinking"] isKindOfClass:NSString.class]) {
                sawThought = YES;
            } else if ([delta[@"text"] isKindOfClass:NSString.class]) {
                [deltaText appendString:delta[@"text"]];
            }
        }
    }
    
    if (sawThought && !_reportedThinking && !_reportedWriting) {
        _reportedThinking = YES;
        if (self.onPhase) {
            void (^phaseBlock)(NSString *) = self.onPhase;
            dispatch_async(dispatch_get_main_queue(), ^{
                phaseBlock(@"Thinking…");
            });
        }
    }
    if (deltaText.length > 0) {
        if (!_reportedWriting) {
            _reportedWriting = YES;
            if (self.onPhase) {
                void (^phaseBlock)(NSString *) = self.onPhase;
                dispatch_async(dispatch_get_main_queue(), ^{
                    phaseBlock(@"Writing");
                });
            }
        }
        [_accumulatedText appendString:deltaText];
        scanCompletedSongsInStream(_accumulatedText, self.songs, _emittedSongs, _streamedResults, self.onSong);
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    [_rawBuffer appendData:data];
    if (_statusCode != 200) return;
    [_utf8Buffer appendData:data];
    
    const uint8_t *bytes = _utf8Buffer.bytes;
    NSUInteger length = _utf8Buffer.length;
    NSUInteger lineStart = 0;
    for (NSUInteger i = 0; i < length; i++) {
        if (bytes[i] == '\n') {
            NSData *lineData = [_utf8Buffer subdataWithRange:NSMakeRange(lineStart, i - lineStart)];
            NSString *lineStr = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (lineStr) [self processSSEEventLine:lineStr];
            lineStart = i + 1;
        }
    }
    if (lineStart > 0) {
        [_utf8Buffer replaceBytesInRange:NSMakeRange(0, lineStart) withBytes:NULL length:0];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (_statusCode == 200 && _utf8Buffer.length > 0) {
        NSString *tail = [[NSString alloc] initWithData:_utf8Buffer encoding:NSUTF8StringEncoding];
        if (tail.length) [self processSSEEventLine:tail];
        [_utf8Buffer setLength:0];
    }
    if (self.completion) {
        self.completion(_rawBuffer, _accumulatedText, _streamedResults, _stopReason, _statusCode, error);
    }
}

@end

static void sendBatchStream(const SGAIProvider *p,
                            NSURLRequest *request,
                            NSURLRequest *plain,
                            NSDictionary<NSString *, NSArray<NSString *> *> *songs,
                            NSUInteger attempt,
                            void (^onPhase)(NSString *phase),
                            void (^onSong)(NSString *trackKey, NSArray<NSString *> *lines),
                            void (^done)(NSData *rawData, NSString *accumulatedText, NSDictionary<NSString *, NSArray<NSString *> *> *streamedResults, NSString *stopReason, NSInteger status, NSError *error)) {
    SGAIBatchStreamDelegate *del = [SGAIBatchStreamDelegate new];
    del.provider = p;
    del.songs = songs;
    del.onPhase = onPhase;
    del.onSong = onSong;
    del.completion = ^(NSData *rawData, NSString *accumulatedText, NSDictionary<NSString *, NSArray<NSString *> *> *streamedResults, NSString *stopReason, NSInteger status, NSError *error) {
        NSString *reply = status == 400 && rawData ? [[NSString alloc] initWithData:rawData encoding:NSUTF8StringEncoding] : nil;
        for (NSUInteger i = 0; plain && reply && i < 4 && p->plainWhen[i]; i++) {
            if (![reply localizedCaseInsensitiveContainsString:p->plainWhen[i]]) continue;
            SGLog(@"ai batch: %@ turned down %@, asking without the optional fields", p->tag, p->plainWhen[i]);
            sendBatchStream(p, plain, nil, songs, attempt, onPhase, onSong, done);
            return;
        }
        BOOL transient = (error && error.code != NSURLErrorTimedOut && error.code != NSURLErrorCancelled) ||
                         status == 408 || status == 429 || status >= 500;
        if (transient && attempt < 2 && streamedResults.count == 0) {
            int64_t delay = (1LL << attempt) * NSEC_PER_SEC + (int64_t)arc4random_uniform(250) * NSEC_PER_MSEC;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                sendBatchStream(p, request, plain, songs, attempt + 1, onPhase, onSong, done);
            });
            return;
        }
        done(rawData, accumulatedText, streamedResults, stopReason, status, error);
    };
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = aiTimeout();
    config.timeoutIntervalForResource = MAX(aiTimeout() * (songs.count ?: 1), 600.0);
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:del delegateQueue:nil];
    [[session dataTaskWithRequest:request] resume];
    [session finishTasksAndInvalidate];
}

void SGLyricsTranslateBatchWithAI(NSDictionary<NSString *, NSArray<NSString *> *> *songs,
                                  NSString *languageTag,
                                  void (^onPhase)(NSString *phase),
                                  void (^onSong)(NSString *trackKey, NSArray<NSString *> *lines),
                                  void (^done)(NSDictionary<NSString *, NSArray<NSString *> *> *results, NSString *error)) {
    const SGAIProvider *p = chosen();
    NSString *key = storedSecret(p, kKeyAccount), *modelID = model(p), *template = SGLyricsBatchPromptTemplate();
    if (!key || !modelID) {
        done(nil, [NSString stringWithFormat:@"Set up %@ in Mod Settings", p->name]);
        return;
    }
    if (!songs.count) {
        done(@{}, nil);
        return;
    }
    NSString *language = [[NSLocale localeWithLocaleIdentifier:@"en"] localizedStringForLocaleIdentifier:languageTag] ?: languageTag;
    NSData *inputData = [NSJSONSerialization dataWithJSONObject:songs options:NSJSONWritingPrettyPrinted error:nil];
    NSString *inputJSON = inputData ? [[NSString alloc] initWithData:inputData encoding:NSUTF8StringEncoding] : @"{}";
    
    NSString *instructions = template;
    instructions = [[instructions stringByReplacingOccurrencesOfString:@"{language}" withString:language]
                    stringByReplacingOccurrencesOfString:@"{count}" withString:@(songs.count).stringValue];
    NSString *prompt = [NSString stringWithFormat:@"%@\n\n%@", instructions, inputJSON];
    
    NSURLRequest *request = batchRequest(p, modelID, prompt, key, NO, YES);
    NSURLRequest *plain = batchRequest(p, modelID, prompt, key, YES, YES);
    if (!request) {
        done(nil, @"Invalid server URL");
        return;
    }
    SGLog(@"ai batch: asking %@ %@ (%lu songs, streaming) into %@, prompt %@", p->tag, modelID, (unsigned long)songs.count, languageTag, fingerprint(template));
    sendBatchStream(p, request, plain, songs, 0, onPhase, onSong, ^(NSData *data, NSString *accumulatedText, NSDictionary<NSString *, NSArray<NSString *> *> *streamedResults, NSString *streamStopped, NSInteger status, NSError *error) {
        NSString *who = speaker(p);
        NSString *stopped = streamStopped;
        NSDictionary *rawDict = nil;
        if (status == 200) {
            if (accumulatedText.length > 0) {
                rawDict = batchMapIn(accumulatedText);
            }
            if (!rawDict && data.length > 0) {
                id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if (root) rawDict = batchMapIn(p->answer(root, who, &stopped));
            }
        }
        
        NSMutableDictionary<NSString *, NSArray<NSString *> *> *results = [NSMutableDictionary dictionaryWithDictionary:streamedResults ?: @{}];
        if (rawDict) {
            NSUInteger songIndex = 0;
            for (NSString *trackKey in songs) {
                NSString *bareID = [trackKey hasPrefix:@"spotify:track:"] ? [trackKey substringFromIndex:@"spotify:track:".length] : trackKey;
                NSString *uriID = [@"spotify:track:" stringByAppendingString:bareID];
                id rawLines = rawDict[trackKey] ?: rawDict[bareID] ?: rawDict[uriID];
                if (!rawLines) {
                    for (NSString *k in rawDict) {
                        if ([k caseInsensitiveCompare:trackKey] == NSOrderedSame ||
                            [k caseInsensitiveCompare:bareID] == NSOrderedSame ||
                            [k caseInsensitiveCompare:uriID] == NSOrderedSame) {
                            rawLines = rawDict[k];
                            break;
                        }
                    }
                }
                if (!rawLines) {
                    rawLines = rawDict[@(songIndex).stringValue];
                }
                if ([rawLines isKindOfClass:NSDictionary.class]) {
                    if ([rawLines[@"lines"] isKindOfClass:NSArray.class]) rawLines = rawLines[@"lines"];
                    else if ([rawLines[@"translations"] isKindOfClass:NSArray.class]) rawLines = rawLines[@"translations"];
                }
                if ([rawLines isKindOfClass:NSArray.class]) {
                    NSMutableArray<NSString *> *clean = [NSMutableArray array];
                    for (id l in rawLines) [clean addObject:[l isKindOfClass:NSString.class] ? l : [l description]];
                    NSArray<NSString *> *expected = songs[trackKey];
                    if (expected && clean.count == expected.count) {
                        results[trackKey] = clean;
                        results[bareID] = clean;
                    }
                }
                songIndex++;
            }
        }
        
        NSUInteger answered = results.count / 2;
        NSString *problem = nil;
        if (answered >= songs.count) {
            // All songs in the chunk completed.
        } else if (error) {
            problem = error.code == NSURLErrorTimedOut
                ? [NSString stringWithFormat:@"%@ timed out", who]
                : [NSString stringWithFormat:@"Could not reach %@", who];
        } else if (status == 401 || status == 403) {
            problem = [NSString stringWithFormat:@"%@ rejected API key", who];
        } else if (status == 429) {
            problem = [NSString stringWithFormat:@"%@ rate limit reached", who];
        } else if (status >= 500) {
            problem = [NSString stringWithFormat:@"%@ is busy, try again", who];
        } else if (status != 200) {
            problem = [NSString stringWithFormat:@"%@ error (%ld)", who, (long)status];
        } else if (stopped) {
            problem = [NSString stringWithFormat:@"%@ stopped early", who];
        } else if (!answered) {
            problem = @"Could not read reply";
        } else {
            problem = [NSString stringWithFormat:@"%@ translated %lu of %lu songs", who, (unsigned long)answered, (unsigned long)songs.count];
        }
        
        SGLog(@"ai batch: %@ answered %lu of %lu songs into %@: %@", p->tag, (unsigned long)answered, (unsigned long)songs.count, languageTag, problem ?: @"ok");
        dispatch_async(dispatch_get_main_queue(), ^{
            done(results.count ? results : nil, problem);
        });
    });
}

#pragma mark - the rows

NSNotificationName const SGLyricsTranslationsDidChangeNotification = @"spotifyglass.lyricsTranslationsDidChange";

SGModRow *SGTranslateEverySongRow(void) {
    SGModRow *row = SGOptionRow(@"Translate any song", @"The lyrics' translate menu for songs that already read as your language",
                                SGKeyLyricsTranslateEverySong);
    row.changed = ^(BOOL on) {
        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
    };
    return row;
}

// The provider, its key, server or model changed: an open lyrics menu names who gets the lyrics, so it is built again.
static void translatorChanged(void) {
    [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
}

NSArray<SGModRow *> *SGOnDeviceTranslatorRows(void) {
    SGModRow *onDevice = SGSwitchRow(@"Translate on iPhone", @"Apple's Translate in the lyrics' translate menu", SGKeyLyricsTranslateOnDevice);
    SGModRow *intelligence = SGSwitchRow(@"Apple Intelligence", @"Apple Intelligence in the lyrics' translate menu", SGKeyLyricsAppleIntelligence);
    onDevice.changed = intelligence.changed = ^(BOOL on) { translatorChanged(); };
    return @[onDevice, intelligence];
}

void SGAIForgetKeys(void) {
    // One delete per provider's own service, every account in it (key and server), never another app's items.
    for (NSUInteger i = 0; i < kProviderCount; i++) {
        SecItemDelete((__bridge CFDictionaryRef)@{(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
                                                  (__bridge id)kSecAttrService: kProviders[i].service});
    }
    translatorChanged();
}

static void configure(UITextField *field, NSString *placeholder) {
    field.placeholder = placeholder;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
}

// The key comes from the clipboard and is never shown: a text field showed it on screen, where a screenshot
// catches it, and a secure field made iOS offer to save it in Passwords, which syncs it through iCloud. An
// OpenAI-compatible provider's server is typed above. Says what leaves the phone, not only where the key stays:
// each song translated goes to the provider whole.
static void askForKey(void) {
    const SGAIProvider *p = chosen();
    BOOL server = isOpenAI(p), stored = storedSecret(p, kKeyAccount) != nil;
    NSString *message = [p->keyNote stringByAppendingString:@"\n\nCopy the key, then tap Paste Key."];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ API key", p->name]
                                                                   message:message preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;   // over the dark settings, whatever the system's
    __weak UIAlertController *weakAlert = alert;
    void (^saveServer)(void) = ^{
        if (!server) return;
        NSString *url = SGAIServerIn(weakAlert.textFields.firstObject.text);
        storeSecret(p, kServerAccount, [url isEqualToString:kOpenAIDefaultURL] ? nil : url);
    };
    UIAlertAction *paste = [UIAlertAction actionWithTitle:@"Paste Key" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        // A key copied with the quotes around it, as from a code sample, is turned down as it stands.
        NSMutableCharacterSet *around = [NSMutableCharacterSet whitespaceAndNewlineCharacterSet];
        [around addCharactersInString:@"\"'“”‘’"];
        UIPasteboard *board = UIPasteboard.generalPasteboard;
        NSString *key = [board.string stringByTrimmingCharactersInSet:around];
        if (!key.length || [key rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location != NSNotFound) {
            UIAlertController *none = [UIAlertController alertControllerWithTitle:@"No key on the clipboard"
                                                                          message:@"Copy the API key, then tap Paste Key again."
                                                                   preferredStyle:UIAlertControllerStyleAlert];
            none.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            [none addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [SGTopController() presentViewController:none animated:YES completion:nil];
            return;
        }
        saveServer();
        storeSecret(p, kKeyAccount, key);
        // Left on the clipboard, Universal Clipboard would hand the key on to the user's other devices.
        board.items = @[];
        translatorChanged();
    }];
    UIAlertAction *save = server && stored ? [UIAlertAction actionWithTitle:@"Save Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        saveServer();
        translatorChanged();
    }] : nil;
    if (server) {
        __weak UIAlertAction *weakPaste = paste, *weakSave = save;
        [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
            configure(field, kOpenAIDefaultURL);
            field.text = storedSecret(p, kServerAccount);
            field.keyboardType = UIKeyboardTypeURL;
            field.textContentType = UITextContentTypeURL;
            [field addAction:[UIAction actionWithHandler:^(UIAction *action) {
                NSString *url = weakAlert.textFields.firstObject.text;
                BOOL usable = !url.length || SGAIServerIn(url);
                weakPaste.enabled = usable;
                weakSave.enabled = usable;
            }] forControlEvents:UIControlEventEditingChanged];
        }];
    }
    [alert addAction:paste];
    if (save) [alert addAction:save];
    if (stored) {
        [alert addAction:[UIAlertAction actionWithTitle:@"Remove" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
            storeSecret(p, kKeyAccount, nil);
            storeSecret(p, kServerAccount, nil);
            translatorChanged();
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static void askForModel(void) {
    const SGAIProvider *p = chosen();
    NSString *example = p->models[1] ?: p->models[0] ?: @"gpt-6-astra, or a model your server lists";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"%@ model", p->name]
        message:[NSString stringWithFormat:@"A model id, such as %@.", example] preferredStyle:UIAlertControllerStyleAlert];
    alert.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    __weak UIAlertController *weakAlert = alert;
    UIAlertAction *save = [UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *modelID = modelIDIn(weakAlert.textFields.firstObject.text, p);
        if (modelID) [NSUserDefaults.standardUserDefaults setObject:modelID forKey:modelKey(p)];
        translatorChanged();
    }];
    save.enabled = NO;
    __weak UIAlertAction *weakSave = save;
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        configure(field, p->models[0] ?: @"Model id");
        field.text = storedString(modelKey(p));
        __weak UITextField *weakField = field;
        [field addAction:[UIAction actionWithHandler:^(UIAction *action) { weakSave.enabled = modelIDIn(weakField.text, p) != nil; }]
        forControlEvents:UIControlEventEditingChanged];
    }];
    [alert addAction:save];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [SGTopController() presentViewController:alert animated:YES completion:nil];
}

static NSArray<NSString *> *modelMenu(const SGAIProvider *p) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < 4 && p->modelNames[i]; i++) [names addObject:p->modelNames[i]];
    [names addObject:@"Other…"];
    return names;
}

// The prompt in a sheet: the checkmark stores it, Default puts Vitrine's back in the field. Stored equal to the
// default, or empty, it is removed, so a later change to the default reaches it.
@interface SGPromptEditor : UIViewController
- (instancetype)initWithBatch:(BOOL)batch;
@end

@implementation SGPromptEditor {
    UITextView *_text;
    BOOL _batch;
}

- (instancetype)initWithBatch:(BOOL)batch {
    if (!(self = [super init])) return nil;
    _batch = batch;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _batch ? @"Batch prompt" : @"Translation prompt";
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    _text = [UITextView new];
    _text.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _text.adjustsFontForContentSizeCategory = YES;
    _text.backgroundColor = UIColor.clearColor;
    _text.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    _text.alwaysBounceVertical = YES;
    _text.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _text.text = _batch ? SGLyricsBatchPromptTemplate() : promptTemplate();
    _text.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_text];
    UILabel *note = [UILabel new];
    note.text = _batch ? @"For multi-song batch translations. {language} and {count} are filled in for each batch; "
                         @"the songs' lines follow as a JSON object mapping track IDs to arrays of lines."
                       : @"For every AI translator. {language} and {count} are filled in for each song; the translator is then "
                         @"told the shape of its answer, and the song's lines follow as a JSON array.";
    note.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    note.adjustsFontForContentSizeCategory = YES;
    note.textColor = UIColor.secondaryLabelColor;
    note.numberOfLines = 0;
    note.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:note];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [note.topAnchor constraintEqualToAnchor:safe.topAnchor constant:12],
        [note.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [note.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [_text.topAnchor constraintEqualToAnchor:note.bottomAnchor constant:4],
        [_text.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_text.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_text.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(close)];
    // Plain: Spotify's white tint fills a Done item's glass and hides its glyph.
    UIBarButtonItem *done = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"checkmark"] style:UIBarButtonItemStylePlain target:self action:@selector(save)];
    done.accessibilityLabel = @"Save";
    UIBarButtonItem *reset = [[UIBarButtonItem alloc] initWithTitle:@"Default" style:UIBarButtonItemStylePlain target:self action:@selector(reset)];
    self.navigationItem.rightBarButtonItems = @[done, reset];
}

- (void)close {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)reset {
    _text.text = _batch ? kDefaultBatchPrompt : kDefaultPrompt;
}

- (void)save {
    NSString *prompt = [_text.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *def = _batch ? kDefaultBatchPrompt : kDefaultPrompt;
    NSString *key = _batch ? SGKeyLyricsBatchPrompt : SGKeyAIPrompt;
    if (!prompt.length || [prompt isEqualToString:def]) [NSUserDefaults.standardUserDefaults removeObjectForKey:key];
    else [NSUserDefaults.standardUserDefaults setObject:prompt forKey:key];
    SGLog(@"ai: %@ prompt %@", _batch ? @"batch" : @"", storedString(key) ? [@"edited, " stringByAppendingString:fingerprint(prompt)] : @"default");
    [self close];
}
@end

NSArray<SGModRow *> *SGAITranslatorRows(void) {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < kProviderCount; i++) [names addObject:kProviders[i].name];
    // A pick in a menu row reloads the page's rows; the model row's menu is the chosen provider's presets.
    SGModRow *models = SGMenuRow(@"Model", modelMenu(chosen()), ^NSString *{
        const SGAIProvider *p = chosen();
        NSString *current = model(p);
        for (NSUInteger i = 0; i < 4 && p->models[i]; i++) if ([p->models[i] isEqualToString:current]) return p->modelNames[i];
        return current ?: @"Not set";
    }, nil);
    __weak SGModRow *weakModels = models;
    models.chosen = ^(NSInteger index) {
        const SGAIProvider *p = chosen();
        if (index == 0 && p->models[0]) [NSUserDefaults.standardUserDefaults removeObjectForKey:modelKey(p)];
        else if (index < 4 && p->models[index]) [NSUserDefaults.standardUserDefaults setObject:p->models[index] forKey:modelKey(p)];
        else askForModel();
        translatorChanged();
    };
    SGModRow *provider = SGMenuRow(@"AI translator", names, ^NSString *{ return chosen()->name; }, ^(NSInteger index) {
        if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAITranslator];
        else [NSUserDefaults.standardUserDefaults setObject:kProviders[index].tag forKey:SGKeyAITranslator];
        weakModels.menu = modelMenu(chosen());
        SGLog(@"ai: translator %@", chosen()->tag);
        translatorChanged();
    });
    SGModRow *key = SGStatActionRow(@"API key", @"Translate any song from the lyrics' corner menu", ^NSString *{
        const SGAIProvider *p = chosen();
        if (!storedSecret(p, kKeyAccount)) return @"Off";
        return isOpenAI(p) ? serverHost() ?: @"Server not usable" : @"Set";
    }, ^{ askForKey(); });
    SGModRow *prompt = SGStatActionRow(@"Translation prompt", @"What the AI translator is told to do with a song's lines",
                                       ^NSString *{ return storedString(SGKeyAIPrompt) ? @"Edited" : @"Default"; }, ^{
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[SGPromptEditor new]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        SGPresentDark(nav);
        [SGTopController() presentViewController:nav animated:YES completion:nil];
    });
    // Low first: 3.8 Flash refuses minimal.
    NSArray<NSString *> *thinkingLevels = @[@"Low", @"Medium", @"High"];
    SGModRow *thinking = SGMenuRow(@"Thinking", thinkingLevels, ^NSString *{
        return geminiThinkingLevel().capitalizedString;
    }, ^(NSInteger index) {
        if (index == 0) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAIThinking];
        else [NSUserDefaults.standardUserDefaults setObject:thinkingLevels[index].lowercaseString forKey:SGKeyAIThinking];
        translatorChanged();
    });
    thinking.visible = ^{ return [chosen()->tag isEqualToString:@"gemini"]; };

    NSArray<NSNumber *> *timeoutSeconds = @[@30, @60, @90, @(kDefaultAITimeout), @180, @240, @300];
    NSMutableArray<NSString *> *timeouts = [NSMutableArray array];
    for (NSNumber *seconds in timeoutSeconds) [timeouts addObject:[NSString stringWithFormat:@"%@ s", seconds]];
    SGModRow *timeout = SGMenuRow(@"Timeout", timeouts, ^NSString *{
        return [NSString stringWithFormat:@"%ld s", (long)aiTimeout()];
    }, ^(NSInteger index) {
        NSInteger seconds = timeoutSeconds[index].integerValue;
        if (seconds == kDefaultAITimeout) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyAITimeout];
        else [NSUserDefaults.standardUserDefaults setInteger:seconds forKey:SGKeyAITimeout];
    });

    NSArray<NSNumber *> *batchSizes = @[@10, @20, @30, @40, @50, @0];
    NSArray<NSString *> *batchSizeOptions = @[@"10 songs", @"20 songs", @"30 songs", @"40 songs", @"50 songs", @"All at once"];
    SGModRow *batchSizeRow = SGMenuRow(@"Songs per batch", batchSizeOptions, ^NSString *{
        NSUInteger idx = [batchSizes indexOfObject:@(SGLyricsBatchSize())];
        return batchSizeOptions[idx != NSNotFound ? idx : 1];
    }, ^(NSInteger index) {
        NSUInteger size = batchSizes[index].unsignedIntegerValue;
        if (size == 20) [NSUserDefaults.standardUserDefaults removeObjectForKey:SGKeyLyricsBatchSize];
        else [NSUserDefaults.standardUserDefaults setInteger:size forKey:SGKeyLyricsBatchSize];
    });
    SGModRow *batchPromptRow = SGStatActionRow(@"Batch prompt", @"Prompt used when translating multiple songs at once",
                                               ^NSString *{ return storedString(SGKeyLyricsBatchPrompt) ? @"Edited" : @"Default"; }, ^{
        UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:[[SGPromptEditor alloc] initWithBatch:YES]];
        nav.modalPresentationStyle = UIModalPresentationPageSheet;
        SGPresentDark(nav);
        [SGTopController() presentViewController:nav animated:YES completion:nil];
    });
    SGModRow *skipSavedRow = SGSwitchRow(@"Skip saved translations", @"Skip songs that already have a saved translation", SGKeyLyricsBatchSkipSaved);
    return @[provider, key, models, thinking, timeout, prompt, batchSizeRow, batchPromptRow, skipSavedRow];
}
