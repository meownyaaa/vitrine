#import <QuartzCore/QuartzCore.h>
#import "MRGAI.h"
#import "MRGDJLog.h"
#import "MRGKeychain.h"

// Endpoints and model choices checked against each provider's docs in November 2026 (sources in
// docs/mirage/AI-DJ.md). Key formats:
//   AIza…  Gemini          sk-ant-…  Anthropic        sk-or-…  OpenRouter     gsk_…  Groq
//   xai-…  xAI             pplx-…    Perplexity       csk-…    Cerebras       fw_… / fw-…  Fireworks
//   tgp_v1_… / tgp_v1-…  Together    sk- + 32 hex  DeepSeek    sk-proj-… / sk-svcacct-… / other sk-…  OpenAI
//   AQ.…   Gemini auth keys (AI Studio makes these since May 2026; the older AIza… standard keys still work when
//          restricted to the Gemini API). Mistral keys have no prefix (32 letters and digits): chosen by hand.

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }
// Typed JSON access (no KVC: valueForKey: on an array maps over it, and on a string throws).
static id dictGet(id obj, NSString *key) { return [obj isKindOfClass:NSDictionary.class] ? ((NSDictionary *)obj)[key] : nil; }
static id firstOf(id arr) { return [arr isKindOfClass:NSArray.class] && [arr count] ? [arr firstObject] : nil; }

MRGProvider MRGDetectProvider(NSString *raw) {
    NSString *key = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (key.length < 10) return MRGProviderNone;
    if ([key hasPrefix:@"AIza"] || [key hasPrefix:@"AQ."]) return MRGProviderGemini;
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
        case MRGProviderMistral: return @"Mistral";
        default: return @"Unknown";
    }
}

NSArray<NSNumber *> *MRGAllProviders(void) {
    return @[@(MRGProviderOpenAI), @(MRGProviderGemini), @(MRGProviderAnthropic), @(MRGProviderOpenRouter), @(MRGProviderGroq),
             @(MRGProviderXAI), @(MRGProviderMistral), @(MRGProviderDeepSeek), @(MRGProviderPerplexity), @(MRGProviderCerebras),
             @(MRGProviderFireworks), @(MRGProviderTogether)];
}

BOOL MRGProviderHasTTS(MRGProvider p) {
    return p == MRGProviderOpenAI || p == MRGProviderGemini || p == MRGProviderXAI || p == MRGProviderGroq;
}

BOOL MRGProviderHasTools(MRGProvider p) { return p != MRGProviderNone && p != MRGProviderPerplexity; }

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
        case MRGProviderMistral: return @"https://api.mistral.ai/v1";
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
        case MRGProviderMistral: return @[@"mistral-small-latest", @"mistral-medium-latest", @"ministral-8b-latest", @"mistral-large-latest", @"mistral-*"];
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
              @"flux|diffusion|babbage|davinci|instruct-0|reasoner|ocr|codestral|devstral|pixtral|voxtral|magistral|:)"
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
static NSString *const kGeminiQueryKey = @"mirage.dj.geminiKeyInQuery";

// The backup key (optional): when the main key answers 429 (out of tokens or rate-limited), the DJ uses the backup's
// provider and model for 30 minutes.
static NSString *const kBackupKey = @"ai-key-backup";
static CFTimeInterval sg_backupUntil;
MRGProvider MRGAIBackupProvider(void) {
    if (!MRGKeychainGet(kBackupKey).length) return MRGProviderNone;
    NSInteger p = [D() integerForKey:@"mirage.dj.backupProvider"];
    return [MRGAllProviders() containsObject:@(p)] ? p : MRGProviderNone;
}
NSString *MRGAIBackupModel(void) { return [D() stringForKey:@"mirage.dj.backupModel"]; }
static BOOL backupActive(void) { return sg_backupUntil > CACurrentMediaTime() && MRGAIBackupProvider() != MRGProviderNone && MRGAIBackupModel().length; }
BOOL MRGAIUsingBackup(void) { return backupActive(); }
static NSString *activeKey(void) { return backupActive() ? MRGKeychainGet(kBackupKey) : MRGKeychainAPIKey(); }
void MRGAIForgetBackup(void) {
    MRGKeychainSet(kBackupKey, nil);
    [D() removeObjectForKey:@"mirage.dj.backupProvider"];
    [D() removeObjectForKey:@"mirage.dj.backupModel"];
    sg_backupUntil = 0;
}

MRGProvider MRGAIProvider(void) {
    if (backupActive()) return MRGAIBackupProvider();
    if (!MRGKeychainAPIKey()) return MRGProviderNone;
    NSInteger p = [D() integerForKey:kProviderKey];
    return [MRGAllProviders() containsObject:@(p)] ? p : MRGProviderNone;
}
NSString *MRGAIRecommendedModel(void) { return [D() stringForKey:kRecommendedKey]; }
NSArray<NSString *> *MRGAIModels(void) {
    NSMutableArray *a = [NSMutableArray array];
    for (id m in [D() arrayForKey:kModelsKey]) if ([m isKindOfClass:NSString.class]) [a addObject:m];
    return a;
}
NSString *MRGAIModel(void) { return backupActive() ? MRGAIBackupModel() : ([D() stringForKey:kOverrideKey] ?: MRGAIRecommendedModel()); }
BOOL MRGAIHasOverride(void) { return [D() stringForKey:kOverrideKey] != nil; }
void MRGAISetModelOverride(NSString *model) {
    if (model.length && ![model isEqualToString:MRGAIRecommendedModel()]) [D() setObject:model forKey:kOverrideKey];
    else [D() removeObjectForKey:kOverrideKey];
}

void MRGAIForgetKey(void) {
    MRGKeychainSetAPIKey(nil);
    for (NSString *k in @[kProviderKey, kModelsKey, kAllModelsKey, kRecommendedKey, kOverrideKey, kGeminiQueryKey]) [D() removeObjectForKey:k];
}

#pragma mark - HTTP

// Gemini takes its key in the x-goog-api-key header (both AIza… and AQ.… keys); a key the header way refuses is
// tried once as ?key=, and the way that worked is kept.
static NSMutableURLRequest *requestWith(MRGProvider p, NSString *key, NSString *path, NSDictionary *body, BOOL geminiQuery) {
    NSString *full = [baseURL(p) stringByAppendingString:path];
    if (p == MRGProviderGemini && geminiQuery) {
        NSString *escaped = [key stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
        full = [full stringByAppendingFormat:@"%@key=%@", [full containsString:@"?"] ? @"&" : @"?", escaped];
    }
    NSURL *url = [NSURL URLWithString:full];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:url];
    r.timeoutInterval = 45;
    [r setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    switch (p) {
        case MRGProviderGemini: if (!geminiQuery) [r setValue:key forHTTPHeaderField:@"x-goog-api-key"]; break;
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

static NSMutableURLRequest *request(MRGProvider p, NSString *key, NSString *path, NSDictionary *body) {
    return requestWith(p, key, path, body, p == MRGProviderGemini && [D() boolForKey:kGeminiQueryKey]);
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
    if (!detail.length && data.length && data.length < 400) detail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSString *base;
    if (status == 401 || status == 403) base = [NSString stringWithFormat:@"%@ refused this key (HTTP %ld).", name, (long)status];
    else if (status == 402) base = [NSString stringWithFormat:@"%@ says this key is out of credit (HTTP 402).", name];
    else if (status == 429) {
        BOOL tpm = [detail rangeOfString:@"tokens per minute" options:NSCaseInsensitiveSearch].location != NSNotFound || [detail rangeOfString:@"TPM"].location != NSNotFound;
        base = tpm ? [NSString stringWithFormat:@"%@'s free tier allows only so many words a minute and this chat went over it (HTTP 429). Mirage waited and tried again; give it a minute, or pick a model with higher limits in Settings → Mirage → AI DJ.", name]
                   : [NSString stringWithFormat:@"%@ is rate-limiting this key or it's out of quota (HTTP 429). Wait a minute and try again.", name];
    }
    else if (status >= 500) base = [NSString stringWithFormat:@"%@ is having trouble right now (HTTP %ld). Try again soon.", name, (long)status];
    else base = [NSString stringWithFormat:@"%@ answered HTTP %ld.", name, (long)status];
    return detail.length ? [NSString stringWithFormat:@"%@\n\n%@ said: %@", base, name, detail] : base;
}

// How long a 429 asks to wait: the Retry-After header, or the provider's own text ("Please try again in 7.52s",
// "in 1m3.2s", "in 450ms": Groq's tokens-per-minute limit, which is what the chat's red "…Requested … Please t…"
// bubble was). -1 when it doesn't say.
static double retryAfter(NSHTTPURLResponse *resp, NSData *data) {
    NSString *h = [resp isKindOfClass:NSHTTPURLResponse.class] ? resp.allHeaderFields[@"Retry-After"] ?: resp.allHeaderFields[@"retry-after"] : nil;
    if ([h isKindOfClass:NSString.class] && h.doubleValue > 0) return h.doubleValue;
    NSString *t = data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    if (!t.length) return -1;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"try again in\\s+(?:(\\d+)m)?\\s*(?:([\\d.]+)(ms|s))?" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
    if (!m) return -1;
    double secs = 0;
    if ([m rangeAtIndex:1].location != NSNotFound) secs += [[t substringWithRange:[m rangeAtIndex:1]] doubleValue] * 60;
    if ([m rangeAtIndex:2].location != NSNotFound) {
        double v = [[t substringWithRange:[m rangeAtIndex:2]] doubleValue];
        secs += [[t substringWithRange:[m rangeAtIndex:3]] isEqualToString:@"ms"] ? v / 1000.0 : v;
    }
    return secs > 0 ? secs : -1;
}

// One request; a 429 that asks for a short wait (up to 25 s) is sent again after it, twice at most, instead of failing.
static void sendTry(MRGProvider p, NSURLRequest *r, int attempt, void (^done)(id json, NSData *data, NSInteger status, NSString *error)) {
    [[NSURLSession.sharedSession dataTaskWithRequest:r completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        if (status == 429 && attempt < 2) {
            double wait = retryAfter((NSHTTPURLResponse *)resp, data);
            if (wait < 0 && attempt == 0) wait = 6;   // no hint: one try after a few seconds
            if (wait >= 0 && wait <= 25) {
                MRGDJLog(@"ai: %@ rate limit (429), trying again in %.1fs", MRGProviderName(p), wait + 0.5);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((wait + 0.5) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ sendTry(p, r, attempt + 1, done); });
                return;
            }
        }
        id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSString *message = (error || status < 200 || status >= 300) ? errorMessage(p, status, data, error) : nil;
        if (status == 429) MRGDJLog(@"ai: %@ rate limit (429) after %d tries: %@", MRGProviderName(p), attempt + 1, message);
        dispatch_async(dispatch_get_main_queue(), ^{ done(json, data, status, message); });
    }] resume];
}

static void send(MRGProvider p, NSURLRequest *r, void (^done)(id json, NSData *data, NSInteger status, NSString *error)) { sendTry(p, r, 0, done); }

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

void MRGAISetupKey(NSString *raw, void (^done)(BOOL, NSString *)) { MRGAISetupKeyAs(raw, MRGProviderNone, done); }

void MRGAISetupKeyAs(NSString *raw, MRGProvider chosen, void (^done)(BOOL, NSString *)) {
    // Pasted keys can carry spaces, line breaks or invisible characters from the page they were copied from.
    NSMutableString *key = [NSMutableString string];
    NSCharacterSet *junk = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSUInteger i = 0; i < raw.length; i++) {
        unichar c = [raw characterAtIndex:i];
        if ([junk characterIsMember:c] || c == 0x200B || c == 0x200C || c == 0x200D || c == 0xFEFF || c == 0x2060 || c < 0x20) continue;
        [key appendFormat:@"%C", c];
    }
    MRGProvider p = chosen != MRGProviderNone ? chosen : MRGDetectProvider(key);
    if (p == MRGProviderNone) {
        done(NO, @"Mirage can't tell the provider from this key's format (Mistral keys, for one, have no prefix). Choose the provider by hand and save again.");
        return;
    }
    void (^validate)(BOOL) = ^(BOOL geminiQuery) {
        send(p, requestWith(p, key, modelsPath(p), nil, geminiQuery), ^(id json, NSData *data, NSInteger status, NSString *error) {
            if (error && p == MRGProviderGemini && !geminiQuery && (status == 400 || status == 401 || status == 403)) {
                // Some Gemini keys are only taken as ?key=: one more try that way before giving up.
                send(p, requestWith(p, key, modelsPath(p), nil, YES), ^(id j2, NSData *d2, NSInteger s2, NSString *e2) {
                    if (e2) { done(NO, error); return; }
                    [D() setBool:YES forKey:kGeminiQueryKey];
                    finishSetup(p, key, modelIDs(p, j2), done);
                });
                return;
            }
            if (error) { done(NO, error); return; }
            if (p == MRGProviderGemini) [D() setBool:geminiQuery forKey:kGeminiQueryKey];
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
    };
    validate(NO);
}

void MRGAISetupBackupKey(NSString *raw, void (^done)(BOOL, NSString *)) {
    NSString *key = [[raw ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] componentsJoinedByString:@""];
    if (!key.length) { MRGAIForgetBackup(); done(YES, @"Backup key removed."); return; }
    MRGProvider p = MRGDetectProvider(key);
    if (p == MRGProviderNone) { done(NO, @"Mirage can't tell the provider from this key's format. Use a key with a prefix (gsk_, AIza…, sk-or-, csk-…)."); return; }
    send(p, requestWith(p, key, modelsPath(p), nil, NO), ^(id json, NSData *data, NSInteger status, NSString *error) {
        if (error) { done(NO, error); return; }
        NSString *pick = MRGAIPickModel(p, modelIDs(p, json));
        if (!pick) { done(NO, [NSString stringWithFormat:@"%@ accepted the key but listed no chat model Mirage can use.", MRGProviderName(p)]); return; }
        if (!MRGKeychainSet(kBackupKey, key)) { done(NO, @"Couldn't save the key on this phone."); return; }
        [D() setInteger:p forKey:@"mirage.dj.backupProvider"];
        [D() setObject:pick forKey:@"mirage.dj.backupModel"];
        done(YES, [NSString stringWithFormat:@"Backup saved: %@ (%@). When the main key runs out (HTTP 429), Mirage uses this one for 30 minutes.", MRGProviderName(p), pick]);
    });
}

#pragma mark - chat

static BOOL isReasoningOpenAI(NSString *m) {
    return [m hasPrefix:@"gpt-5"] || [m hasPrefix:@"gpt-6"] || [m hasPrefix:@"o1"] || [m hasPrefix:@"o3"] || [m hasPrefix:@"o4"];
}

static NSString *textFromOpenAI(id json) {
    id choices = [json isKindOfClass:NSDictionary.class] ? json[@"choices"] : nil;
    id msg = dictGet(firstOf(choices), @"message");
    id content = [msg isKindOfClass:NSDictionary.class] ? msg[@"content"] : nil;
    return [content isKindOfClass:NSString.class] ? content : nil;
}

static NSString *textFromGemini(id json) {
    NSMutableString *out = [NSMutableString string];
    id cands = [json isKindOfClass:NSDictionary.class] ? json[@"candidates"] : nil;
    id parts = dictGet(dictGet(firstOf(cands), @"content"), @"parts");
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
    if (!reasoning) b[@"temperature"] = @0.6;   // 0.5.2: was 0.9; lower = fewer made-up details in the lines
    if (reasoning) b[@"reasoning_effort"] = @"low";
    if (p == MRGProviderXAI && [model hasPrefix:@"grok-4.3"]) b[@"reasoning_effort"] = @"none";
    if (json) b[@"response_format"] = @{@"type": @"json_object"};
    return b;
}

// A web-grounded answer where the provider has search built in: Gemini's google_search tool (sources from
// groundingMetadata.groundingChunks[].web). Other providers answer done(nil, nil, nil) right away (nothing grounded).
void MRGAIGrounded(NSString *question, void (^done)(NSString *text, NSArray<NSDictionary *> *sources, NSString *error)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = activeKey(), *model = MRGAIModel();
    if (p != MRGProviderGemini || !key || !model) { done(nil, nil, nil); return; }
    NSDictionary *body = @{@"contents": @[@{@"role": @"user", @"parts": @[@{@"text": question}]}],
                           @"tools": @[@{@"google_search": @{}}],
                           @"generationConfig": @{@"temperature": @0.2}};
    NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", model];
    send(p, request(p, key, path, body), ^(id j, NSData *d, NSInteger s, NSString *e) {
        NSString *text = e ? nil : textFromGemini(j);
        NSMutableArray *sources = [NSMutableArray array];
        @try {
            id cand = [dictGet(j, @"candidates") isKindOfClass:NSArray.class] ? [dictGet(j, @"candidates") firstObject] : nil;
            id chunks = dictGet(dictGet(cand, @"groundingMetadata"), @"groundingChunks");
            for (id c in [chunks isKindOfClass:NSArray.class] ? chunks : @[]) {
                id web = dictGet(c, @"web");
                NSString *uri = dictGet(web, @"uri"), *title = dictGet(web, @"title");
                if ([uri isKindOfClass:NSString.class] && sources.count < 4)
                    [sources addObject:@{@"url": uri, @"title": [title isKindOfClass:NSString.class] ? title : @"web"}];
            }
        } @catch (__unused NSException *x) {}
        dispatch_async(dispatch_get_main_queue(), ^{ done(text, sources, e); });
    });
}

static void chatOnce(NSString *system, NSString *user, BOOL json, void (^done)(NSString *, NSString *));
// A 429 from the main key with a backup saved: the backup takes over for 30 minutes and the call is sent again.
static BOOL switchToBackup(NSString *error) {
    if (![error containsString:@"HTTP 429"] || backupActive() || MRGAIBackupProvider() == MRGProviderNone || !MRGAIBackupModel().length) return NO;
    MRGProvider main = MRGAIProvider();
    sg_backupUntil = CACurrentMediaTime() + 30 * 60;
    MRGDJLog(@"ai: %@ is out of quota or rate-limited (429); using the backup key (%@, %@) for 30 minutes", MRGProviderName(main), MRGProviderName(MRGAIBackupProvider()), MRGAIBackupModel());
    return YES;
}
void MRGAIChat(NSString *system, NSString *user, BOOL json, void (^done)(NSString *, NSString *)) {
    chatOnce(system, user, json, ^(NSString *text, NSString *error) {
        if (error && switchToBackup(error)) { chatOnce(system, user, json, done); return; }
        done(text, error);
    });
}
static void chatOnce(NSString *system, NSString *user, BOOL json, void (^done)(NSString *, NSString *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = activeKey(), *model = MRGAIModel();
    if (p == MRGProviderNone || !key || !model) { done(nil, @"Add an API key in Mirage settings first."); return; }
    void (^finish)(NSString *, NSString *) = ^(NSString *text, NSString *error) {
        if (!error && !text.length) error = [NSString stringWithFormat:@"%@ sent an empty answer. Try again.", MRGProviderName(p)];
        done(error ? nil : text, error);
    };
    switch (p) {
        case MRGProviderGemini: {
            NSMutableDictionary *config = [@{@"temperature": @0.6} mutableCopy];
            if (json) config[@"responseMimeType"] = @"application/json";
            NSDictionary *body = @{@"systemInstruction": @{@"parts": @[@{@"text": system}]},
                                   @"contents": @[@{@"role": @"user", @"parts": @[@{@"text": user}]}],
                                   @"generationConfig": config};
            NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", model];
            send(p, request(p, key, path, body), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(textFromGemini(j), e); });
            return;
        }
        case MRGProviderAnthropic: {
            NSDictionary *body = @{@"model": model, @"max_tokens": @1500, @"system": system, @"temperature": @0.6,
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
        for (NSString *want in @[@"gpt-4o-mini-tts", @"tts-1-hd", @"tts-1"]) if ([tts containsObject:want]) return want;
        return ranked(tts).firstObject ?: @"gpt-4o-mini-tts";
    }
    if (p == MRGProviderGroq) {
        for (NSString *m in all) if ([m isKindOfClass:NSString.class] && [m containsString:@"orpheus-v1-english"]) return m;
        return @"canopylabs/orpheus-v1-english";
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

// Voices from each provider's docs (November 2026): OpenAI's speech voices for gpt-4o-mini-tts, Gemini's prebuilt
// TTS voices, Groq's Orpheus English voices. xAI's come from its own list (GET /v1/tts/voices).
static NSArray<NSString *> *docVoices(MRGProvider p) {
    switch (p) {
        case MRGProviderOpenAI: return @[@"alloy", @"ash", @"ballad", @"coral", @"echo", @"fable", @"nova", @"onyx", @"sage", @"shimmer", @"verse", @"marin", @"cedar"];
        case MRGProviderGemini: return @[@"Puck", @"Zephyr", @"Charon", @"Kore", @"Fenrir", @"Leda", @"Orus", @"Aoede", @"Callirrhoe", @"Autonoe",
                                         @"Enceladus", @"Iapetus", @"Umbriel", @"Algieba", @"Despina", @"Erinome", @"Algenib", @"Rasalgethi",
                                         @"Laomedeia", @"Achernar", @"Alnilam", @"Schedar", @"Gacrux", @"Pulcherrima", @"Achird",
                                         @"Zubenelgenubi", @"Vindemiatrix", @"Sadachbia", @"Sadaltager", @"Sulafat"];
        case MRGProviderGroq: return @[@"troy", @"austin", @"daniel", @"autumn", @"diana", @"hannah"];
        case MRGProviderXAI: return @[@"eve"];
        default: return @[];
    }
}

static NSString *defaultVoice(MRGProvider p) {
    switch (p) {
        case MRGProviderOpenAI: return @"ash";
        case MRGProviderGemini: return @"Puck";
        case MRGProviderGroq: return @"troy";
        case MRGProviderXAI: return @"eve";
        default: return nil;
    }
}

void MRGAIProviderVoices(void (^done)(NSArray<NSDictionary *> *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = activeKey();
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *v in docVoices(p)) [out addObject:@{@"id": v, @"name": v.capitalizedString}];
    if (p != MRGProviderXAI || !key) { done(out); return; }
    send(p, request(p, key, @"/tts/voices", nil), ^(id j, NSData *d, NSInteger s, NSString *e) {
        NSArray *list = [j isKindOfClass:NSDictionary.class] ? j[@"voices"] : nil;
        if (![list isKindOfClass:NSArray.class] || !list.count) { done(out); return; }
        NSMutableArray *voices = [NSMutableArray array];
        for (NSDictionary *v in list) {
            if (![v isKindOfClass:NSDictionary.class] || ![v[@"voice_id"] isKindOfClass:NSString.class]) continue;
            NSString *name = [v[@"name"] isKindOfClass:NSString.class] ? v[@"name"] : [v[@"voice_id"] capitalizedString];
            [voices addObject:@{@"id": v[@"voice_id"], @"name": name}];
        }
        done(voices.count ? voices : out);
    });
}

void MRGAISpeech(NSString *text, NSString *voice, double speed, NSString *instructions, void (^done)(NSData *, NSString *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = activeKey();
    if (!key || !MRGProviderHasTTS(p)) { done(nil, @"This provider has no voice; using the phone's."); return; }
    NSString *v = voice.length ? voice : defaultVoice(p);
    if (speed <= 0) speed = 1;
    if (p == MRGProviderOpenAI) {
        NSMutableDictionary *body = [@{@"model": ttsModel(p), @"voice": v, @"input": text, @"response_format": @"mp3",
                                       @"speed": @(MIN(4.0, MAX(0.25, speed)))} mutableCopy];
        if ([body[@"model"] containsString:@"gpt-4o"]) body[@"instructions"] = instructions.length ? instructions : @"A relaxed, upbeat radio DJ. Casual, warm, natural.";
        NSMutableURLRequest *r = request(p, key, @"/audio/speech", body);
        [r setValue:@"audio/mpeg" forHTTPHeaderField:@"Accept"];
        send(p, r, ^(id j, NSData *d, NSInteger s, NSString *e) { done(e ? nil : d, e); });
        return;
    }
    if (p == MRGProviderGroq) {
        // Orpheus takes at most 200 characters a request.
        NSString *input = text.length > 200 ? [text substringToIndex:200] : text;
        NSDictionary *body = @{@"model": ttsModel(p), @"voice": v, @"input": input, @"response_format": @"wav"};
        NSMutableURLRequest *r = request(p, key, @"/audio/speech", body);
        [r setValue:@"audio/wav" forHTTPHeaderField:@"Accept"];
        send(p, r, ^(id j, NSData *d, NSInteger s, NSString *e) { done(e ? nil : d, e); });
        return;
    }
    if (p == MRGProviderXAI) {
        NSDictionary *body = @{@"text": text, @"voice_id": v, @"language": @"auto", @"speed": @(MIN(1.5, MAX(0.7, speed)))};
        NSMutableURLRequest *r = request(p, key, @"/tts", body);
        [r setValue:@"*/*" forHTTPHeaderField:@"Accept"];
        send(p, r, ^(id j, NSData *d, NSInteger s, NSString *e) {
            if (e) { done(nil, e); return; }
            // The audio itself, or a JSON envelope with it in base64.
            if ([j isKindOfClass:NSDictionary.class] && [j[@"audio"] isKindOfClass:NSString.class]) {
                NSData *audio = [[NSData alloc] initWithBase64EncodedString:j[@"audio"] options:0];
                done(audio, audio ? nil : @"xAI sent no audio.");
                return;
            }
            done(d.length ? d : nil, d.length ? nil : @"xAI sent no audio.");
        });
        return;
    }
    NSString *how = instructions.length ? [NSString stringWithFormat:@"Read the line after the colon aloud. %@\nLine: ", instructions] : @"Say casually, like a laid-back radio DJ: ";
    NSDictionary *body = @{@"contents": @[@{@"parts": @[@{@"text": [how stringByAppendingString:text]}]}],
                           @"generationConfig": @{@"responseModalities": @[@"AUDIO"],
                                                  @"speechConfig": @{@"voiceConfig": @{@"prebuiltVoiceConfig": @{@"voiceName": v}}}}};
    NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", ttsModel(p)];
    send(p, request(p, key, path, body), ^(id j, NSData *d, NSInteger s, NSString *e) {
        if (e) { done(nil, e); return; }
        id cands = [j isKindOfClass:NSDictionary.class] ? j[@"candidates"] : nil;
        id parts = dictGet(dictGet(firstOf(cands), @"content"), @"parts");
        NSString *b64 = nil;
        for (id part in [parts isKindOfClass:NSArray.class] ? parts : nil) {
            id inline_ = [part isKindOfClass:NSDictionary.class] ? part[@"inlineData"] : nil;
            if ([inline_ isKindOfClass:NSDictionary.class] && [inline_[@"data"] isKindOfClass:NSString.class]) { b64 = inline_[@"data"]; break; }
        }
        NSData *pcm = b64 ? [[NSData alloc] initWithBase64EncodedString:b64 options:0] : nil;
        done(pcm.length ? wavFromPCM(pcm) : nil, pcm.length ? nil : @"Gemini sent no audio.");
    });
}

#pragma mark - tools (function calling)

static NSString *jsonString(id obj) {
    if (!obj) return @"{}";
    if ([obj isKindOfClass:NSString.class]) return obj;
    NSData *d = [NSJSONSerialization isValidJSONObject:obj] ? [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil] : nil;
    return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"{}";
}

static id parseLenient(NSString *s) {
    if (![s isKindOfClass:NSString.class] || !s.length) return nil;
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil] : nil;
    if (j) return j;
    // Common slips: trailing commas, single quotes, Python literals.
    NSMutableString *t = [s mutableCopy];
    [[NSRegularExpression regularExpressionWithPattern:@",\\s*([}\\]])" options:0 error:nil] replaceMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@"$1"];
    if ([t rangeOfString:@"\""].location == NSNotFound) [t replaceOccurrencesOfString:@"'" withString:@"\"" options:0 range:NSMakeRange(0, t.length)];
    for (NSArray *pair in @[@[@": None", @": null"], @[@": True", @": true"], @[@": False", @": false"]]) [t replaceOccurrencesOfString:pair[0] withString:pair[1] options:0 range:NSMakeRange(0, t.length)];
    d = [t dataUsingEncoding:NSUTF8StringEncoding];
    return d ? [NSJSONSerialization JSONObjectWithData:d options:NSJSONReadingFragmentsAllowed error:nil] : nil;
}

static NSDictionary *jsonDict(id s) {
    if ([s isKindOfClass:NSDictionary.class]) return s;
    id j = parseLenient(s);
    return [j isKindOfClass:NSDictionary.class] ? j : @{};
}

#pragma mark - tool calls written as text

// From `open` (a '{' or '['), the end of its balanced JSON value (strings respected), or NSNotFound.
static NSUInteger jsonEnd(NSString *t, NSUInteger open) {
    unichar o = [t characterAtIndex:open], c = o == '{' ? '}' : ']';
    NSInteger depth = 0;
    BOOL inString = NO, escaped = NO;
    for (NSUInteger i = open; i < t.length; i++) {
        unichar ch = [t characterAtIndex:i];
        if (inString) { if (escaped) escaped = NO; else if (ch == '\\') escaped = YES; else if (ch == '"') inString = NO; continue; }
        if (ch == '"') inString = YES;
        else if (ch == o || ch == (o == '{' ? '[' : '{')) depth++;
        else if (ch == c || ch == (c == '}' ? ']' : '}')) { depth--; if (depth == 0) return i; }
    }
    return NSNotFound;
}

static NSDictionary *callFrom(NSString *name, id args, NSSet *names) {
    if (![name isKindOfClass:NSString.class]) return nil;
    NSString *n = [name hasPrefix:@"functions."] ? [name substringFromIndex:10] : name;
    if (![names containsObject:n]) return nil;
    if ([args isKindOfClass:NSString.class]) args = jsonDict(args);
    return @{@"id": [@"text_" stringByAppendingString:NSUUID.UUID.UUIDString], @"name": n, @"arguments": [args isKindOfClass:NSDictionary.class] ? args : @{}, @"from_text": @YES};
}

// Values of `key: value, key2: [..]` written loosely after a tool name, as JSON when they parse.
static NSDictionary *looseArgs(NSString *t) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"([A-Za-z_]+)\\s*[:=]\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|\\[[^\\]]*\\]|[^,\\n}]+)" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *k = [t substringWithRange:[m rangeAtIndex:1]];
        NSString *v = [[t substringWithRange:[m rangeAtIndex:2]] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        id parsed = parseLenient(v);
        out[k] = parsed ?: v;
    }
    return out;
}

// Tool calls a model wrote into its text instead of the API's tool_calls (0.3.1 with Groq gpt-oss-120b showed
// 'play_tracks: intro: "", uris: [...]' in the chat): Harmony (to=functions.x … <|message|>{…}), <tool_call>{…}</tool_call>,
// <function=x>{…}</function>, JSON objects {"name"/"tool"/"function": x, "arguments"/"parameters"/"args": {…}} (bare,
// in a list or a ```json fence), x({…}), and `x: key: value, …` at the start of a line. Returns the calls (only names in
// `names`), and in *cleaned the text without them and without stray <|…|> tokens.
NSArray<NSDictionary *> *MRGParseTextToolCalls(NSString *text, NSSet<NSString *> *names, NSString **cleaned) {
    NSMutableArray *calls = [NSMutableArray array];
    if (![text isKindOfClass:NSString.class] || !text.length || !names.count) { if (cleaned) *cleaned = text; return calls; }
    NSMutableString *t = [text mutableCopy];
    NSMutableArray<NSValue *> *cut = [NSMutableArray array];
    // Harmony / <function=…> / to=functions.x: a name, then the next JSON object.
    NSRegularExpression *named = [NSRegularExpression regularExpressionWithPattern:@"(?:to=functions\\.|<function=|\"?recipient\"?\\s*:\\s*\"functions\\.)([A-Za-z_]+)" options:0 error:nil];
    for (NSTextCheckingResult *m in [named matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *n = [t substringWithRange:[m rangeAtIndex:1]];
        NSUInteger from = NSMaxRange(m.range);
        NSRange brace = [t rangeOfString:@"{" options:0 range:NSMakeRange(from, t.length - from)];
        NSUInteger end = brace.location != NSNotFound && brace.location - from < 120 ? jsonEnd(t, brace.location) : NSNotFound;
        NSDictionary *c = callFrom(n, end != NSNotFound ? [t substringWithRange:NSMakeRange(brace.location, end - brace.location + 1)] : @{}, names);
        if (!c) continue;
        [calls addObject:c];
        [cut addObject:[NSValue valueWithRange:NSMakeRange(m.range.location, (end != NSNotFound ? end + 1 : from) - m.range.location)]];
    }
    // JSON objects naming a tool.
    if (!calls.count) {
        for (NSUInteger i = 0; i < t.length; i++) {
            unichar ch = [t characterAtIndex:i];
            if (ch != '{' && ch != '[') continue;
            NSUInteger end = jsonEnd(t, i);
            if (end == NSNotFound) continue;
            id j = parseLenient([t substringWithRange:NSMakeRange(i, end - i + 1)]);
            NSArray *list = [j isKindOfClass:NSArray.class] ? j : (j ? @[j] : @[]);
            NSUInteger before = calls.count;
            for (NSDictionary *o in list) {
                if (![o isKindOfClass:NSDictionary.class]) continue;
                id fn = o[@"function"];
                NSString *n = [o[@"name"] isKindOfClass:NSString.class] ? o[@"name"] : [o[@"tool"] isKindOfClass:NSString.class] ? o[@"tool"]
                            : [o[@"tool_name"] isKindOfClass:NSString.class] ? o[@"tool_name"] : [fn isKindOfClass:NSString.class] ? fn
                            : [fn isKindOfClass:NSDictionary.class] ? fn[@"name"] : nil;
                id args = o[@"arguments"] ?: o[@"parameters"] ?: o[@"args"] ?: o[@"input"] ?: ([fn isKindOfClass:NSDictionary.class] ? fn[@"arguments"] : nil);
                NSDictionary *c = callFrom(n, args, names);
                if (c) [calls addObject:c];
            }
            if (calls.count > before) { [cut addObject:[NSValue valueWithRange:NSMakeRange(i, end - i + 1)]]; i = end; }
        }
    }
    // name({…}) or name: key: value … at a line start.
    if (!calls.count) {
        NSString *alt = [names.allObjects componentsJoinedByString:@"|"];
        NSRegularExpression *line = [NSRegularExpression regularExpressionWithPattern:[NSString stringWithFormat:@"(?m)^[\\s`*>-]*(%@)\\s*(\\(|:)\\s*(.*)$", alt] options:0 error:nil];
        for (NSTextCheckingResult *m in [line matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
            NSString *n = [t substringWithRange:[m rangeAtIndex:1]];
            NSString *rest = [t substringWithRange:[m rangeAtIndex:3]];
            NSRange brace = [rest rangeOfString:@"{"];
            id args = nil;
            if (brace.location != NSNotFound && brace.location < 4) {
                NSUInteger e = jsonEnd(rest, brace.location);
                if (e != NSNotFound) args = jsonDict([rest substringWithRange:NSMakeRange(brace.location, e - brace.location + 1)]);
            }
            if (![args count]) args = looseArgs(rest);
            NSDictionary *c = callFrom(n, args, names);
            if (c) { [calls addObject:c]; [cut addObject:[NSValue valueWithRange:m.range]]; }
        }
    }
    [cut sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) { return a.rangeValue.location > b.rangeValue.location ? NSOrderedAscending : NSOrderedDescending; }];
    NSUInteger floor = NSNotFound;
    for (NSValue *v in cut) {
        NSRange r = v.rangeValue;
        if (floor != NSNotFound && NSMaxRange(r) > floor) continue;   // overlapping
        if (NSMaxRange(r) <= t.length) { [t deleteCharactersInRange:r]; floor = r.location; }
    }
    if (cleaned) {
        NSMutableString *c = [t mutableCopy];
        [[NSRegularExpression regularExpressionWithPattern:@"<\\|[^|]*\\|>|</?tool_call>|</?function[^>]*>|```(?:json)?" options:0 error:nil] replaceMatchesInString:c options:0 range:NSMakeRange(0, c.length) withTemplate:@""];
        [[NSRegularExpression regularExpressionWithPattern:@"(?m)^\\s*(?:commentary|analysis|final|assistant)\\s*$" options:0 error:nil] replaceMatchesInString:c options:0 range:NSMakeRange(0, c.length) withTemplate:@""];
        *cleaned = [c stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    }
    return calls;
}

static NSString *str(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }

// OpenAI-compatible chat/completions (OpenAI, OpenRouter, Groq, xAI, Cerebras, Fireworks, Together, DeepSeek, Mistral).
static NSDictionary *openAIToolBody(MRGProvider p, NSString *model, NSString *system, NSArray *messages, NSArray *tools, BOOL extras) {
    NSMutableArray *msgs = [NSMutableArray arrayWithObject:@{@"role": @"system", @"content": system}];
    for (NSDictionary *m in messages) {
        NSString *role = m[@"role"];
        if ([role isEqualToString:@"tool"]) {
            [msgs addObject:@{@"role": @"tool", @"tool_call_id": m[@"tool_call_id"] ?: @"", @"content": m[@"content"] ?: @"{}"}];
        } else if ([role isEqualToString:@"assistant"]) {
            NSMutableDictionary *a = [@{@"role": @"assistant", @"content": str(m[@"content"]) ?: @""} mutableCopy];
            NSMutableArray *calls = [NSMutableArray array];
            for (NSDictionary *c in m[@"tool_calls"]) {
                [calls addObject:@{@"id": c[@"id"] ?: @"", @"type": @"function",
                                   @"function": @{@"name": c[@"name"] ?: @"", @"arguments": jsonString(c[@"arguments"])}}];
            }
            if (calls.count) a[@"tool_calls"] = calls;
            [msgs addObject:a];
        } else {
            [msgs addObject:@{@"role": @"user", @"content": m[@"content"] ?: @""}];
        }
    }
    NSMutableArray *fns = [NSMutableArray array];
    for (NSDictionary *t in tools) [fns addObject:@{@"type": @"function", @"function": @{@"name": t[@"name"], @"description": t[@"description"], @"parameters": t[@"parameters"]}}];
    NSMutableDictionary *b = [@{@"model": model, @"messages": msgs} mutableCopy];
    if (fns.count) b[@"tools"] = fns;
    if (extras) {
        BOOL reasoning = (p == MRGProviderOpenAI && isReasoningOpenAI(model)) || [model containsString:@"gpt-oss"];
        if (reasoning) b[@"reasoning_effort"] = @"low"; else b[@"temperature"] = @0.4;
        if (p == MRGProviderXAI && [model hasPrefix:@"grok-4.3"]) b[@"reasoning_effort"] = @"none";
    }
    return b;
}

static NSDictionary *openAIToolAnswer(id json) {
    id choices = [json isKindOfClass:NSDictionary.class] ? json[@"choices"] : nil;
    NSDictionary *msg = dictGet(firstOf(choices), @"message");
    if (![msg isKindOfClass:NSDictionary.class]) return nil;
    NSMutableArray *calls = [NSMutableArray array];
    for (NSDictionary *c in [msg[@"tool_calls"] isKindOfClass:NSArray.class] ? msg[@"tool_calls"] : @[]) {
        if (![c isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *f = c[@"function"];
        if (![f isKindOfClass:NSDictionary.class] || !str(f[@"name"])) continue;
        id raw = f[@"arguments"];
        NSDictionary *args = jsonDict(raw);
        NSMutableDictionary *call = [@{@"id": str(c[@"id"]) ?: NSUUID.UUID.UUIDString, @"name": f[@"name"], @"arguments": args} mutableCopy];
        if (!args.count && [raw isKindOfClass:NSString.class] && [[raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] length] > 2) call[@"bad_arguments"] = raw;
        [calls addObject:call];
    }
    return @{@"role": @"assistant", @"content": str(msg[@"content"]) ?: @"", @"tool_calls": calls};
}

static NSDictionary *anthropicToolBody(NSString *model, NSString *system, NSArray *messages, NSArray *tools) {
    NSMutableArray *msgs = [NSMutableArray array];
    for (NSDictionary *m in messages) {
        NSString *role = m[@"role"];
        if ([role isEqualToString:@"tool"]) {
            NSDictionary *block = @{@"type": @"tool_result", @"tool_use_id": m[@"tool_call_id"] ?: @"", @"content": m[@"content"] ?: @"{}"};
            NSMutableDictionary *last = [msgs.lastObject mutableCopy];
            if ([last[@"role"] isEqualToString:@"user"] && [last[@"content"] isKindOfClass:NSArray.class] &&
                [[last[@"content"] firstObject][@"type"] isEqualToString:@"tool_result"]) {
                last[@"content"] = [last[@"content"] arrayByAddingObject:block];
                msgs[msgs.count - 1] = last;
            } else {
                [msgs addObject:@{@"role": @"user", @"content": @[block]}];
            }
        } else if ([role isEqualToString:@"assistant"]) {
            NSMutableArray *blocks = [NSMutableArray array];
            if ([str(m[@"content"]) length]) [blocks addObject:@{@"type": @"text", @"text": m[@"content"]}];
            for (NSDictionary *c in m[@"tool_calls"]) [blocks addObject:@{@"type": @"tool_use", @"id": c[@"id"] ?: @"", @"name": c[@"name"] ?: @"", @"input": c[@"arguments"] ?: @{}}];
            if (!blocks.count) [blocks addObject:@{@"type": @"text", @"text": @"…"}];
            [msgs addObject:@{@"role": @"assistant", @"content": blocks}];
        } else {
            [msgs addObject:@{@"role": @"user", @"content": m[@"content"] ?: @""}];
        }
    }
    NSMutableArray *fns = [NSMutableArray array];
    for (NSDictionary *t in tools) [fns addObject:@{@"name": t[@"name"], @"description": t[@"description"], @"input_schema": t[@"parameters"]}];
    NSMutableDictionary *b = [@{@"model": model, @"max_tokens": @1500, @"system": system, @"messages": msgs} mutableCopy];
    if (fns.count) b[@"tools"] = fns;
    return b;
}

static NSDictionary *anthropicToolAnswer(id json) {
    NSArray *content = [json isKindOfClass:NSDictionary.class] ? json[@"content"] : nil;
    if (![content isKindOfClass:NSArray.class]) return nil;
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *calls = [NSMutableArray array];
    for (NSDictionary *b in content) {
        if (![b isKindOfClass:NSDictionary.class]) continue;
        if ([b[@"type"] isEqual:@"text"] && str(b[@"text"])) [text appendString:b[@"text"]];
        if ([b[@"type"] isEqual:@"tool_use"] && str(b[@"name"]))
            [calls addObject:@{@"id": str(b[@"id"]) ?: NSUUID.UUID.UUIDString, @"name": b[@"name"], @"arguments": [b[@"input"] isKindOfClass:NSDictionary.class] ? b[@"input"] : @{}}];
    }
    return @{@"role": @"assistant", @"content": text, @"tool_calls": calls};
}

// Gemini: the model's own parts are sent back as they came (Gemini 3 needs each functionCall's thoughtSignature).
static NSDictionary *geminiToolBody(NSString *system, NSArray *messages, NSArray *tools) {
    NSMutableArray *contents = [NSMutableArray array];
    for (NSDictionary *m in messages) {
        NSString *role = m[@"role"];
        if ([role isEqualToString:@"tool"]) {
            NSDictionary *part = @{@"functionResponse": @{@"name": m[@"name"] ?: @"tool", @"response": @{@"result": jsonDict(m[@"content"])}}};
            NSMutableDictionary *last = [contents.lastObject mutableCopy];
            if ([last[@"role"] isEqualToString:@"user"] && dictGet(firstOf(last[@"parts"]), @"functionResponse")) {
                last[@"parts"] = [last[@"parts"] arrayByAddingObject:part];
                contents[contents.count - 1] = last;
            } else {
                [contents addObject:@{@"role": @"user", @"parts": @[part]}];
            }
        } else if ([role isEqualToString:@"assistant"]) {
            NSArray *raw = [m[@"raw"] isKindOfClass:NSArray.class] ? m[@"raw"] : nil;
            if (!raw.count) {
                NSMutableArray *parts = [NSMutableArray array];
                if ([str(m[@"content"]) length]) [parts addObject:@{@"text": m[@"content"]}];
                for (NSDictionary *c in m[@"tool_calls"]) [parts addObject:@{@"functionCall": @{@"name": c[@"name"] ?: @"", @"args": c[@"arguments"] ?: @{}}}];
                raw = parts.count ? parts : @[@{@"text": @"…"}];
            }
            [contents addObject:@{@"role": @"model", @"parts": raw}];
        } else {
            [contents addObject:@{@"role": @"user", @"parts": @[@{@"text": m[@"content"] ?: @""}]}];
        }
    }
    NSMutableArray *decls = [NSMutableArray array];
    for (NSDictionary *t in tools) [decls addObject:@{@"name": t[@"name"], @"description": t[@"description"], @"parameters": t[@"parameters"]}];
    NSMutableDictionary *b = [@{@"systemInstruction": @{@"parts": @[@{@"text": system}]}, @"contents": contents,
                                @"generationConfig": @{@"temperature": @0.4}} mutableCopy];
    if (decls.count) b[@"tools"] = @[@{@"functionDeclarations": decls}];
    return b;
}

static NSDictionary *geminiToolAnswer(id json) {
    id cands = [json isKindOfClass:NSDictionary.class] ? json[@"candidates"] : nil;
    NSArray *parts = dictGet(dictGet(firstOf(cands), @"content"), @"parts");
    if (![parts isKindOfClass:NSArray.class]) return nil;
    NSMutableString *text = [NSMutableString string];
    NSMutableArray *calls = [NSMutableArray array];
    NSUInteger n = 0;
    for (NSDictionary *part in parts) {
        if (![part isKindOfClass:NSDictionary.class]) continue;
        if (str(part[@"text"]) && ![part[@"thought"] boolValue]) [text appendString:part[@"text"]];
        NSDictionary *fc = part[@"functionCall"];
        if ([fc isKindOfClass:NSDictionary.class] && str(fc[@"name"]))
            [calls addObject:@{@"id": str(fc[@"id"]) ?: [NSString stringWithFormat:@"call_%lu", (unsigned long)n++], @"name": fc[@"name"],
                               @"arguments": [fc[@"args"] isKindOfClass:NSDictionary.class] ? fc[@"args"] : @{}}];
    }
    return @{@"role": @"assistant", @"content": text, @"tool_calls": calls, @"raw": parts};
}

static void chatToolsOnce(NSString *system, NSArray<NSDictionary *> *messages, NSArray<NSDictionary *> *tools, void (^done)(NSDictionary *, NSString *));
void MRGAIChatTools(NSString *system, NSArray<NSDictionary *> *messages, NSArray<NSDictionary *> *tools,
                    void (^done)(NSDictionary *, NSString *)) {
    chatToolsOnce(system, messages, tools, ^(NSDictionary *a, NSString *error) {
        if (error && switchToBackup(error)) { chatToolsOnce(system, messages, tools, done); return; }
        done(a, error);
    });
}
static void chatToolsOnce(NSString *system, NSArray<NSDictionary *> *messages, NSArray<NSDictionary *> *tools,
                    void (^done)(NSDictionary *, NSString *)) {
    MRGProvider p = MRGAIProvider();
    NSString *key = activeKey(), *model = MRGAIModel();
    if (p == MRGProviderNone || !key || !model) { done(nil, @"Add an API key in Mirage settings first."); return; }
    NSMutableSet *names = [NSMutableSet set];
    for (NSDictionary *t in tools) if ([t[@"name"] isKindOfClass:NSString.class]) [names addObject:t[@"name"]];
    void (^finish)(NSDictionary *, NSString *) = ^(NSDictionary *a, NSString *e) {
        if (!e && !a) e = [NSString stringWithFormat:@"%@ sent an answer Mirage couldn't read. Try again.", MRGProviderName(p)];
        if (a && names.count) {
            // Calls written as text become real calls; the text never shows them.
            NSString *cleaned = nil;
            NSArray *textCalls = MRGParseTextToolCalls(str(a[@"content"]) ?: @"", names, &cleaned);
            NSArray *apiCalls = [a[@"tool_calls"] isKindOfClass:NSArray.class] ? a[@"tool_calls"] : @[];
            if (textCalls.count || ![cleaned isEqualToString:str(a[@"content"]) ?: @""]) {
                NSMutableDictionary *m = [a mutableCopy];
                m[@"content"] = cleaned ?: @"";
                if (!apiCalls.count && textCalls.count) { m[@"tool_calls"] = textCalls; [m removeObjectForKey:@"raw"]; }
                MRGDJLog(@"chat: %lu tool call%@ written as text, run as calls", (unsigned long)textCalls.count, textCalls.count == 1 ? @"" : @"s");
                a = m;
            }
        }
        done(e ? nil : a, e);
    };
    switch (p) {
        case MRGProviderGemini: {
            NSString *path = [NSString stringWithFormat:@"/models/%@:generateContent", model];
            send(p, request(p, key, path, geminiToolBody(system, messages, tools)), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(e ? nil : geminiToolAnswer(j), e); });
            return;
        }
        case MRGProviderAnthropic: {
            send(p, request(p, key, @"/messages", anthropicToolBody(model, system, messages, tools)), ^(id j, NSData *d, NSInteger s, NSString *e) { finish(e ? nil : anthropicToolAnswer(j), e); });
            return;
        }
        case MRGProviderPerplexity: {
            // No function calling there: the conversation as text, answered without actions.
            NSMutableString *t = [NSMutableString string];
            for (NSDictionary *m in messages) {
                if ([m[@"role"] isEqualToString:@"tool"]) continue;
                [t appendFormat:@"%@: %@\n", [m[@"role"] isEqualToString:@"user"] ? @"Listener" : @"DJ", m[@"content"] ?: @""];
            }
            MRGAIChat(system, t, NO, ^(NSString *text, NSString *error) { finish(text ? @{@"role": @"assistant", @"content": text, @"tool_calls": @[]} : nil, error); });
            return;
        }
        default: {
            send(p, request(p, key, @"/chat/completions", openAIToolBody(p, model, system, messages, tools, YES)), ^(id j, NSData *d, NSInteger s, NSString *e) {
                // Groq (and some others) answer 400 tool_use_failed when the model botched a call, with what it wrote in
                // failed_generation: read the calls from that instead of failing.
                id err = [j isKindOfClass:NSDictionary.class] ? j[@"error"] : nil;
                NSString *failed = [err isKindOfClass:NSDictionary.class] ? str(err[@"failed_generation"]) : nil;
                if (s == 400 && failed.length && names.count) {
                    NSString *cleaned = nil;
                    NSArray *calls = MRGParseTextToolCalls(failed, names, &cleaned);
                    MRGDJLog(@"chat: %@ said tool_use_failed; %lu call%@ recovered from its text", MRGProviderName(p), (unsigned long)calls.count, calls.count == 1 ? @"" : @"s");
                    if (calls.count) { done(@{@"role": @"assistant", @"content": cleaned ?: @"", @"tool_calls": calls}, nil); return; }
                }
                if (s == 400) {
                    send(p, request(p, key, @"/chat/completions", openAIToolBody(p, model, system, messages, tools, NO)), ^(id j2, NSData *d2, NSInteger s2, NSString *e2) {
                        finish(e2 ? nil : openAIToolAnswer(j2), e2);
                    });
                    return;
                }
                finish(e ? nil : openAIToolAnswer(j), e);
            });
            return;
        }
    }
}
