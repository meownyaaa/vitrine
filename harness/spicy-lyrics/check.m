// Reads made-up Spicy Lyrics API responses through the real SGSpicyLyricsResult and checks the lines
// and the credit. The responses follow the shapes in developers.spicylyrics.org's Get Lyrics reference;
// the words are filler. Exits non-zero on the first wrong answer.
#import <UIKit/UIKit.h>
#import "Shared/LyricsSources/LyricsSources.h"

// What SpicyLyrics.m reaches outside the parser for; none of it but the result class is used here.
@implementation SGLyricsResult
@end
@implementation SGLyricsLink
@end
void SGLyricsPageLines(NSArray<SGKaraokeLine *> *lines, NSArray<NSNumber *> **starts, NSArray<NSString *> **texts) {
    *starts = [lines valueForKey:@"start"];
    *texts = @[];
}
void SGLyricsGetJSON(NSURL *url, NSDictionary *headers, void (^done)(id root)) { done(nil); }
@implementation SGLyricsQuery
@end
// The reply the next request gets, and how many were sent and lost.
static NSHTTPURLResponse *sg_reply;
static id sg_body;
static NSUInteger sg_sent, sg_lost;
static NSDictionary *sg_headers;
void SGLyricsGetJSONReply(NSURL *url, NSDictionary *headers, void (^done)(id root, NSHTTPURLResponse *response)) {
    sg_sent++;
    sg_headers = headers;
    done(sg_body, sg_reply);
}
void SGLyricsNoteReply(NSURLResponse *response, NSError *error) { if (error) sg_lost++; }
NSArray<NSString *> *SGLyricsOrder(void) { return @[]; }
void SGLyricsSetOrder(NSArray<NSString *> *keys) {}
SGModRow *SGStatActionRow(NSString *t, NSString *s, NSString *(^v)(void), void (^a)(void)) { return nil; }
UIViewController *SGTopController(void) { return nil; }
static NSString *sg_language;   // the Lyrics page's translation language, nil for Any
NSString *SGLyricsTranslationLanguage(void) { return sg_language; }

// SpicyLyrics.m's ask with the key passed in, its wait and its key check.
void SGSpicyLyricsAskWith(NSString *key, SGLyricsQuery *query, void (^done)(SGLyricsResult *result));
NSTimeInterval SGSpicyLyricsWait(NSHTTPURLResponse *reply, NSDate *now);
NSString *SGSpicyLyricsKeyProblem(NSString *key);

#define CHECK(cond) do { if (!(cond)) { fprintf(stderr, "FAILED line %d: %s\n", __LINE__, #cond); exit(1); } } while (0)

static NSHTTPURLResponse *reply(NSInteger status, NSDictionary *headers) {
    return [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://api.spicylyrics.org/"] statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
}

// Asks for a track and says what came back: the result, or nil, at once since the stub answers at once.
static SGLyricsResult *ask(NSString *trackID) {
    SGLyricsQuery *query = [SGLyricsQuery new];
    query.trackID = trackID;
    __block SGLyricsResult *answer = (id)@"unanswered";
    SGSpicyLyricsAskWith(@"sl_pk_harness_key", query, ^(SGLyricsResult *result) { answer = result; });
    CHECK(![(id)answer isEqual:@"unanswered"]);
    return answer;
}

static SGLyricsResult *parse(NSString *json) {
    return SGSpicyLyricsResult([NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil]);
}

int main(void) {
    @autoreleasepool {
        SGLyricsResult *syllable = parse(@"{\"Body\":{\"Type\":\"Syllable\",\"source\":\"spicy_lyrics\",\"StartTime\":1.5,\"EndTime\":9,"
            "\"UploadAttribution\":{\"Uploader\":{\"username\":\"up\"},\"Maker\":{\"username\":\"mk\"}},"
            "\"Content\":["
            "{\"Type\":\"Vocal\",\"OppositeAligned\":false,\"Lead\":{\"StartTime\":1.5,\"EndTime\":3,\"TranslatedText\":\"tr\",\"Syllables\":["
            "{\"Text\":\"Ev\",\"StartTime\":1.5,\"EndTime\":1.8,\"IsPartOfWord\":true},"
            "{\"Text\":\"ery\",\"StartTime\":1.8,\"EndTime\":2.2,\"IsPartOfWord\":false},"
            "{\"Text\":\"day\",\"StartTime\":2.2,\"EndTime\":3,\"IsPartOfWord\":false}]},"
            "\"Background\":[{\"StartTime\":2.5,\"EndTime\":3.5,\"Syllables\":[{\"Text\":\"(oh)\",\"StartTime\":2.5,\"EndTime\":3.5}]},"
            "{\"StartTime\":3.6,\"EndTime\":3.9,\"Syllables\":[{\"Text\":\"(yeah)\",\"StartTime\":3.6,\"EndTime\":3.9}]}]},"
            "{\"Type\":\"Vocal\",\"OppositeAligned\":true,\"Lead\":{\"StartTime\":4,\"EndTime\":9,\"Syllables\":["
            "{\"Text\":\"two\",\"StartTime\":4,\"EndTime\":9}]}}]},\"Status\":200,\"Type\":\"object\"}");
        CHECK(syllable.karaokeLines.count == 2);
        CHECK(syllable.wordTimed && syllable.synced);
        SGKaraokeLine *first = syllable.karaokeLines[0];
        CHECK([SGKaraokeLineText(first) isEqualToString:@"Every day"]);
        CHECK(first.words[0].start == 1500 && first.words[1].end == 2200);
        CHECK(first.words[1].joined && !first.words[2].joined);
        CHECK(first.start == 1500 && first.end == 3000);
        CHECK([first.translation isEqualToString:@"tr"]);
        CHECK([SGKaraokeLineText(first.backing) isEqualToString:@"(oh) (yeah)"] && first.backing.start == 2500 && first.backing.end == 3900);
        CHECK(first.align == SGKaraokeAlignLeading && syllable.karaokeLines[1].align == SGKaraokeAlignTrailing);
        CHECK([syllable.provider isEqualToString:@"Spicy Lyrics, synced by mk, uploaded by up"]);
        CHECK(syllable.creditRequired && !syllable.creditLinks);   // no addresses, nothing to open

        // The required credit's links, uploader first; a person with no http address has none.
        SGLyricsResult *linked = parse(@"{\"Body\":{\"Type\":\"Static\",\"source\":\"spicy_lyrics\",\"Lines\":[{\"Text\":\"a\"}],"
            "\"UploadAttribution\":{\"Uploader\":{\"username\":\"up\",\"url\":\"https://spicylyrics.org/u/up\"},"
            "\"Maker\":{\"username\":\"mk\",\"url\":\"https://spicylyrics.org/u/mk\"}}}}");
        CHECK(linked.creditLinks.count == 2 && [linked.creditLinks[0].title isEqualToString:@"Uploader: up"]
              && [linked.creditLinks[1].url.absoluteString isEqualToString:@"https://spicylyrics.org/u/mk"]);
        CHECK(parse(@"{\"Body\":{\"Type\":\"Static\",\"source\":\"spicy_lyrics\",\"Lines\":[{\"Text\":\"a\"}],"
            "\"UploadAttribution\":{\"Uploader\":{\"username\":\"up\",\"url\":\"javascript:x\"},"
            "\"Maker\":{\"username\":\"mk\",\"url\":\"https://spicylyrics.org/u/mk\"}}}}").creditLinks.count == 1);
        CHECK([parse(@"{\"Body\":{\"Type\":\"Static\",\"source\":\"other\",\"Lines\":[{\"Text\":\"a\"}]}}").provider
               isEqualToString:@"Spicy Lyrics, source unknown"]);

        // Pronunciation from each syllable's spelling, timed with it; the backing's from its own; the
        // translations of the lead and every background group joined; the line timed by the Lead.
        SGLyricsResult *spelt = parse(@"{\"Body\":{\"Type\":\"Syllable\",\"source\":\"spotify\",\"Content\":[{\"Lead\":{"
            "\"StartTime\":1,\"EndTime\":4,\"TranslatedText\":\"I\",\"Syllables\":["
            "{\"Text\":\"私\",\"TransliteratedText\":\"wata\",\"StartTime\":1.2,\"EndTime\":1.6,\"IsPartOfWord\":true},"
            "{\"Text\":\"は\",\"TransliteratedText\":\"shi wa\",\"StartTime\":1.6,\"EndTime\":2}]},"
            "\"Background\":[{\"TranslatedText\":\"oh\",\"Syllables\":[{\"Text\":\"ああ\",\"TransliteratedText\":\"aa\",\"StartTime\":2,\"EndTime\":3}]},"
            "{\"TranslatedText\":\"yes\",\"Syllables\":[{\"Text\":\"はい\",\"StartTime\":3,\"EndTime\":3.5}]}]},"
            "{\"Lead\":{\"TransliteratedText\":\"ko re\",\"Syllables\":[{\"Text\":\"これ\",\"StartTime\":5,\"EndTime\":6}]}},"
            "{\"Lead\":{\"TransliteratedText\":\"same\",\"TranslatedText\":\"Same!\",\"Syllables\":[{\"Text\":\"same\",\"StartTime\":7,\"EndTime\":8}]}}]}}");
        SGKaraokeLine *jp = spelt.karaokeLines[0];
        CHECK(jp.start == 1000 && jp.end == 4000);
        CHECK([SGKaraokeLineText(jp.pronunciation) isEqualToString:@"watashi wa"] && jp.pronunciation.words[1].start == 1600);
        CHECK([SGKaraokeLineText(jp.backing.pronunciation) isEqualToString:@"aa"]);
        CHECK([jp.translation isEqualToString:@"I oh yes"]);
        SGKaraokeLine *estimated = spelt.karaokeLines[1];
        CHECK([SGKaraokeLineText(estimated.pronunciation) isEqualToString:@"ko re"] && estimated.pronunciation.start == 5000);
        SGKaraokeLine *same = spelt.karaokeLines[2];
        CHECK(!same.pronunciation && !same.translation);   // both read the same as the line

        SGLyricsResult *line = parse(@"{\"Body\":{\"Type\":\"Line\",\"source\":\"spotify\",\"Content\":["
            "{\"Type\":\"Vocal\",\"Text\":\"one line\",\"StartTime\":10.81,\"EndTime\":12,\"OppositeAligned\":false},"
            "{\"Type\":\"Vocal\",\"Text\":\"\",\"StartTime\":12,\"EndTime\":20},"
            "{\"Type\":\"Vocal\",\"Text\":\"two line\",\"StartTime\":20,\"EndTime\":23,\"OppositeAligned\":true,\"TranslatedText\":\"zwei\"}]}}");
        CHECK(line.karaokeLines.count == 2);
        CHECK(line.synced && !line.wordTimed);
        CHECK(line.karaokeLines[0].start == 10810 && line.karaokeLines[0].end <= 12000);
        CHECK(line.karaokeLines[1].align == SGKaraokeAlignTrailing);
        CHECK(!line.karaokeLines[0].translation && [line.karaokeLines[1].translation isEqualToString:@"zwei"]);
        CHECK([line.provider isEqualToString:@"Spotify via Spicy Lyrics"]);
        CHECK([SGKaraokeLineText(parse(@"{\"Body\":{\"Type\":\"Line\",\"Content\":[{\"Text\":\"東京\",\"TransliteratedText\":\"Tokyo\","
            "\"StartTime\":1,\"EndTime\":3,\"OppositeAligned\":null}]}}").karaokeLines[0].pronunciation) isEqualToString:@"Tokyo"]);
        SGKaraokeLine *nulled = parse(@"{\"Body\":{\"Type\":\"Syllable\",\"Content\":[{\"OppositeAligned\":null,\"Lead\":{"
            "\"StartTime\":null,\"EndTime\":null,\"Syllables\":["
            "{\"Text\":\"ok\",\"StartTime\":1,\"EndTime\":2,\"IsPartOfWord\":null}]}}]}}").karaokeLines.firstObject;
        CHECK(nulled && nulled.start == 1000 && nulled.end == 2000);

        // With a language chosen, a translation the API names no language for is left out of both syncs.
        sg_language = @"es";
        CHECK(!parse(@"{\"Body\":{\"Type\":\"Line\",\"Content\":[{\"Text\":\"two line\",\"StartTime\":20,\"EndTime\":23,"
            "\"TranslatedText\":\"zwei\"}]}}").karaokeLines[0].translation);
        CHECK(!parse(@"{\"Body\":{\"Type\":\"Syllable\",\"Content\":[{\"Lead\":{\"TranslatedText\":\"tr\",\"Syllables\":["
            "{\"Text\":\"day\",\"StartTime\":2.2,\"EndTime\":3}]}}]}}").karaokeLines[0].translation);
        sg_language = nil;

        SGLyricsResult *plain = parse(@"{\"Body\":{\"Type\":\"Static\",\"source\":\"apple_music\",\"Lines\":[{\"Text\":\"\"},{\"Text\":\"a b\"},{\"Text\":\"\"},"
            "{\"Text\":\"\"},{\"Text\":\"c\",\"TranslatedText\":\"ce\"},{\"Text\":\"\"}]}}");
        CHECK(plain.karaokeLines.count == 2 && !plain.synced);
        // An empty row between lines is a ♪ on Spotify's page; one at either end is left off.
        CHECK([plain.texts isEqualToArray:(@[@"a b", @"♪", @"c"])] && [plain.starts isEqualToArray:(@[@0, @0, @0])]);
        CHECK(!plain.karaokeLines[0].translation && [plain.karaokeLines[1].translation isEqualToString:@"ce"]);
        CHECK([plain.provider isEqualToString:@"Apple Music via Spicy Lyrics"]);

        CHECK(!parse(@"{\"Body\":{\"Type\":\"Syllable\",\"Content\":[]}}"));
        CHECK(!parse(@"{\"error\":\"not found\"}"));
        // The key: publishable only.
        CHECK(!SGSpicyLyricsKeyProblem(@"sl_pk_abcdef123"));
        CHECK([SGSpicyLyricsKeyProblem(@"sl_sk_abcdef123") containsString:@"secret"]);
        CHECK(SGSpicyLyricsKeyProblem(@"sl_pk_abc") && SGSpicyLyricsKeyProblem(@"sl_pk_abc def 12") && SGSpicyLyricsKeyProblem(@"pk_abcdefghijkl"));

        // The wait a reply asks for.
        NSDate *now = [NSDate dateWithTimeIntervalSince1970:1700000000];
        CHECK(SGSpicyLyricsWait(reply(429, @{@"Retry-After": @"30", @"RateLimit-Reset": @"90"}), now) == 30);
        CHECK(SGSpicyLyricsWait(reply(503, @{@"RateLimit-Reset": @"90"}), now) == 90);
        CHECK(SGSpicyLyricsWait(reply(429, @{}), now) == 60);
        CHECK(SGSpicyLyricsWait(reply(429, @{@"Retry-After": @"99999"}), now) == 3600);
        CHECK(SGSpicyLyricsWait(reply(429, @{@"Retry-After": @"Tue, 14 Nov 2023 22:15:20 GMT"}), now) == 120);
        CHECK(SGSpicyLyricsWait(reply(200, @{@"RateLimit-Remaining": @"0", @"RateLimit-Reset": @"12"}), now) == 12);
        CHECK(SGSpicyLyricsWait(reply(200, @{@"RateLimit-Remaining": @"0", @"RateLimit-Reset": @"1700000045"}), now) == 45);
        CHECK(SGSpicyLyricsWait(reply(200, @{@"RateLimit-Remaining": @"3", @"RateLimit-Reset": @"12"}), now) == 0);

        // Asking: a bad id is never sent; an answer and a miss are kept; the request's headers.
        sg_body = [NSJSONSerialization JSONObjectWithData:[@"{\"Body\":{\"Type\":\"Static\",\"Lines\":[{\"Text\":\"a\"}]}}" dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        sg_reply = reply(200, @{});
        CHECK(!ask(@"0123456789abcdefghij-_") && !ask(@"short") && sg_sent == 0);
        CHECK(ask(@"0123456789abcdefghijkA") && sg_sent == 1);
        CHECK([sg_headers[@"Authorization"] isEqualToString:@"Bearer sl_pk_harness_key"] && [sg_headers[@"Accept"] isEqualToString:@"application/json"]
              && [sg_headers[@"User-Agent"] hasPrefix:@"Vitrine/"]);
        CHECK(ask(@"0123456789abcdefghijkA") && sg_sent == 1);
        sg_reply = reply(404, @{});
        sg_body = nil;
        CHECK(!ask(@"0123456789abcdefghijkB") && !ask(@"0123456789abcdefghijkB") && sg_sent == 2);

        // A 429 is waited out, each skip counted as lost; then asked again.
        sg_reply = reply(429, @{@"Retry-After": @"1"});
        CHECK(!ask(@"0123456789abcdefghijkC") && sg_sent == 3);
        CHECK(!ask(@"0123456789abcdefghijkC") && sg_sent == 3 && sg_lost == 1);
        [NSThread sleepForTimeInterval:1.1];
        sg_reply = reply(404, @{});
        CHECK(!ask(@"0123456789abcdefghijkC") && sg_sent == 4);

        // A refused key: the reason for the row, and no request for ten minutes.
        sg_reply = reply(401, @{});
        sg_body = @{@"Body": @{@"error": @"origin_not_allowed"}};
        CHECK(!ask(@"0123456789abcdefghijkD") && sg_sent == 5);
        CHECK(!ask(@"0123456789abcdefghijkE") && sg_sent == 5 && sg_lost == 1);
        puts("spicy lyrics: all checks passed");
    }
    return 0;
}
