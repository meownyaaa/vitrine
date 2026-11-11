#import "MRGAI.h"
#import "MRGKeychain.h"

// Endpoints and model choices checked against each provider's docs in November 2026 (sources in
// docs/mirage/AI-DJ.md). Key formats:
//   AIza…  Gemini          sk-ant-…  Anthropic        sk-or-…  OpenRouter     gsk_…  Groq
//   xai-…  xAI             pplx-…    Perplexity       csk-…    Cerebras       fw_… / fw-…  Fireworks
//   tgp_v1_… / tgp_v1-…  Together    sk- + 32 hex  DeepSeek    sk-proj-… / sk-svcacct-… / other sk-…  OpenAI

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }

MRGProvider MRGDetectProvider(NSString *raw) {
    NSString *key = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (key.length < 10) return MRGProviderNone;
    if ([key hasPrefix:@"AIza"]) return MRGProviderGemini;
    if ([key hasPrefix:@"sk-ant-"]) return MRGProviderAnthropic;
    if ([key hasPrefix:@"sk-or-"]) return MRGProviderOpenRouter;
    if ([key hasPrefix:@"gsk_"]) return MRGProviderGroq;
    if ([key hasPrefix:@"xai-"]) return MRGProviderXAI;
    if ([key hasPrefix:@"pplx-"]) return MRGProviderPerplexity;
    if ([key hasPrefix:@"csk-"]) return MRGProviderCerebras;
    if ([key hasPrefix:@"fw_"] || [key hasPrefix:@"fw-"]) return MRGProviderFireworks;
    if ([key hasPrefix:@"tgp_v1_"] || [key hasPrefix:@"tgp_v1-"]) return MRGProviderTogether;
    if ([key hasPrefix:@"sk-proj-"] || [key hasPrefix:@"sk-svcacct-"] || [key hasPrefix:@"sk-admin-"]) return MRGProviderOpenAI;
    if ([key hasPrefix:@"sk-"]) {
        NSString *rest = [key substringFromIndex:3];
        NSCharacterSet *notHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
        if (rest.length == 32 && [rest rangeOfCharacterFromSet:notHex].location == NSNotFound) return MRGProviderDeepSeek;
        return MRGProviderOpenAI;
    }
    return MRGProviderNone;
}

NSString *MRGProviderName(MRGProvider p) {
    switch (p) {
        case MRGProviderOpenAI: return @"OpenAI";
        case MRGProviderGemini: return @"Google Gemini";
        case MRGProviderAnthropic: return @"Anthropic";
        case MRGProviderOpenRouter: return @"OpenRouter";
        case MRGProviderGroq: return @"Groq";
        case MRGProviderXAI: return @"xAI";
        case MRGProviderPerplexity: return @"Perplexity";
        case MRGProviderCerebras: return @"Cerebras";
        case MRGProviderFireworks: return @"Fireworks";
        case MRGProviderTogether: return @"Together";
        case MRGProviderDeepSeek: return @"DeepSeek";
        default: return @"Unknown";
    }
}

BOOL MRGProviderHasTTS(MRGProvider p) { return p == MRGProviderOpenAI || p == MRGProviderGemini; }

static NSString *baseURL(MRGProvider p) {
    switch (p) {
        case MRGProviderOpenAI: return @"https://api.openai.com/v1";
        case MRGProviderGemini: return @"https://generativelanguage.googleapis.com/v1beta";
        case MRGProviderAnthropic: return @"https://api.anthropic.com/v1";
        case MRGProviderOpenRouter: return @"https://openrouter.ai/api/v1";
        case MRGProviderGroq: return @"https://api.groq.com/openai/v1";
        case MRGProviderXAI: return @"https://api.x.ai/v1";
        case MRGProviderPerplexity: return @"https://api.perplexity.ai/v1";
        case MRGProviderCerebras: return @"https://api.cerebras.ai/v1";
        case MRGProviderFireworks: return @"https://api.fireworks.ai/inference/v1";
        case MRGProviderTogether: return @"https://api.together.xyz/v1";
        case MRGProviderDeepSeek: return @"https://api.deepseek.com";
        default: return nil;
    }
}

#pragma mark - model choice

// In order of preference: fast, cheap chat models good enough to know music. A pattern's * matches
// anything, and a date or version suffix after the pattern is allowed (claude-haiku-4-5-20251001). Where
// several match one pattern, a non-preview beats a preview, then the higher version, then the shorter id.
static NSArray<NSString *> *preferences(MRGProvider p) {
    switch (p) {
        case MRGProviderOpenAI: return @[@"gpt-4.1-mini", @"gpt-6-luna", @"gpt-5.6-luna", @"gpt-5.4-mini", @"gpt-5-mini",
                                         @"gpt-4o-mini", @"gpt-5.4-nano", @"gpt-5-nano", @"gpt-4.1", @"gpt-4o"];
        case MRGProviderGemini: return @[@"gemini-*-flash-lite", @"gemini-flash-lite-latest", @"gemini-*-flash", @"gemini-flash-latest"];
        case MRGProviderAnthropic: return @[@"claude-haiku-*", @"claude-*-haiku", @"claude-sonnet-*", @"claude-*-sonnet"];
        case MRGProviderOpenRouter: return @[@"google/gemini-*-flash-lite", @"openai/gpt-4.1-mini", @"anthropic/claude-haiku-*",
                                             @"openai/gpt-oss-120b", @"x-ai/grok-4.3", @"meta-llama/llama-3.3-70b-instruct"];
        case MRGProviderGroq: return @[@"openai/gpt-oss-120b", @"openai/gpt-oss-20b", @"qwen/qwen3*", @"llama-3.3-70b-versatile", @"llama*"];
        case MRGProviderXAI: return @[@"grok-4.3", @"grok-4.20-*non-reasoning", @"grok-4.20*", @"grok-4.5", @"grok-4*", @"grok-*"];
        case MRGProviderPerplexity: return @[@"perplexity/glm-*-flash", @"openai/gpt-6-luna", @"google/gemini-*-flash",
                                             @"openai/gpt-*-luna", @"anthropic/claude-haiku-*", @"perplexity/sonar", @"sonar"];
        case MRGProviderCerebras: return @[@"gpt-oss-120b", @"llama-3.3-70b", @"qwen-3-*", @"llama*"];
        case MRGProviderFireworks: return @[@"accounts/fireworks/models/gpt-oss-120b", @"accounts/fireworks/models/gpt-oss-20b",
                                            @"accounts/fireworks/models/llama-v3p3-70b-instruct", @"accounts/fireworks/models/deepseek-v3*",
                                            @"accounts/fireworks/models/qwen3*"];
        case MRGProviderTogether: return @[@"openai/gpt-oss-120b", @"meta-llama/Llama-3.3-70B-Instruct-Turbo", @"openai/gpt-oss-20b",
                                           @"Qwen/Qwen3*", @"deepseek-ai/DeepSeek-V3*"];
        case MRGProviderDeepSeek: return @[@"deepseek-chat", @"deepseek-flash*", @"deepseek-v*-flash*", @"deepseek-*"];
        default: return @[];
    }
}

// Not chat models, or chat models that are slow or odd for this (search, reasoning-only, audio, images).
static BOOL unsuitable(NSString *model) {
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"(embed|tts|whisper|transcri|audio|realtime|image|imagen|vision|moderation|guard|dall-e|sora|veo|live|"
              @"computer-use|search|codex|lyria|aqa|robotics|deep-research|thinking|rerank|orpheus|playai|speech|"
              @"flux|diffusion|babbage|davinci|instruct-0|reasoner|:)"
                                                       options:NSRegularExpressionCaseInsensitive error:nil];
    });
    return [re firstMatchInString:model options:0 range:NSMakeRange(0, model.length)] != nil;
}

static BOOL matches(NSString *pattern, NSString *model) {
    NSString *escaped = [NSRegularExpression escapedPatternForString:pattern];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\\*" withString:@".*"];
    NSString *full = [NSString stringWithFormat:@"^%@([-@][0-9][-0-9a-z.]*)?$", escaped];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:full options:NSRegularExpressionCaseInsensitive error:nil];
    return [re firstMatchInString:model options:0 range:NSMakeRange(0, model.length)] != nil;
}

static BOOL isPreview(NSString *m) {
    NSString *l = m.lowercaseString;
    return [l containsString:@"preview"] || [l containsString:@"-exp"] || [l containsString:@"beta"];
}

static NSArray<NSString *> *ranked(NSArray<NSString *> *ids) {
    return [ids sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        BOOL pa = isPreview(a), pb = isPreview(b);
        if (pa != pb) return pa ? NSOrderedDescending : NSOrderedAscending;
        NSComparisonResult v = [b compare:a options:NSNumericSearch | NSCaseInsensitiveSearch];
        if (v != NSOrderedSame && a.length == b.length) return v;
        // A longer id that is the shorter one plus a suffix (a dated snapshot) after the alias.
        if ([a hasPrefix:b] || [b hasPrefix:a]) return a.length < b.length ? NSOrderedAscending : NSOrderedDescending;
        return v;
    }];
}

NSString *MRGAIPickModel(MRGProvider provider, NSArray<NSString *> *ids) {
    NSMutableArray *ok = [NSMutableArray array];
    for (NSString *m in ids) if ([m isKindOfClass:NSString.class] && !unsuitable(m)) [ok addObject:m];
    for (NSString *pattern in preferences(provider)) {
        NSMutableArray *hits = [NSMutableArray array];
        for (NSString *m in ok) if (matches(pattern, m)) [hits addObject:m];
        if (hits.count) return ranked(hits).firstObject;
    }
    return ranked(ok).firstObject;
}

#pragma mark - saved state

static NSString *const kProviderKey = @"mirage.dj.provider";
static NSString *const kModelsKey = @"mirage.dj.models";
static NSString *const kAllModelsKey = @"mirage.dj.allModels";
static NSString *const kRecommendedKey = @"mirage.dj.recommended";
static NSString *const kOverrideKey = @"mirage.dj.model";

MRGProvider MRGAIProvider(void) { return MRGKeychainAPIKey() ? [D() integerForKey:kProviderKey] : MRGProviderNone; }
NSString *MRGAIRecommendedModel(void) { return [D() stringForKey:kRecommendedKey]; }
NSArray<NSString *> *MRGAIModels(void) { return [D() arrayForKey:kModelsKey] ?: @[]; }
NSString *MRGAIModel(void) { return [D() stringForKey:kOverrideKey] ?: MRGAIRecommendedModel(); }
BOOL MRGAIHasOverride(void) { return [D() stringForKey:kOverrideKey] != nil; }
void MRGAISetModelOverride(NSString *model) {
    if (model.length && ![model isEqualToString:MRGAIRecommendedModel()]) [D() setObject:model forKey:kOverrideKey];
    else [D() removeObjectForKey:kOverrideKey];
}

void MRGAIForgetKey(void) {
    MRGKeychainSetAPIKey(nil);
    for (NSString *k in @[kProviderKey, kModelsKey, kAllModelsKey, kRecommendedKey, kOverrideKey]) [D() removeObjectForKey:k];
}

#pragma mark - HTTP

static NSMutableURLRequest *request(MRGProvider p, NSString *key, NSString *path, NSDictionary *body) {
    NSURL *url = [NSURL URLWithString:[baseURL(p) stringByAppendingString:path]];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 45;
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    switch (p) {
        case MRGProviderGemini: [r setValue:key forHTTPHeaderField:@"x-goog-api-key"]; break;
        case MRGProviderAnthropic:
            [r setValue:key forHTTPHeaderField:@"x-api-key"];
            [r setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
            break;
        default: [r setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"]; break;
    }
    if (p == MRGProviderOpenRouter) {
        [r setValue:@"https://github.com/x4nzz/Mirage" forHTTPHeaderField:@"HTTP-Referer"];
        [r setValue:@"Mirage DJ" forHTTPHeaderField:@"X-Title"];
    }
    if (body) {
        r.HTTPMethod = @"POST";
        [r setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        r.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    }
    return r;
}

// The provider's own error text where it gives one, else a plain reason by status.
static NSString *errorMessage(MRGProvider p, NSInteger status, NSData *data, NSError *error) {
    NSString *name = MRGProviderName(p);
    if (error) {
        if (error.code == NSURLErrorNotConnectedToInternet || error.code == NSURLErrorNetworkConnectionLost)
            return @"You're offline. Connect and try again.";
        if (error.code == NSURLErrorTimedOut) return [NSString stringWithFormat:@"%@ took too long to answer. Try again.", name];
        return [NSString stringWithFormat:@"Couldn't reach %@: %@", name, error.localizedDescription];
    }
    NSString *detail = nil;
    id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([json isKindOfClass:NSDictionary.class]) {
        id e = json[@"error"];
        if ([e isKindOfClass:NSDictionary.class] && [e[@"message"] isKindOfClass:NSString.class]) detail = e[@"message"];
        else if ([e isKindOfClass:NSString.class]) detail = e;
        else if ([json[@"message"] isKindOfClass:NSString.class]) detail = json[@"message"];
    }
    if (detail.length > 200) detail = [[detail substringToIndex:200] stringByAppendingString:@"…"];
    NSString *base;
    if (status == 401 || status == 403) base = [NSString stringWithFormat:@"%@ rejected this key. Check it and paste it again.", name];
    else if (status == 402) base = [NSString stringWithFormat:@"%@ says this key is out of credit.", name];
    else if (status == 429) base = [NSString stringWithFormat:@"%@ is rate-limiting this key (or it's out of quota). Wait a minute and try again.", name];
    else if (status >= 500) base = [NSString stringWithFormat:@"%@ is having trouble right now (HTTP %ld). Try again soon.", name, (long)status];
    else base = [NSString stringWithFormat:@"%@ answered HTTP %ld.", name, (long)status];
    return detail.length ? [NSString stringWithFormat:@"%@\n\n%@", base, detail] : base;
}

static void send(MRGProvider p, NSURLRequest *r, void (^done)(id json, NSData *data, NSInteger status, NSString *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *message = (error || status < 200 || status >= 300) ? errorMessage(p, status, data, error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(json, data, status, message); });
    }] resume];
}

#pragma mark - setup

static NSArray<NSString *> *modelIDs(MRGProvider p, id json) {
    NSMutableArray *ids = [NSMutableArray array];
    if (p == MRGProviderGemini) {
        for (NSDictionary *m in [json isKindOfClass:NSDictionary.class] ? json[@"models"] : nil) {
            if (![m isKindOfClass:NSDictionary.class]) continue;
            NSArray *methods = m[@"supportedGenerationMethods"];
            NSString *name = m[@"name"];
            if (![name isKindOfClass:NSString.class]) continue;
            if ([methods isKindOfClass:NSArray.class] && ![methods containsObject:@"generateContent"]) continue;
            [ids addObject:[name hasPrefix:@"models/"] ? [name substringFromIndex:7] : name];
        }
        return ids;
    }
    // OpenAI's list shape ({"data": [...]}) everywhere else; Together answers a bare array, typed.
    NSArray *list = [json isKindOfClass:NSArray.class] ? json : ([json isKindOfClass:NSDictionary.class] ? json[@"data"] : nil);
    for (NSDictionary *m in [list isKindOfClass:NSArray.class] ? list : nil) {
        if (![m isKindOfClass:NSDictionary.class] || ![m[@"id"] isKindOfClass:NSString.class]) continue;
        if ([m[@"type"] isKindOfClass:NSString.class] && p == MRGProviderTogether && ![m[@"type"] isEqualToString:@"chat"]) continue;
        [ids addObject:m[@"id"]];
    }
    return ids;
}

static NSString *modelsPath(MRGProvider p) {
    switch (p) {
        case MRGProviderGemini: return @"/models?pageSize=1000";
        case MRGProviderAnthropic: return @"/models?limit=1000";
        default: return @"/models";
    }
}

static void finishSetup(MRGProvider p, NSString *key, NSArray<NSString *> *all, void (^done)(BOOL, NSString *)) {
    NSMutableArray *chat = [NSMutableArray array];
    for (NSString *m in all) if (!unsuitable(m)) [chat addObject:m];
    NSString *pick = MRGAIPickModel(p, all);
    if (!pick) { done(NO, [NSString stringWithFormat:@"%@ accepted the key but listed no chat model it can use.", MRGProviderName(p)]); return; }
    if (!MRGKeychainSetAPIKey(key)) { done(NO, @"Couldn't save the key on this phone."); return; }
    [D() setInteger:p forKey:kProviderKey];
    [D() setObject:[chat sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)] forKey:kModelsKey];
    [D() setObject:all forKey:kAllModelsKey];
    [D() setObject:pick forKey:kRecommendedKey];
    NSString *override = [D() stringForKey:kOverrideKey];
    if (override && ![all containsObject:override]) [D() removeObjectForKey:kOverrideKey];
    done(YES, [NSString stringWithFormat:@"%@ key saved. Using %@.", MRGProviderName(p), MRGAIModel()]);
}

void MRGAISetupKey(NSString *raw, void (^done)(BOOL, NSString *)) {
    NSString *key = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    MRGProvider p = MRGDetectProvider(key);
    if (p == MRGProviderNone) {
        done(NO, @"That doesn't look like an API key Mirage knows. Supported: OpenAI, Gemini, Anthropic, OpenRouter, Groq, xAI, Perplexity, Cerebras, Fireworks, Together, DeepSeek.");
        return;
    }
    send(p, request(p, key, modelsPath(p), nil), ^(id json, NSData *data, NSInteger status, NSString *error) {
        if (error) { done(NO, error); return; }
        NSArray *ids = modelIDs(p, json);
        // OpenRouter's and Perplexity's model lists are public, so they say nothing about the key: check it too.
        if (p == MRGProviderOpenRouter) {
            send(p, request(p, key, @"/key", nil), ^(id j2, NSData *d2, NSInteger s2, NSString *e2) {
                if (e2) done(NO, e2); else finishSetup(p, key, ids, done);
            });
            return;
        }
        if (p == MRGProviderPerplexity) {
            NSString *model = MRGAIPickModel(p, ids) ?: @"perplexity/sonar";
            NSDictionary *body = @{@"model": model, @"input": @"Say ok.", @"max_output_tokens": @16};
            send(p, request(p, key, @"/agent", body), ^(id j2, NSData *d2, NSInteger s2, NSString *e2) {
                if (e2) done(NO, e2); else finishSetup(p, key, ids.count ? ids : @[@"perplexity/sonar"], done);
            });
            return;
        }
        finishSetup(p, key, ids, done);
    });
}

#pragma mark - chat

static BOOL isReasoningOpenAI(NSString *m) {
    return [m hasPrefix:@"gpt-5"] || [m hasPrefix:@"gpt-6"] || [m hasPrefix:@"o1"] || [m hasPrefix:@"o3"] || [m hasPrefix:@"o4"];
}

static NSString *textFromOpenAI(id json) {
    id choices = [json isKindOfClass:NSDictionary.class] ? json[@"choices"] : nil;
    id msg = [choices isKindOfClass:NSArray.class] && [choices count] ? [choices[0] valueForKey:@"message"] : nil;
    id content = [msg isKindOfClass:NSDictionary.class] ? msg[@"content"] : nil;
    return [content isKindOfClass:NSString.class] ? content : nil;
}

static NSString *textFromGemini(id json) {
    NSMutableString *out = [NSMutableString string];
    id cands = [json isKindOfClass:NSDictionary.class] ? json[@"candidates"] : nil;
    id parts = [cands isKindOfClass:NSArray.class] && [cands count] ? [[cands[0] valueForKey:@"content"] valueForKey:@"parts"] : nil;
    for (id part in [parts isKindOfClass:NSArray.class] ? parts : nil) {
        if (![part isKindOfClass:NSDictionary.class] || [part[@"thought"] boolValue]) continue;
        if ([part[@"text"] isKindOfClass:NSString.class]) [out appendString:part[@"text"]];
    }
    return out.length ? out : nil;
}

static NSString *textFromAnthropic(id json) {
    NSMutableString *out = [NSMutableString string];
    for (id block in [json isKindOfClass:NSDictionary.class] && [json[@"content"] isKindOfClass:NSArray.class] ? json[@"content"] : nil) {
        if ([block isKindOfClass:NSDictionary.class] && [block[@"type"] isEqual:@"text"] && [block[@"text"] isKindOfClass:NSString.class])
            [out appendString:block[@"text"]];
    }
    return out.length ? out : nil;
}

// Responses-shaped (Perplexity's Agent API): output_text when given, else the message items' text parts.
static NSString *textFromResponses(id json) {
    if (![json isKindOfClass:NSDictionary.class]) return nil;
    if ([json[@"output_text"] isKindOfClass:NSString.class]) return json[@"output_text"];
    NSMutableString *out = [NSMutableString string];
    for (id item in [json[@"output"] isKindOfClass:NSArray.class] ? json[@"output"] : nil) {
        id content = [item isKindOfClass:NSDictionary.class] ? item[@"content"] : nil;
        for (id part in [content isKindOfClass:NSArray.class] ? content : nil) {
            if ([part isKindOfClass:NSDictionary.class] && [part[@"text"] isKindOfClass:NSString.class]) [out appendString:part[@"text"]];
        }
    }
    return out.length ? out : nil;
}

static NSDictionary *openAIBody(MRGProvider p, NSString *model, NSString *system, NSString *user, BOOL json, BOOL extras) {
    NSMutableDictionary *b = [@{@"model": model, @"messages": @[@{@"role": @"system", @"content": system},
                                                                @{@"role": @"user", @"content": user}]} mutableCopy];
    if (!extras) return b;
    BOOL reasoning = (p == MRGProviderOpenAI && isReasoningOpenAI(model)) || [model containsString:@"gpt-oss"];
    if (!reasoning) b[@"temperature"] = @0.9;
    if (reasoning) b[@"reasoning_effort"] = @"low";
    if (p == MRGProviderXAI && [model hasPrefix:@"grok-4.3"]) b[@"reasoning_effort"] = @"none";
    if (json) b[@"response_format"] = @{@"type": @"json_object"};
    return b;
}

void MRGAIChat(NSString *system, NSString *user, BOOL json, void (^done)(NSString *, NSString *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = MRGKeychainAPIKey(), *model = MRGAIModel();
    if (p == MRGProviderNone || !key || !model) { done(nil, @"Add an API key in Mirage settings first."); return; }
    void (^finish)(NSString *, NSString *) = ^(NSString *text, NSString *error) {
        if (!error && !text.length) error = [NSString stringWithFormat:@"%@ sent an empty answer. Try again.", MRGProviderName(p)];
        done(error ? nil : text, error);
    };
    switch (p) {
        case MRGProviderGemini: {
            NSMutableDictionary *config = [@{@"temperature": @0.9} mutableCopy];
            if (json) config[@"responseMimeType"] = @"application/json";
            NSDictionary *body = @{@"systemInstruction": @{@"parts": @[@{@"text": system}]},
                                   @"contents": @[@{@"role": @"user", @"parts": @[@{@"text": user}]}],
                                   @"generationConfig": config};
            NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", model];
            send(p, request(p, key, path, body), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(textFromGemini(j), e); });
            return;
        }
        case MRGProviderAnthropic: {
            NSDictionary *body = @{@"model": model, @"max_tokens": @1500, @"system": system, @"temperature": @0.9,
                                   @"messages": @[@{@"role": @"user", @"content": user}]};
            send(p, request(p, key, @"/messages", body), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(textFromAnthropic(j), e); });
            return;
        }
        case MRGProviderPerplexity: {
            NSDictionary *body = @{@"model": model, @"instructions": system, @"input": user, @"max_output_tokens": @1500};
            send(p, request(p, key, @"/agent", body), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(textFromResponses(j), e); });
            return;
        }
        default: {
            // Temperature, reasoning effort and JSON mode first; a 400 (a model that takes one of them not)
            // gets the plain request once more.
            send(p, request(p, key, @"/chat/completions", openAIBody(p, model, system, user, json, YES)), ^(id j, NSData *d, NSInteger s, NSString *e) {
                if (s == 400) {
                    send(p, request(p, key, @"/chat/completions", openAIBody(p, model, system, user, json, NO)), ^(id j2, NSData *d2, NSInteger s2, NSString *e2) {
                        finish(textFromOpenAI(j2), e2);
                    });
                    return;
                }
                finish(textFromOpenAI(j), e);
            });
            return;
        }
    }
}

#pragma mark - speech

static NSString *ttsModel(MRGProvider p) {
    NSArray *all = [D() arrayForKey:kAllModelsKey] ?: @[];
    NSMutableArray *tts = [NSMutableArray array];
    for (NSString *m in all) if ([m isKindOfClass:NSString.class] && [m.lowercaseString containsString:@"tts"]) [tts addObject:m];
    if (p == MRGProviderOpenAI) {
        for (NSString *want in @[@"gpt-4o-mini-tts", @"tts-1"]) if ([tts containsObject:want]) return want;
        return ranked(tts).firstObject ?: @"gpt-4o-mini-tts";
    }
    NSMutableArray *flash = [NSMutableArray array];
    for (NSString *m in tts) if ([m containsString:@"flash"]) [flash addObject:m];
    return ranked(flash).firstObject ?: ranked(tts).firstObject ?: @"gemini-2.5-flash-preview-tts";
}

// Gemini's speech is raw 16-bit mono PCM at 24 kHz: a WAV header makes it playable.
static NSData *wavFromPCM(NSData *pcm) {
    NSMutableData *wav = [NSMutableData dataWithCapacity:pcm.length + 44];
    uint32_t rate = 24000, byteRate = rate * 2, dataLen = (uint32_t)pcm.length, riffLen = dataLen + 36;
    uint16_t fmt = 1, channels = 1, align = 2, bits = 16;
    uint32_t fmtLen = 16;
    [wav appendBytes:"RIFF" length:4]; [wav appendBytes:&riffLen length:4]; [wav appendBytes:"WAVE" length:4];
    [wav appendBytes:"fmt " length:4]; [wav appendBytes:&fmtLen length:4]; [wav appendBytes:&fmt length:2];
    [wav appendBytes:&channels length:2]; [wav appendBytes:&rate length:4]; [wav appendBytes:&byteRate length:4];
    [wav appendBytes:&align length:2]; [wav appendBytes:&bits length:2];
    [wav appendBytes:"data" length:4]; [wav appendBytes:&dataLen length:4];
    [wav appendData:pcm];
    return wav;
}

void MRGAISpeech(NSString *text, void (^done)(NSData *, NSString *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = MRGKeychainAPIKey();
    if (!key || !MRGProviderHasTTS(p)) { done(nil, @"This provider has no voice; using the phone's."); return; }
    if (p == MRGProviderOpenAI) {
        NSDictionary *body = @{@"model": ttsModel(p), @"voice": @"ash", @"input": text, @"response_format": @"mp3",
                               @"instructions": @"A relaxed, upbeat late-night radio DJ. Casual, warm, quick."};
        NSMutableURLRequest *r = request(p, key, @"/audio/speech", body);
        [r setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
        send(p, r, ^(id j, NSData *d, NSInteger s, NSString *e) { done(e ? nil : d, e); });
        return;
    }
    NSDictionary *body = @{@"contents": @[@{@"parts": @[@{@"text": [@"Say casually, like a laid-back radio DJ: " stringByAppendingString:text]}]}],
                           @"generationConfig": @{@"responseModalities": @[@"AUDIO"],
                                                  @"speechConfig": @{@"voiceConfig": @{@"prebuiltVoiceConfig": @{@"voiceName": @"Puck"}}}}};
    NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", ttsModel(p)];
    send(p, request(p, key, path, body), ^(id j, NSData *d, NSInteger s, NSString *e) {
        if (e) { done(nil, e); return; }
        id cands = [j isKindOfClass:NSDictionary.class] ? j[@"candidates"] : nil;
        id parts = [cands isKindOfClass:NSArray.class] && [cands count] ? [[cands[0] valueForKey:@"content"] valueForKey:@"parts"] : nil;
        NSString *b64 = nil;
        for (id part in [parts isKindOfClass:NSArray.class] ? parts : nil) {
            id inline_ = [part isKindOfClass:NSDictionary.class] ? part[@"inlineData"] : nil;
            if ([inline_ isKindOfClass:NSDictionary.class] && [inline_[@"data"] isKindOfClass:NSString.class]) { b64 = inline_[@"data"]; break; }
        }
        NSData *pcm = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        done(pcm.length ? wavFromPCM(pcm) : nil, pcm.length ? nil : @"Gemini sent no audio.");
    });
}
