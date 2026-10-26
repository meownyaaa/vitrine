// A line in the Latin alphabet, offline, by Apple's own transforms (ICU's under them). Japanese goes
// through the tokenizer's Latin transcription, which reads kanji the Japanese way: Any-Latin alone
// reads them as Mandarin (君の名前 as "jūnno míng qián" instead of "kimi no namae"). Pinyin keeps its
// tone marks; every other script is brought down to plain ASCII, which reads better sung along to
// than ICU's scholarly marks (Greek "Kalēméra", Thai "s̄wạs̄dī").
//
// ponytail: ICU transliterates rather than reads aloud: Arabic and Hebrew come out as their consonants
// ("mrhba"), Thai in ISO 11940's spelling rather than the one signs use, and a line mixing Latin with
// another script loses the Latin part's accents ("Café" as "Cafe"). A reading per language is the upgrade.
#import "Lyrics.h"
#import <objc/runtime.h>

NSNotificationName const SGLyricsRomanisedDidChangeNotification = @"spotifyglass.lyricsRomanisedDidChange";

typedef NS_ENUM(NSUInteger, SGScript) { SGScriptKana, SGScriptNotLatin, SGScriptHan };

// Compiled once: every line on the page is looked at.
static BOOL has(NSString *text, SGScript script) {
    static NSRegularExpression *patterns[3];
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *sources = @[@"[\\p{Hiragana}\\p{Katakana}]", @"[\\p{L}&&[^\\p{Latin}]]", @"\\p{Han}"];
        for (NSUInteger i = 0; i < 3; i++) patterns[i] = [NSRegularExpression regularExpressionWithPattern:sources[i] options:0 error:NULL];
    });
    return [patterns[script] rangeOfFirstMatchInString:text options:0 range:NSMakeRange(0, text.length)].location != NSNotFound;
}

static BOOL hasKana(NSString *text) {
    return has(text, SGScriptKana);
}

BOOL SGLyricsLooksJapanese(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        if (hasKana(SGKaraokeLineText(line))) return YES;
    }
    return NO;
}

// The tokenizer's reading of each word, a space between words; what it has no reading for (punctuation,
// another script) is kept for the transform after it.
static NSString *readJapanese(NSString *text) {
    NSMutableString *read = [NSMutableString string];
    CFLocaleRef japanese = CFLocaleCreate(NULL, CFSTR("ja"));
    CFStringTokenizerRef words = CFStringTokenizerCreate(NULL, (__bridge CFStringRef)text, CFRangeMake(0, text.length),
                                                         kCFStringTokenizerUnitWord, japanese);
    NSUInteger from = 0;
    while (CFStringTokenizerAdvanceToNextToken(words) != kCFStringTokenizerTokenNone) {
        CFRange range = CFStringTokenizerGetCurrentTokenRange(words);
        NSString *between = [text substringWithRange:NSMakeRange(from, range.location - from)];
        NSString *word = CFBridgingRelease(CFStringTokenizerCopyCurrentTokenAttribute(words, kCFStringTokenizerAttributeLatinTranscription));
        if (read.length && !between.length) [read appendString:@" "];
        [read appendString:between];
        [read appendString:word ?: [text substringWithRange:NSMakeRange(range.location, range.length)]];
        from = range.location + range.length;
    }
    [read appendString:[text substringFromIndex:from]];
    CFRelease(words);
    CFRelease(japanese);
    return read;
}

NSString *SGLyricsRomanised(NSString *text, BOOL japanese) {
    if (!text.length) return nil;
    static NSCache<NSString *, NSString *> *kept;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ kept = [NSCache new]; });
    NSString *key = japanese ? [@"ja:" stringByAppendingString:text] : text;
    NSString *romanised = [kept objectForKey:key];
    if (romanised) return romanised.length ? romanised : nil;
    // Only a line with a letter of another script: Latin with accents (German, Vietnamese) is left alone.
    if (!has(text, SGScriptNotLatin)) {
        [kept setObject:@"" forKey:key];
        return nil;
    }
    BOOL kana = japanese || hasKana(text);
    NSString *source = kana ? readJapanese(text) : text;
    // Han left over is Chinese: its pinyin keeps the tones, and only its punctuation is made ASCII.
    NSString *transform = !kana && has(text, SGScriptHan) ? @"Any-Latin; [[:P:][:Zs:]] Latin-ASCII" : @"Any-Latin; Latin-ASCII";
    romanised = [[source stringByApplyingTransform:transform reverse:NO]
                 stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"";
    if ([romanised caseInsensitiveCompare:text] == NSOrderedSame) romanised = @"";
    [kept setObject:romanised forKey:key];
    return romanised.length ? romanised : nil;
}

static char kRomanisedLineKey;

SGKaraokeLine *SGLyricsRomanisedLine(SGKaraokeLine *line, BOOL japanese) {
    if (!line) return nil;
    id cached = objc_getAssociatedObject(line, &kRomanisedLineKey);
    if (cached) {
        if (cached == NSNull.null) return nil;
        SGKaraokeLine *r = (SGKaraokeLine *)cached;
        r.translation = line.translation;
        r.translationMade = line.translationMade;
        return r;
    }

    NSString *text = SGKaraokeLineText(line);
    NSString *pronText = line.pronunciation.words.count ? SGKaraokeLineText(line.pronunciation) : nil;
    SGKaraokeLine *romanised = nil;
    if (pronText.length && has(text, SGScriptNotLatin) && !has(pronText, SGScriptNotLatin)) {
        romanised = [line.pronunciation copy];
        romanised.translation = line.translation;
        romanised.translationMade = line.translationMade;
        if (line.backing) {
            romanised.backing = SGLyricsRomanisedLine(line.backing, japanese) ?: line.backing;
        }
    } else {
        NSString *romanisedText = SGLyricsRomanised(text, japanese);
        if (romanisedText.length && [romanisedText caseInsensitiveCompare:text] != NSOrderedSame) {
            if (line.timing == SGKaraokeTimingNone) {
                romanised = SGKaraokeStaticLines(@[romanisedText]).firstObject;
            } else {
                NSInteger start = line.start;
                NSInteger end = line.end > line.start ? line.end : line.start + 3000;
                romanised = SGKaraokeEstimatedLines(@[@(start), @(end)], @[romanisedText, @""]).firstObject;
                if (romanised && line.end > start) {
                    NSInteger targetSpan = line.end - start;
                    NSInteger genSpan = romanised.end - start;
                    if (genSpan > 0 && genSpan != targetSpan) {
                        for (SGKaraokeWord *w in romanised.words) {
                            w.start = start + (NSInteger)llround((double)(w.start - start) * targetSpan / genSpan);
                            w.end = start + (NSInteger)llround((double)(w.end - start) * targetSpan / genSpan);
                        }
                    }
                    romanised.start = start;
                    romanised.end = line.end;
                }
            }
            if (romanised) {
                romanised.align = line.align;
                romanised.voice = line.voice;
                romanised.translation = line.translation;
                romanised.translationMade = line.translationMade;
                if (line.backing) {
                    romanised.backing = SGLyricsRomanisedLine(line.backing, japanese) ?: line.backing;
                }
            }
        } else if (line.backing) {
            SGKaraokeLine *romanisedBacking = SGLyricsRomanisedLine(line.backing, japanese);
            if (romanisedBacking) {
                romanised = [line copy];
                romanised.backing = romanisedBacking;
            }
        }
    }

    objc_setAssociatedObject(line, &kRomanisedLineKey, romanised ?: NSNull.null, OBJC_ASSOCIATION_RETAIN);
    return romanised;
}
