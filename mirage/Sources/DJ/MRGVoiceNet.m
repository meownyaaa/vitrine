#import "MRGVoiceNet.h"
#import "MRGKeychain.h"
#import "MRGDJLog.h"
#include <stdint.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static NSUserDefaults *D(void) { return NSUserDefaults.standardUserDefaults; }

#pragma mark - Edge: Sec-MS-GEC v2

// Edge's speech service wants a Sec-MS-GEC token: from the current 5-minute window in Windows file time, a salted
// SHA-256 and a CS64 checksum. Ported from edge-tts (src/edge_tts/drm.py, generate_sec_ms_gec_v2, LGPL-3.0) and checked
// against it for several timestamps.
static const uint32_t gec_SHA256_INITIAL[8] = {0x6A09E667,0xBB67AE85,0x3C6EF372,0xA54FF53A,0x510E527F,0x9B05688C,0x1F83D9AB,0x5BE0CD19};
static const uint32_t gec_SHA256_STATE[8] = {0xFD9FBEA2,0x91243CE7,0xBE499094,0xCD2E1E0A,0x6C006F49,0x04BD35AB,0xFEB0A7E4,0x03EFFBD2};
static const uint32_t gec_SHA256_SCHEDULE[14] = {0xEB24BF9E,0x1558691F,0xA0C09EE2,0x0CFA32BA,0xA622EE8C,0xD1DD9491,0xC0DD25A0,0xF9E70AB6,0xF0C31573,0x7058CE4E,0x7188E606,0x00E5AB33,0xD258B060,0x72766564};
static const uint32_t gec_SHA256_ROUND_CONSTANTS[64] = {0x428A2F98,0x71374491,0xB5C0FBCF,0xE9B5DBA5,0x3956C25B,0x59F111F1,0x923F82A4,0xAB1C5ED5,0xD807AA98,0x12835B01,0x243185BE,0x550C7DC3,0x72BE5D74,0x80DEB1FE,0x9BDC06A7,0xC19BF174,0xE49B69C1,0xEFBE4786,0x0FC19DC6,0x240CA1CC,0x2DE92C6F,0x4A7484AA,0x5CB0A9DC,0x76F988DA,0x983E5152,0xA831C66D,0xB00327C8,0xBF597FC7,0xC6E00BF3,0xD5A79147,0x06CA6351,0x14292967,0x27B70A85,0x2E1B2138,0x4D2C6DFC,0x53380D13,0x650A7354,0x766A0ABB,0x81C2C92E,0x92722C85,0xA2BFE8A1,0xA81A664B,0xC24B8B70,0xC76C51A3,0xD192E819,0xD6990624,0xF40E3585,0x106AA070,0x19A4C116,0x1E376C08,0x2748774C,0x34B0BCB5,0x391C0CB3,0x4ED8AA4A,0x5B9CCA4F,0x682E6FF3,0x748F82EE,0x78A5636F,0x84C87814,0x8CC70208,0x90BEFFFA,0xA4506CEB,0xBEF9A3F7,0xC67178F2};
static const uint32_t gec_CS64[14][2] = {{0xE82E91B1,0xB32700D0},{0x44DE24C6,0x88DFF51D},{0x3BEB65BC,0x29514038},{0xC89C5933,0xB328CBDF},{0x8D1EC211,0xD405B4D5},{0x314EF5D5,0x26E55F3C},{0xE92491B1,0x607801C6},{0xF0A5B9D5,0x82B2C1FB},{0x06064CF3,0xFA51A3DA},{0xDA79FA60,0x207CC464},{0xBED20560,0x3C3C74F3},{0x89F9C9F8,0xD2D14B61},{0x35FA38C6,0xBB04A2C1},{0xCB49E3C6,0xC5626167}};
#define ROTR(x,n) (((x)>>(n))|((x)<<(32-(n))))
static uint32_t gs0(uint32_t x){return ROTR(x,7)^ROTR(x,18)^(x>>3);}
static uint32_t gs1(uint32_t x){return ROTR(x,17)^ROTR(x,19)^(x>>10);}
static uint32_t rol16(uint32_t v){return (v<<16)|(v>>16);}
static void gecExpand(uint32_t *w,int first){for(int i=first;i<64;i++)w[i]=gs1(w[i-2])+w[i-7]+gs0(w[i-15])+w[i-16];}
static void gecRounds(const uint32_t *st,const uint32_t *w,int first,uint32_t *out){
    uint32_t k[64]; memcpy(k,gec_SHA256_ROUND_CONSTANTS,sizeof k); if(first==14)k[14]=0xC9DC06A7;
    uint32_t a=st[0],b=st[1],c=st[2],d=st[3],e=st[4],f=st[5],g=st[6],h=st[7];
    for(int i=first;i<64;i++){
        uint32_t t1=h+(ROTR(e,6)^ROTR(e,11)^ROTR(e,25))+(g^(e&(f^g)))+k[i]+w[i];
        uint32_t t2=(ROTR(a,2)^ROTR(a,13)^ROTR(a,22))+((a&b)|(c&(a|b)));
        h=g;g=f;f=e;e=d+t1;d=c;c=b;b=a;a=t1+t2;}
    out[0]=a;out[1]=b;out[2]=c;out[3]=d;out[4]=e;out[5]=f;out[6]=g;out[7]=h;}
static void gecSha(const uint8_t *data,size_t len,uint8_t dig[32]){
    uint32_t w[64]={0};
    w[14]=((uint32_t)data[0]<<16)|((uint32_t)data[1]<<8)|data[2];
    w[15]=((uint32_t)data[3]<<24)|((uint32_t)data[4]<<16)|((uint32_t)data[5]<<8)|data[6];
    for(int i=16;i<30;i++){uint32_t v=gec_SHA256_SCHEDULE[i-16];
        if(i-2>=14)v+=(i==16)?(gs1(w[i-2])^0x000B92C0):gs1(w[i-2]);
        if(i-7>=14)v+=w[i-7];
        if(i-15>=14)v+=(i==29)?(gs0(w[i-15])^0x059C0B80):gs0(w[i-15]);
        w[i]=v;}
    w[30]=gs1(w[28])+w[23]+gs0(w[15])+w[14]+0xC9DC06A7-gec_SHA256_ROUND_CONSTANTS[14];
    gecExpand(w,31);
    uint32_t st[8],wk[8]; gecRounds(gec_SHA256_STATE,w,14,wk);
    for(int i=0;i<8;i++)st[i]=gec_SHA256_INITIAL[i]+wk[i];
    size_t length=57+len, rest=len-7; size_t pad=(size_t)(((55-(long)length)%64+64)%64);
    size_t tot=rest+1+pad+8; uint8_t *p=calloc(tot,1); memcpy(p,data+7,rest); p[rest]=0x80;
    uint64_t bits=(uint64_t)length*8; for(int i=0;i<8;i++)p[tot-1-i]=(uint8_t)(bits>>(8*i));
    for(size_t off=0;off<tot;off+=64){uint32_t ww[64];
        for(int i=0;i<16;i++)ww[i]=((uint32_t)p[off+4*i]<<24)|((uint32_t)p[off+4*i+1]<<16)|((uint32_t)p[off+4*i+2]<<8)|p[off+4*i+3];
        gecExpand(ww,16); gecRounds(st,ww,0,wk); for(int i=0;i<8;i++)st[i]+=wk[i];}
    free(p);
    for(int i=0;i<8;i++){dig[4*i]=st[i]>>24;dig[4*i+1]=st[i]>>16;dig[4*i+2]=st[i]>>8;dig[4*i+3]=st[i];}}
static void gecCS64(const uint8_t *data,size_t len,const uint8_t dig[32],uint32_t out[2]){
    uint32_t ka=dig[0]|(dig[1]<<8)|(dig[2]<<16)|((uint32_t)dig[3]<<24), kb=dig[4]|(dig[5]<<8)|(dig[6]<<16)|((uint32_t)dig[7]<<24);
    ka|=1;kb|=1; uint32_t fac[2]={ka*0x82893933u,kb*0x82893933u};
    size_t blen=len+1; size_t plen=(blen+3)/4*4; size_t nw=plen/4; if(nw%2)nw++;
    uint8_t *b=calloc(nw*4,1); memcpy(b+1,data,len);
    size_t n=14+nw; uint32_t *terms=malloc(n*4),*offs=malloc(n*4);
    for(int i=0;i<14;i++){terms[i]=gec_CS64[i][0]*fac[i%2];offs[i]=gec_CS64[i][1];}
    for(size_t i=0;i<nw;i++){uint32_t wd=b[4*i]|(b[4*i+1]<<8)|(b[4*i+2]<<16)|((uint32_t)b[4*i+3]<<24);
        uint32_t term=wd*((i%2==0)?ka:kb), off=rol16(wd)*((i%2==0)?0xEF0569FBu:0xC31713DBu);
        if(i==0){term+=0xF2F90B1Au*fac[0];off+=0x0B1A0000u;}
        terms[14+i]=term;offs[14+i]=off;}
    uint32_t sacc=0,slast=0,state=0,acc=0;
    for(size_t i=0;i<n;i+=2){uint32_t x=terms[i],y=terms[i+1];
        uint32_t t=rol16(offs[i]+x); uint32_t q=t*0x76F50F34u; sacc+=rol16(q)*0xC3EFEA97u+q;
        t=rol16(offs[i+1]+y); q=t*0x1881CE3Cu; slast=rol16(q)*0x35BD1EC9u+q; sacc+=slast;
        state=state*ka+x; state=rol16(state)*0xCF98B111u; state=rol16(state)*0x87085B9Fu; state=rol16(state)*0x12CEB96Du; state=rol16(state)*0x257E1D83u;
        acc+=state; t=state*kb+y; t=rol16(t)*0xA27416F5u; t=rol16(t)*0xD38396FFu; state=rol16(rol16(t)*0x7C932B89u)*0xBFA49F69u; acc+=state;}
    out[0]=slast^state; out[1]=sacc^acc; free(b);free(terms);free(offs);}
// "<16 hex>-<64 hex>" for a unix time.
static void gecToken(double ut,char out[82]){
    long long t=(long long)ut+11644473600LL; t-=t%300; char s[64]; snprintf(s,sizeof s,"%lld0000000%s",t,"6A5AA1D4EAFF4E9FB37E23D68491D6F4");
    uint8_t d[32]; gecSha((uint8_t*)s,strlen(s),d); uint32_t c[2]; gecCS64((uint8_t*)s,strlen(s),d,c);
    uint8_t cb[8]; for(int i=0;i<4;i++){cb[i]=c[0]>>(8*i);cb[4+i]=c[1]>>(8*i);}
    char *o=out; for(int i=0;i<8;i++)o+=sprintf(o,"%02X",cb[i]); *o++='-'; for(int i=0;i<32;i++)o+=sprintf(o,"%02X",d[i]);}

NSString *MRGEdgeToken(double unixTime) {
    char out[82] = {0};
    gecToken(unixTime, out);
    return [NSString stringWithUTF8String:out];
}

#pragma mark - Edge voices

static NSString *const kEdgeVersion = @"2-143.0.3650.75";
static NSString *const kEdgeToken = @"6A5AA1D4EAFF4E9FB37E23D68491D6F4";
static NSString *const kEdgeUA = @"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0";

NSArray<NSDictionary *> *MRGEdgeVoices(void) {
    static NSArray *list;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray *raw = @[
            @[@"en-US-AvaMultilingualNeural", @"Ava", @"US · female · expressive, caring"],
            @[@"en-US-AvaNeural", @"Ava (soft)", @"US · female · soft, intimate"],
            @[@"en-US-EmmaMultilingualNeural", @"Emma", @"US · female · bright, cheerful"],
            @[@"en-US-EmmaNeural", @"Emma (calm)", @"US · female · warm, calm"],
            @[@"en-US-JennyNeural", @"Jenny", @"US · female · friendly, comforting"],
            @[@"en-US-AriaNeural", @"Aria", @"US · female · positive, confident"],
            @[@"en-US-MichelleNeural", @"Michelle", @"US · female · pleasant"],
            @[@"en-US-AnaNeural", @"Ana", @"US · child voice"],
            @[@"en-GB-SoniaNeural", @"Sonia", @"UK · female"],
            @[@"en-GB-MaisieNeural", @"Maisie", @"UK · female · young"],
            @[@"en-AU-NatashaNeural", @"Natasha", @"Australia · female"],
            @[@"en-US-AndrewNeural", @"Andrew", @"US · male · warm, confident"],
            @[@"en-US-BrianMultilingualNeural", @"Brian", @"US · male · casual, sincere"],
            @[@"en-US-GuyNeural", @"Guy", @"US · male · passionate"],
            @[@"en-US-ChristopherNeural", @"Christopher", @"US · male · deep, authoritative"],
            @[@"en-US-RogerNeural", @"Roger", @"US · male · lively"],
            @[@"en-US-EricNeural", @"Eric", @"US · male · calm"],
            @[@"en-GB-RyanNeural", @"Ryan", @"UK · male"],
        ];
        NSMutableArray *a = [NSMutableArray array];
        for (NSArray *r in raw) [a addObject:@{@"id": r[0], @"name": r[1], @"detail": r[2]}];
        list = a;
    });
    return list;
}
NSString *MRGEdgeVoice(void) { return [D() stringForKey:@"mirage.dj.edgeVoice"] ?: @"en-US-AvaMultilingualNeural"; }
void MRGEdgeSetVoice(NSString *v) { if (v.length) [D() setObject:v forKey:@"mirage.dj.edgeVoice"]; }

static NSString *xmlEscaped(NSString *s) {
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"'" withString:@"&apos;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    return m;
}

static NSString *jsDate(void) {
    NSDateFormatter *f = [NSDateFormatter new];
    f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    f.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    f.dateFormat = @"EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'";
    return [f stringFromDate:NSDate.date];
}

static NSString *hexID(void) { return [[NSUUID.UUID.UUIDString stringByReplacingOccurrencesOfString:@"-" withString:@""] lowercaseString]; }

static double sg_edgeSkew;   // server clock minus ours, learned from a refused handshake's Date header

// 0.5.1: the websocket gets its own session with a delegate, and nothing is sent until the upgrade (HTTP 101) has
// opened it. 0.5.0 sent speech.config and the SSML straight after -resume and read any receive error as a refusal,
// printing the 101 of a socket that had in fact opened; Microsoft closes a socket with code 1007 and a reason when a
// message is wrong (no speech.config first, bad SSML), and that reason is now logged.
@interface MRGEdgeSocket : NSObject <NSURLSessionWebSocketDelegate>
@property (nonatomic, copy) void (^opened)(void);
@property (nonatomic, copy) void (^closed)(NSInteger code, NSString *reason);
@property (nonatomic, copy) void (^failed)(NSError *error);   // the task ended (a handshake refused before opening)
@end
@implementation MRGEdgeSocket
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didOpenWithProtocol:(NSString *)protocol {
    void (^b)(void) = self.opened; self.opened = nil;
    if (b) b();
}
- (void)URLSession:(NSURLSession *)session webSocketTask:(NSURLSessionWebSocketTask *)task didCloseWithCode:(NSURLSessionWebSocketCloseCode)code reason:(NSData *)reason {
    void (^b)(NSInteger, NSString *) = self.closed; self.closed = nil;
    NSString *why = reason.length ? [[NSString alloc] initWithData:reason encoding:NSUTF8StringEncoding] : nil;
    if (b) b(code, why);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    void (^b)(NSError *) = self.failed; self.failed = nil;
    if (b) b(error);
}
@end

static NSString *edgeClosedText(NSInteger code, NSString *reason) {
    return [NSString stringWithFormat:@"Microsoft closed the free voice (code %ld%@%@)", (long)code, reason.length ? @": " : @"", reason ?: @""];
}

// One synthesis per connection, as Edge does: speech.config, then the SSML; binary "Path:audio" frames carry the MP3
// (a 2-byte big-endian header length, the header, the audio), "Path:turn.end" closes it.
static void edgeRun(NSString *text, NSString *voice, double speed, double pitch, double volume, int attempt, void (^done)(NSData *, NSString *)) {
    NSString *url = [NSString stringWithFormat:@"wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=%@&ConnectionId=%@&Sec-MS-GEC=%@&Sec-MS-GEC-Version=%@",
                     kEdgeToken, hexID(), MRGEdgeToken(NSDate.date.timeIntervalSince1970 + sg_edgeSkew), kEdgeVersion];
    NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    r.timeoutInterval = 15;
    [r setValue:@"no-cache" forHTTPHeaderField:@"Pragma"];
    [r setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    [r setValue:@"chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold" forHTTPHeaderField:@"Origin"];
    [r setValue:kEdgeUA forHTTPHeaderField:@"User-Agent"];
    [r setValue:@"en-US,en;q=0.9" forHTTPHeaderField:@"Accept-Language"];
    uint8_t muid[16]; arc4random_buf(muid, sizeof muid);
    NSMutableString *mu = [NSMutableString string];
    for (int i = 0; i < 16; i++) [mu appendFormat:@"%02X", muid[i]];
    [r setValue:[NSString stringWithFormat:@"muid=%@;", mu] forHTTPHeaderField:@"Cookie"];
    r.HTTPShouldHandleCookies = NO;

    MRGEdgeSocket *socket = [MRGEdgeSocket new];
    NSURLSessionConfiguration *cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    cfg.HTTPCookieStorage = nil;
    cfg.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:socket delegateQueue:NSOperationQueue.mainQueue];
    NSURLSessionWebSocketTask *task = [session webSocketTaskWithRequest:r];
    task.maximumMessageSize = 4 * 1024 * 1024;
    __block BOOL over = NO;
    __block NSInteger closeCode = 0;
    __block NSString *closeReason = nil;
    __block void (^receive)(void) = nil;   // keeps itself alive until the turn ends
    __block void (^onError)(NSError *) = nil;
    NSMutableData *audio = [NSMutableData data];
    void (^end)(NSString *) = ^(NSString *error) {
        if (over) return;
        over = YES;
        receive = nil;
        onError = nil;
        socket.opened = nil;
        socket.closed = nil;
        socket.failed = nil;
        [task cancelWithCloseCode:NSURLSessionWebSocketCloseCodeNormalClosure reason:nil];
        [session finishTasksAndInvalidate];   // breaks the session → delegate retain
        NSData *d = audio.length ? [audio copy] : nil;
        NSString *e = d ? nil : (error ?: @"Microsoft's free voice sent no audio");
        if (e) MRGDJLog(@"voice: Edge %@ (attempt %d, HTTP %ld)", e, attempt, (long)([task.response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)task.response).statusCode : 0));
        dispatch_async(dispatch_get_main_queue(), ^{ done(d, e); });
    };
    void (^retry)(NSString *) = ^(NSString *why) {
        if (over) return;
        over = YES;
        receive = nil;
        onError = nil;
        socket.opened = nil;
        socket.closed = nil;
        socket.failed = nil;
        [task cancel];
        [session finishTasksAndInvalidate];
        MRGDJLog(@"voice: Edge %@, trying once more", why);
        dispatch_async(dispatch_get_main_queue(), ^{ edgeRun(text, voice, speed, pitch, volume, attempt + 1, done); });
    };
    socket.closed = ^(NSInteger code, NSString *reason) { closeCode = code; closeReason = reason; };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!over) end(@"Microsoft's free voice timed out"); });
    onError = ^(NSError *error) {
        NSHTTPURLResponse *resp = [task.response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)task.response : nil;
        NSInteger st = resp.statusCode;
        NSInteger code = closeCode ?: task.closeCode;
        NSString *reason = closeReason ?: (task.closeReason.length ? [[NSString alloc] initWithData:task.closeReason encoding:NSUTF8StringEncoding] : nil);
        if (st == 403 && attempt == 0) {
            // Usually a clock off by minutes: the token is per 5-minute window. Once more with the server's time.
            NSString *date = resp.allHeaderFields[@"Date"];
            NSDateFormatter *f = [NSDateFormatter new];
            f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            f.dateFormat = @"EEE, dd MMM yyyy HH:mm:ss zzz";
            NSDate *server = date ? [f dateFromString:date] : nil;
            if (server) sg_edgeSkew = server.timeIntervalSince1970 - NSDate.date.timeIntervalSince1970;
            retry([NSString stringWithFormat:@"refused the handshake (HTTP 403)%@", server ? [NSString stringWithFormat:@", server clock %.0fs off", sg_edgeSkew] : @""]);
            return;
        }
        if (st == 101 || code > 0) {
            // The socket opened and Microsoft closed it: its reason says why.
            NSString *why = code > 0 ? edgeClosedText(code, reason) : [NSString stringWithFormat:@"Microsoft's free voice dropped the connection (%@ %ld)", error.domain ?: @"?", (long)error.code];
            if (attempt == 0 && !audio.length) { retry(why); return; }
            end(why);
            return;
        }
        end(st ? [NSString stringWithFormat:@"Microsoft's free voice refused the connection (HTTP %ld)%@", (long)st, st == 403 ? @"; Microsoft may have changed it" : @""]
               : [NSString stringWithFormat:@"Microsoft's free voice: %@ (%@ %ld)", error.localizedDescription ?: @"connection failed", error.domain ?: @"?", (long)error.code]);
        return;
    };
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    // The cycle is on purpose: the reader keeps itself alive until end()/retry() set it to nil.
    receive = ^{
        [task receiveMessageWithCompletionHandler:^(NSURLSessionWebSocketMessage *msg, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (over) return;
                if (error || !msg) { void (^f)(NSError *) = onError; if (f) f(error); return; }
                if (msg.type == NSURLSessionWebSocketMessageTypeString) {
                    if ([msg.string containsString:@"Path:turn.end"]) { end(nil); return; }
                } else if (msg.data.length >= 2) {
                    const uint8_t *b = msg.data.bytes;
                    NSUInteger hl = ((NSUInteger)b[0] << 8) | b[1];
                    if (2 + hl <= msg.data.length) {
                        NSString *head = [[NSString alloc] initWithData:[msg.data subdataWithRange:NSMakeRange(2, hl)] encoding:NSUTF8StringEncoding];
                        if ([head containsString:@"Path:audio"] && 2 + hl < msg.data.length)
                            [audio appendData:[msg.data subdataWithRange:NSMakeRange(2 + hl, msg.data.length - 2 - hl)]];
                    }
                }
                void (^next)(void) = receive;
                if (next) next();
            });
        }];
    };
#pragma clang diagnostic pop
    NSString *config = [NSString stringWithFormat:@"X-Timestamp:%@\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n"
        @"{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{\"sentenceBoundaryEnabled\":\"false\",\"wordBoundaryEnabled\":\"false\"},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n", jsDate()];
    long rate = lround((MIN(1.5, MAX(0.6, speed)) - 1.0) * 100.0);
    long pct = lround((MIN(1.5, MAX(0.75, pitch)) - 1.0) * 100.0);
    long vol = lround((MIN(1.0, MAX(0.3, volume)) - 1.0) * 100.0);
    // Prosody only: Microsoft's free endpoint refuses mstts:express-as styles and <break> ("SSML is invalid", tested).
    NSString *ssml = [NSString stringWithFormat:@"<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'><voice name='%@'><prosody pitch='%+ld%%' rate='%+ld%%' volume='%+ld%%'>%@</prosody></voice></speak>",
                      voice, pct, rate, vol, xmlEscaped(text)];
    NSString *say = [NSString stringWithFormat:@"X-RequestId:%@\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:%@Z\r\nPath:ssml\r\n\r\n%@", hexID(), jsDate(), ssml];
    socket.opened = ^{
        if (over) return;
        if (receive) receive();
        [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:config] completionHandler:^(NSError *e1) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (over) return;
                if (e1) { end([@"Microsoft's free voice: " stringByAppendingString:e1.localizedDescription ?: @"send failed"]); return; }
                [task sendMessage:[[NSURLSessionWebSocketMessage alloc] initWithString:say] completionHandler:^(NSError *e2) {
                    if (e2) dispatch_async(dispatch_get_main_queue(), ^{ end([@"Microsoft's free voice: " stringByAppendingString:e2.localizedDescription ?: @"send failed"]); });
                }];
            });
        }];
    };
    [task resume];
    // A handshake that fails never opens; the task's completion reports it (403, no network).
    socket.failed = ^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (over) return; void (^f)(NSError *) = onError; if (f) f(error); });
    };
}

void MRGEdgeSpeech(NSString *text, NSString *voice, double speed, double pitch, void (^done)(NSData *, NSString *)) {
    if (!text.length) { done(nil, @"Nothing to say"); return; }
    id v = [NSUserDefaults.standardUserDefaults objectForKey:@"mirage.dj.edgeVolume"];
    double volume = [v isKindOfClass:NSNumber.class] ? [v doubleValue] : 1.0;
    @try { edgeRun(text, voice.length ? voice : MRGEdgeVoice(), speed, pitch, volume, 0, done); }
    @catch (NSException *e) { done(nil, [NSString stringWithFormat:@"Microsoft's free voice: %@", e.reason ?: @"failed"]); }
}
