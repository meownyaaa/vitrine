#import "Lyrics.h"

@implementation SGKaraokeWord
@end

@implementation SGKaraokeLine
- (id)copyWithZone:(NSZone *)zone {
    SGKaraokeLine *copy = [SGKaraokeLine new];
    copy.words = _words;
    copy.start = _start;
    copy.end = _end;
    copy.voice = _voice;
    copy.align = _align;
    copy.timing = _timing;
    copy.backing = _backing;
    copy.pronunciation = _pronunciation;
    copy.translation = _translation;
    copy.translationMade = _translationMade;
    return copy;
}
@end

// A line is sung at about this pace and never takes longer than the gap to the next one. A slow
// line gets at least 60 % of its gap, but not more than 1.8x the estimate, so a long instrumental
// after it does not stretch its last word across the break.
static const NSInteger kLineBaseMs = 350, kMsPerLetter = 75;
static const double kMinGapShare = 0.6, kMaxStretch = 1.8;
// Added to every word's letters, for the breath between words and so a one-letter word still shows.
static const NSUInteger kWordWeight = 2;
// A syllable of an unspaced script is one character but a whole beat, so it counts for this many
// letters; without it a Japanese line reads as a handful of letters and its sweep finishes early.
static const NSUInteger kSyllableLetters = 3;

#pragma mark - the model

NSString *SGKaraokeLineText(SGKaraokeLine *line) {
    NSMutableString *text = [NSMutableString string];
    for (SGKaraokeWord *word in line.words) {
        if (text.length && !word.joined) [text appendString:@" "];
        [text appendString:word.text ?: @""];
    }
    return text;
}

NSInteger SGKaraokeSungEnd(SGKaraokeLine *line) {
    return line.backing ? MAX(line.end, line.backing.end) : line.end;
}

NSInteger SGKaraokeLeadLine(NSArray<SGKaraokeLine *> *lines, NSInteger ms) {
    NSInteger last = -1;
    while (last + 1 < (NSInteger)lines.count && lines[(NSUInteger)last + 1].start <= ms) last++;
    for (NSInteger i = 0; i < last; i++) {
        if (SGKaraokeSungEnd(lines[(NSUInteger)i]) > ms) return i;
    }
    return last;
}

NSInteger SGKaraokeMsToChange(NSArray<SGKaraokeLine *> *lines, NSInteger position, NSInteger wordsOf) {
    NSInteger next = NSIntegerMax;
    for (SGKaraokeLine *line in lines) {
        NSInteger sungEnd = SGKaraokeSungEnd(line);
        NSInteger ats[] = {line.start, line.start - SGKaraokeBreakMs, sungEnd, line.end + SGKaraokeBreakMs + 1,
                           sungEnd + SGKaraokeBreakMs + 1};
        for (size_t i = 0; i < sizeof ats / sizeof *ats; i++) {
            if (ats[i] > position && ats[i] < next) next = ats[i];
        }
    }
    if (wordsOf >= 0) {
        for (SGKaraokeWord *word in lines[(NSUInteger)wordsOf].words) {
            if (word.start > position && word.start < next) next = word.start;
        }
    }
    return next == NSIntegerMax ? -1 : next - position;
}

// The letters and digits alone, lowercased: a pronunciation or a translation that reads the same as its
// line is the line again, as an English line of a Japanese song is spelled out as itself.
NSString *SGLyricsBareText(NSString *text) {
    NSMutableString *bare = [NSMutableString string];
    NSCharacterSet *kept = NSCharacterSet.alphanumericCharacterSet;
    NSString *lower = text.lowercaseString;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([kept characterIsMember:c]) [bare appendFormat:@"%C", c];
    }
    return bare;
}

static id lineInPlist(SGKaraokeLine *line) {
    if (!line) return nil;
    NSMutableArray *words = [NSMutableArray arrayWithCapacity:line.words.count];
    for (SGKaraokeWord *word in line.words) [words addObject:@[word.text ?: @"", @(word.start), @(word.end), @(word.joined)]];
    NSMutableDictionary *plist = [@{@"w": words, @"s": @(line.start), @"e": @(line.end), @"a": @(line.align), @"t": @(line.timing)} mutableCopy];
    if (line.voice) plist[@"v"] = line.voice;
    if (line.backing) plist[@"b"] = lineInPlist(line.backing);
    if (line.pronunciation) plist[@"p"] = lineInPlist(line.pronunciation);
    if (line.translation) plist[@"tr"] = line.translation;
    if (line.translationMade) plist[@"tm"] = @YES;
    return plist;
}

// A number of the plist, or nil for anything else: a file another process reads may hold anything.
static NSNumber *numberIn(id value) {
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

// `depth` keeps a line's backing and pronunciation, which hold lines of their own, from nesting past what a line has.
static SGKaraokeLine *lineFromPlist(id plist, int depth) {
    if (depth > 2 || ![plist isKindOfClass:NSDictionary.class] || ![plist[@"w"] isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    for (NSArray *fields in plist[@"w"]) {
        if (![fields isKindOfClass:NSArray.class] || fields.count < 4 || ![fields[0] isKindOfClass:NSString.class]) return nil;
        NSNumber *start = numberIn(fields[1]), *end = numberIn(fields[2]), *joined = numberIn(fields[3]);
        if (!start || !end || !joined) return nil;
        SGKaraokeWord *word = [SGKaraokeWord new];
        word.text = fields[0];
        word.start = start.integerValue;
        word.end = end.integerValue;
        word.joined = joined.boolValue;
        [words addObject:word];
    }
    NSNumber *start = numberIn(plist[@"s"]), *end = numberIn(plist[@"e"]);
    if (!start || !end) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start.integerValue;
    line.end = end.integerValue;
    line.align = numberIn(plist[@"a"]).unsignedIntegerValue == SGKaraokeAlignTrailing ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
    line.timing = MIN(numberIn(plist[@"t"]).unsignedIntegerValue, (NSUInteger)SGKaraokeTimingNone);
    if ([plist[@"v"] isKindOfClass:NSString.class]) line.voice = plist[@"v"];
    line.backing = lineFromPlist(plist[@"b"], depth + 1);
    line.pronunciation = lineFromPlist(plist[@"p"], depth + 1);
    if ([plist[@"tr"] isKindOfClass:NSString.class]) line.translation = plist[@"tr"];
    line.translationMade = numberIn(plist[@"tm"]).boolValue;
    return line;
}

NSArray *SGKaraokeLinesPlist(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray *plist = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) [plist addObject:lineInPlist(line)];
    return plist;
}

NSArray<SGKaraokeLine *> *SGKaraokeLinesFromPlist(id plist) {
    if (![plist isKindOfClass:NSArray.class]) return nil;
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray arrayWithCapacity:[plist count]];
    for (id entry in plist) {
        SGKaraokeLine *line = lineFromPlist(entry, 0);
        if (!line) return nil;
        [lines addObject:line];
    }
    return lines;
}

// Japanese, Chinese and Korean, and the punctuation set with them. Kana and Hangul are listed as
// well as the ideographs: a line of either is written without spaces just the same.
static NSCharacterSet *unspacedScript(void) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *building = [NSMutableCharacterSet new];
        [building addCharactersInRange:NSMakeRange(0x3000, 0x40)];    // CJK punctuation
        [building addCharactersInRange:NSMakeRange(0x3040, 0xC0)];    // hiragana and katakana
        [building addCharactersInRange:NSMakeRange(0x3400, 0x9C0)];   // ideographs, extension A
        [building addCharactersInRange:NSMakeRange(0x4E00, 0x5200)];  // ideographs
        [building addCharactersInRange:NSMakeRange(0xAC00, 0x2BA4)];  // hangul syllables
        [building addCharactersInRange:NSMakeRange(0xF900, 0x200)];   // compatibility ideographs
        [building addCharactersInRange:NSMakeRange(0xFF66, 0x38)];    // halfwidth katakana
        set = [building copy];
    });
    return set;
}

BOOL SGKaraokeUnspacedScript(NSString *text) {
    return text.length && [text rangeOfCharacterFromSet:unspacedScript()].location != NSNotFound;
}

@implementation SGKaraokePiece
@end

SGKaraokeLine *SGKaraokePieceLine(NSArray<SGKaraokePiece *> *pieces, NSInteger start, NSInteger end) {
    NSMutableArray<SGKaraokeWord *> *words = [NSMutableArray array];
    SGKaraokeWord *open = nil;   // the word the next piece runs on into
    BOOL spaced = YES;           // a space has gone by, so the next word is not joined to the last
    for (SGKaraokePiece *piece in pieces) {
        if (piece.spaceBefore) {
            open = nil;
            spaced = YES;
        }
        // A source times a Chinese or Japanese syllable a piece at a time and never spaces them, so
        // running them together would light a line up whole instead of sweeping it.
        BOOL unspaced = SGKaraokeUnspacedScript(piece.text);
        if (piece.text.length && open && !unspaced) {
            open.text = [open.text stringByAppendingString:piece.text];
            open.end = MAX(open.end, piece.end);
        } else if (piece.text.length) {
            SGKaraokeWord *word = [SGKaraokeWord new];
            word.text = piece.text;
            word.start = piece.start;
            word.end = piece.end;
            word.joined = !spaced;
            [words addObject:word];
            open = unspaced ? nil : word;
            spaced = NO;
        }
        if (!piece.text.length || piece.spaceAfter) {
            open = nil;
            spaced = YES;
        }
    }
    if (!words.count) return nil;
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start;
    line.end = MAX(end, words.lastObject.end);
    return line;
}

// Thai, Lao, Burmese and Khmer, which leave no space between words either, but whose syllables are a
// letter with marks around it: they are split where the system's dictionary finds a word, not a
// character at a time.
static BOOL dictionaryScript(NSString *text) {
    static NSCharacterSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *building = [NSMutableCharacterSet new];
        [building addCharactersInRange:NSMakeRange(0x0E00, 0x100)];   // Thai and Lao
        [building addCharactersInRange:NSMakeRange(0x1000, 0xA0)];    // Myanmar
        [building addCharactersInRange:NSMakeRange(0x1780, 0x80)];    // Khmer
        set = [building copy];
    });
    return [text rangeOfCharacterFromSet:set].location != NSNotFound;
}

void SGKaraokeAlignVoices(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray<NSString *> *heard = [NSMutableArray array];
    for (SGKaraokeLine *line in lines) {
        if (!line.voice.length || [heard containsObject:line.voice]) continue;
        [heard addObject:line.voice];
    }
    if (heard.count < 2) return;   // one voice, or none named: every line leads, as it already does
    NSString *trailing = heard[1];
    for (SGKaraokeLine *line in lines) {
        line.align = [line.voice isEqualToString:trailing] ? SGKaraokeAlignTrailing : SGKaraokeAlignLeading;
        line.backing.align = line.align;
    }
}

#pragma mark - estimating the words inside a line

static NSUInteger lettersIn(NSString *text) {
    __block NSUInteger count = 0;
    NSCharacterSet *letters = NSCharacterSet.alphanumericCharacterSet, *unspaced = unspacedScript();
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length)
                             options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
        if ([unspaced characterIsMember:[piece characterAtIndex:0]]) count += kSyllableLetters;
        else if ([letters characterIsMember:[piece characterAtIndex:0]]) count++;
    }];
    return count;
}

static void appendPiece(NSMutableArray<SGKaraokeWord *> *pieces, NSString *text) {
    if (!text.length) return;
    SGKaraokeWord *word = [SGKaraokeWord new];
    word.text = text;
    [pieces addObject:word];
}

// A token cut at the start of every word the system finds in it, so the pieces still make up the
// whole token: whatever comes between two words stays with the first, whatever comes before the
// first word with it.
static void appendWords(NSMutableArray<SGKaraokeWord *> *pieces, NSString *token) {
    NSMutableArray<NSNumber *> *cuts = [NSMutableArray arrayWithObject:@0];
    __block BOOL first = YES;
    [token enumerateSubstringsInRange:NSMakeRange(0, token.length)
                              options:NSStringEnumerationByWords | NSStringEnumerationSubstringNotRequired
                           usingBlock:^(NSString *word, NSRange range, NSRange enclosing, BOOL *stop) {
        if (!first && range.location > cuts.lastObject.unsignedIntegerValue) [cuts addObject:@(range.location)];
        first = NO;
    }];
    [cuts addObject:@(token.length)];
    for (NSUInteger i = 0; i + 1 < cuts.count; i++) {
        NSUInteger from = cuts[i].unsignedIntegerValue;
        appendPiece(pieces, [token substringWithRange:NSMakeRange(from, cuts[i + 1].unsignedIntegerValue - from)]);
    }
}

// The line split into what the sweep lights one at a time: words where the script spaces them, a
// syllable at a time where it does not, so a Japanese line sweeps instead of lighting up whole, and
// the dictionary's words in Thai and its neighbors, so a long line wraps between them.
// Everything a token holds past its first piece is joined to the one before it.
static NSArray<SGKaraokeWord *> *piecesOf(NSString *line) {
    NSMutableArray<SGKaraokeWord *> *pieces = [NSMutableArray array];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]) {
        if (!token.length) continue;
        NSUInteger first = pieces.count;
        if (!SGKaraokeUnspacedScript(token)) {
            if (dictionaryScript(token)) appendWords(pieces, token);
            else appendPiece(pieces, token);
        } else {
            // Latin letters or digits caught between two syllables stay together as one piece.
            NSMutableString *run = [NSMutableString string];
            NSCharacterSet *unspaced = unspacedScript();
            [token enumerateSubstringsInRange:NSMakeRange(0, token.length)
                                      options:NSStringEnumerationByComposedCharacterSequences
                                   usingBlock:^(NSString *piece, NSRange a, NSRange b, BOOL *stop) {
                if (![unspaced characterIsMember:[piece characterAtIndex:0]]) {
                    [run appendString:piece];
                    return;
                }
                appendPiece(pieces, [run copy]);
                [run setString:@""];
                appendPiece(pieces, piece);
            }];
            appendPiece(pieces, [run copy]);
        }
        for (NSUInteger i = first + 1; i < pieces.count; i++) pieces[i].joined = YES;
    }
    return pieces;
}

static BOOL isBreak(NSString *text) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length == 0 || [trimmed isEqualToString:@"♪"];
}

// gap is the time to the next line, 0 for the last one.
static SGKaraokeLine *timedLine(NSString *text, NSInteger start, NSInteger gap) {
    NSArray<SGKaraokeWord *> *words = piecesOf(text);
    NSUInteger weight = 0, letters = 0;
    for (SGKaraokeWord *word in words) {
        NSUInteger count = lettersIn(word.text);
        letters += count;
        weight += count + kWordWeight;
    }
    NSInteger estimate = kLineBaseMs + (NSInteger)letters * kMsPerLetter;
    NSInteger sung = estimate;
    if (gap > 0) {
        sung = MAX((NSInteger)(gap * kMinGapShare), estimate);
        sung = MIN(sung, (NSInteger)(estimate * kMaxStretch));
        sung = MIN(sung, gap);
    }

    double at = start;
    for (SGKaraokeWord *word in words) {
        word.start = (NSInteger)at;
        at += weight ? (double)sung * (lettersIn(word.text) + kWordWeight) / weight : 0;
        word.end = (NSInteger)at;
    }
    SGKaraokeLine *line = [SGKaraokeLine new];
    line.words = words;
    line.start = start;
    line.end = start + sung;
    line.timing = SGKaraokeTimingLine;
    return line;
}

NSArray<SGKaraokeLine *> *SGKaraokeEstimatedLines(NSArray<NSNumber *> *starts, NSArray<NSString *> *texts) {
    // A line listed out of time order is given the gap to the line sung after it, not the one listed after
    // it. The lines stay in the order they were listed: a source pairs them up with its own by position, and
    // the lines are put in time order where they are kept (SGKaraokeInTimeOrder).
    NSUInteger count = MIN(texts.count, starts.count);
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        if (isBreak(texts[i])) continue;
        NSInteger start = starts[i].integerValue, gap = 0;
        for (NSUInteger j = 0; j < count; j++) {   // ponytail: quadratic, a song's few hundred lines at most
            NSInteger after = starts[j].integerValue - start;
            if (after > 0 && (!gap || after < gap)) gap = after;
        }
        [lines addObject:timedLine(texts[i], start, gap)];
    }
    return lines.count ? lines : nil;
}

NSArray<SGKaraokeLine *> *SGKaraokeStaticLines(NSArray<NSString *> *texts) {
    NSMutableArray<SGKaraokeLine *> *lines = [NSMutableArray array];
    for (NSString *text in texts) {
        if (![text isKindOfClass:NSString.class] || isBreak(text)) continue;
        NSArray<SGKaraokeWord *> *words = piecesOf(text);
        if (!words.count) continue;
        SGKaraokeLine *line = [SGKaraokeLine new];
        line.words = words;
        line.timing = SGKaraokeTimingNone;
        [lines addObject:line];
    }
    return lines.count ? lines : nil;
}

SGKaraokeTiming SGKaraokeLinesTiming(NSArray<SGKaraokeLine *> *lines) {
    SGKaraokeTiming finest = SGKaraokeTimingNone;
    for (SGKaraokeLine *line in lines) finest = MIN(finest, line.timing);
    return finest;
}

// Some sources list a line out of its place in time: a chorus written once with its repeats after it,
// or one voice's lines listed after the other's. Everything that reads lines takes them in time order.
NSArray<SGKaraokeLine *> *SGKaraokeInTimeOrder(NSArray<SGKaraokeLine *> *lines) {
    for (NSUInteger i = 1; i < lines.count; i++) {
        if (lines[i].start >= lines[i - 1].start) continue;
        return [lines sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(SGKaraokeLine *a, SGKaraokeLine *b) {
            return a.start < b.start ? NSOrderedAscending : a.start > b.start ? NSOrderedDescending : NSOrderedSame;
        }];
    }
    return lines;
}

BOOL SGKaraokeHasTranslations(NSArray<SGKaraokeLine *> *lines) {
    for (SGKaraokeLine *line in lines) {
        if (line.translation.length) return YES;
    }
    return NO;
}
