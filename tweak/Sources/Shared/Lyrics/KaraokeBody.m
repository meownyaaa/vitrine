// Spotify's own lyrics bodies read into lines, apart from the rest of the lines' model (KaraokeTiming.m) so the
// model builds without the protobuf reader, as Vitrine Addon builds it.
#import "Lyrics.h"
#import "Shared/AdBlock/Protobuf.h"

// Lyrics { 1 data: { 1 time_synchronized, 2 repeated line: { 1 offset_ms, 2 content } }, 2 colors }
// Not time_synchronized, the lines are plain text and their offsets all 0. The flag alone is not
// trusted: Spotify's page body has come without it for lines its JSON calls LINE_SYNCED, so any
// offset past 0 counts as timed too.
static NSArray<SGKaraokeLine *> *fromProtobuf(NSData *body) {
    SGPBField *data = SGPBFirst(SGPBParse(body), 1);
    if (data.wire != 2) return nil;
    NSArray<SGPBField *> *fields = SGPBParse(data.payload);
    BOOL synced = SGPBFirst(fields, 1).varint != 0;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (SGPBField *field in fields) {
        if (field.number != 2 || field.wire != 2) continue;
        NSArray<SGPBField *> *line = SGPBParse(field.payload);
        int32_t start = (int32_t)SGPBFirst(line, 1).varint;
        if (start > 0) synced = YES;
        [starts addObject:@(start)];
        [texts addObject:SGPBText(SGPBFirst(line, 2)) ?: @""];
    }
    return synced ? SGKaraokeEstimatedLines(starts, texts) : SGKaraokeStaticLines(texts);
}

// { "lyrics": { "syncType": "LINE_SYNCED", "lines": [ { "startTimeMs": "1234", "words": "..." } ] } },
// or "UNSYNCED" with every start 0.
static NSArray<SGKaraokeLine *> *fromJSON(NSData *body) {
    NSDictionary *root = [NSJSONSerialization JSONObjectWithData:body options:0 error:nil];
    NSDictionary *lyrics = [root isKindOfClass:NSDictionary.class] ? root[@"lyrics"] : nil;
    if (![lyrics isKindOfClass:NSDictionary.class]) return nil;
    BOOL synced = [lyrics[@"syncType"] isEqual:@"LINE_SYNCED"];
    if (!synced && ![lyrics[@"syncType"] isEqual:@"UNSYNCED"]) return nil;
    NSMutableArray<NSNumber *> *starts = [NSMutableArray array];
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (NSDictionary *line in lyrics[@"lines"]) {
        if (![line isKindOfClass:NSDictionary.class]) continue;
        id words = line[@"words"];
        [starts addObject:@([line[@"startTimeMs"] integerValue])];
        [texts addObject:[words isKindOfClass:NSString.class] ? words : @""];
    }
    return synced ? SGKaraokeEstimatedLines(starts, texts) : SGKaraokeStaticLines(texts);
}

NSArray<SGKaraokeLine *> *SGKaraokeLinesFromBody(NSData *body) {
    if (!body.length) return nil;
    return ((const uint8_t *)body.bytes)[0] == '{' ? fromJSON(body) : fromProtobuf(body);
}
