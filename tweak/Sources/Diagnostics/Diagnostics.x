// Screen dumps for FLEX builds. The tree of the visible screen is served over HTTP on the phone's
// loopback (fetched from the Mac through `iproxy` over USB), and also logged when the app goes to
// the background or the full player appears.
#import "Core/SGCore.h"
#import "Diagnostics.h"
#import <sys/socket.h>
#import <ifaddrs.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <unistd.h>

// harness/driver builds the server on another port, so it leaves a tunnel to the phone on 8085 alone.
#ifndef SG_TREE_PORT
#define SG_TREE_PORT 8085
#endif
static const uint16_t kTreePort = SG_TREE_PORT;

static NSString *hexColor(CGColorRef color) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [[UIColor colorWithCGColor:color] getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"#%02X%02X%02X@%.2f", (int)(r * 255), (int)(g * 255), (int)(b * 255), a];
}

static void appendTree(UIView *view, NSUInteger depth, NSMutableString *out) {
    NSMutableString *line = [NSMutableString stringWithFormat:@"%*s%@ %@", (int)depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    CGColorRef bg = view.layer.backgroundColor;
    if (bg && CGColorGetAlpha(bg) > 0) [line appendFormat:@" bg=%@", hexColor(bg)];
    if (view.layer.cornerRadius > 0) [line appendFormat:@" r=%.1f", view.layer.cornerRadius];
    if (view.alpha < 1) [line appendFormat:@" a=%.2f", view.alpha];
    if (view.hidden) [line appendString:@" hidden"];
    if (view.layer.mask) [line appendString:@" masked"];
    if (view.clipsToBounds) [line appendString:@" clips"];
    // What draws black without a background colour: an opaque layer with no fill, a layer's own opacity, filters and
    // a picture in the layer itself, and sublayers that are not views (their fill, their picture, a gradient). Not
    // view.opaque, which is YES on nearly every view.
    if (view.layer.opaque) [line appendString:@" opaque"];
    if (view.layer.opacity < 1) [line appendFormat:@" op=%.2f", view.layer.opacity];
    if (view.layer.filters.count) [line appendFormat:@" filters=%lu", (unsigned long)view.layer.filters.count];
    if (view.layer.compositingFilter) [line appendFormat:@" comp=%@", view.layer.compositingFilter];
    if (view.layer.contents && ![view isKindOfClass:UIImageView.class]) [line appendString:@" contents"];
    if (view.layer.shouldRasterize) [line appendString:@" raster"];
    if (![NSStringFromClass(view.layer.class) isEqualToString:@"CALayer"]) [line appendFormat:@" layer=%@", NSStringFromClass(view.layer.class)];
    NSMutableArray<NSString *> *loose = [NSMutableArray array];
    NSSet<CALayer *> *viewLayers = [NSSet setWithArray:[view.subviews valueForKey:@"layer"]];
    for (CALayer *sub in view.layer.sublayers) {
        if ([viewLayers containsObject:sub]) continue;
        NSMutableString *desc = [NSMutableString stringWithString:NSStringFromClass(sub.class)];
        if (sub.backgroundColor && CGColorGetAlpha(sub.backgroundColor) > 0) [desc appendFormat:@" bg=%@", hexColor(sub.backgroundColor)];
        if (sub.contents) [desc appendString:@" contents"];
        if ([sub isKindOfClass:CAGradientLayer.class] && ((CAGradientLayer *)sub).colors.count) [desc appendString:@" gradient"];
        if (sub.hidden) [desc appendString:@" hidden"];
        if (sub.opacity < 1) [desc appendFormat:@" op=%.2f", sub.opacity];
        [desc appendFormat:@" %@", NSStringFromCGRect(sub.frame)];
        [loose addObject:desc];
    }
    if (loose.count) [line appendFormat:@" sublayers=[%@]", [loose componentsJoinedByString:@"; "]];
    if (view.accessibilityIdentifier.length) [line appendFormat:@" id=%@", view.accessibilityIdentifier];
    // Controls and accessibility elements, the views the phone driver's `tap --label` finds.
    if (([view isKindOfClass:UIControl.class] || (view.isAccessibilityElement && ![view isKindOfClass:UILabel.class])) && view.accessibilityLabel.length) {
        [line appendFormat:@" a11y=\"%@\"", view.accessibilityLabel];
    }
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        [line appendFormat:@" \"%@\" %.0fpt %@", label.text, label.font.pointSize, hexColor(label.textColor.CGColor)];
    }
    if ([view isKindOfClass:UIImageView.class] && ((UIImageView *)view).image) {
        CGSize size = ((UIImageView *)view).image.size;
        [line appendFormat:@" img=%.0fx%.0f", size.width, size.height];
    }
    [out appendString:line];
    [out appendString:@"\n"];
    for (UIView *sub in view.subviews) appendTree(sub, depth + 1, out);
}

BOOL SGIsDebugBuild(void) {
    return NSClassFromString(@"FLEXManager") != nil;
}

// What the mod has set, so a recorded tree says whether it shows Spotify as it came or a screen some
// switch has already changed: the stock marker Reset all settings leaves, then every key of the mod's
// with its value. The counters, the update check, the signing warning, the tour and the Musixmatch
// token belong to the install rather than to a choice, as in About/Backup.m, and are left out.
// scripts/record-session.py reads this section to call a snapshot clean or not.
static NSString *describeValue(id value) {
    if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSDictionary.class]) {
        return [NSString stringWithFormat:@"%@%lu", [value isKindOfClass:NSArray.class] ? @"list:" : @"map:", (unsigned long)[value count]];
    }
    if ([value isKindOfClass:NSString.class]) {
        NSString *text = value;
        return [NSString stringWithFormat:@"\"%@\"", text.length > 40 ? [[text substringToIndex:40] stringByAppendingString:@"…"] : text];
    }
    return [value description];
}

static void appendModState(NSMutableString *out) {
    NSDictionary *stored = [NSUserDefaults.standardUserDefaults persistentDomainForName:NSBundle.mainBundle.bundleIdentifier] ?: @{};
    [out appendFormat:@"== mod\nstock %@\n", [stored[SGKeyStock] boolValue] ? @"yes" : @"no"];
    NSArray<NSString *> *local = @[@"spotifyglass.adblock.counts", @"spotifyglass.privacy.counts", @"spotifyglass.update.",
                                   @"spotifyglass.signing.", @"spotifyglass.onboarding.", @"spotifyglass.navbar.stock", @"spotifyglass.redesign.navbar.stock",
                                   @"spotifyglass.musixmatch.token"];
    for (NSString *key in [stored.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![key hasPrefix:@"spotifyglass."] || [key isEqualToString:SGKeyStock]) continue;
        BOOL skip = NO;
        for (NSString *prefix in local) skip |= [key hasPrefix:prefix];
        if (!skip) [out appendFormat:@"%@ = %@\n", key, describeValue(stored[key])];
    }
}

NSString *SGScreenTree(void) {
    NSMutableString *out = [NSMutableString string];
    UIViewController *root = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || [NSStringFromClass(window.class) containsString:@"FLEX"]) continue;
            if (!root || window.isKeyWindow) root = window.rootViewController;
            [out appendFormat:@"== window %@ level %.0f\n", window.class, window.windowLevel];
            appendTree(window, 0, out);
        }
    }
    if ([root respondsToSelector:@selector(_printHierarchy)]) {
        [out appendFormat:@"== view controllers\n%@\n", [root _printHierarchy]];
    }
    appendModState(out);
    return out;
}

void SGDumpScreen(NSString *reason) {
    SGLogLong([@"screen dump " stringByAppendingString:reason], SGScreenTree());
}

BOOL SGRunOnMain(NSTimeInterval timeout, dispatch_block_t block) {
    if (NSThread.isMainThread) {
        block();
        return YES;
    }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        block();
        dispatch_semaphore_signal(done);
    });
    return dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC))) == 0;
}

// The server: GET /tree (or any path that is not a driver command) answers with the current screen's
// tree as text/plain; in a build with the phone driver, GET /<command>?<params> runs that command and
// answers JSON (Driver.m). It listens on 127.0.0.1 only, the phone's loopback, which the Mac reaches
// through usbmux (iproxy) over the cable and nothing on Wi-Fi reaches, and it starts only in FLEX builds.
static void sendAll(int client, NSData *data) {
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    while (left > 0) {
        ssize_t n = send(client, p, left, 0);
        if (n <= 0) return;
        p += n;
        left -= (size_t)n;
    }
}

static void respond(int client, NSString *status, NSString *type, NSData *data) {
    NSString *head = [NSString stringWithFormat:@"HTTP/1.0 %@\r\nContent-Type: %@; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
                                                status, type, (unsigned long)data.length];
    sendAll(client, [head dataUsingEncoding:NSUTF8StringEncoding]);
    sendAll(client, data);
}

// The request line and headers, up to the blank line that ends them; a GET has no body.
static NSString *readRequest(int client) {
    NSMutableData *request = [NSMutableData data];
    char buffer[4096];
    while (request.length < 64 * 1024) {
        ssize_t n = recv(client, buffer, sizeof(buffer), 0);
        if (n <= 0) break;
        [request appendBytes:buffer length:(NSUInteger)n];
        if ([request rangeOfData:[@"\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding] options:0 range:NSMakeRange(0, request.length)].location != NSNotFound) break;
    }
    return [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] ?: @"";
}

#if SG_DRIVER
static NSString *driverToken(void);
#endif

// `tailnet`: the client came in on the Tailscale listener, which answers nothing without the token.
static void serve(int client, BOOL tailnet) {
    struct timeval timeout = {2, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    int no = 1;
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &no, sizeof(no));
#if !SG_DRIVER
    readRequest(client);
#else
    NSString *request = readRequest(client);
    if (tailnet) {
        NSString *token = [NSString stringWithFormat:@"\r\nX-Phone-Token: %@\r\n", driverToken()];
        if ([request rangeOfString:token options:NSCaseInsensitiveSearch].location == NSNotFound) {
            respond(client, @"403 Forbidden", @"application/json", [@"{\"ok\":false,\"error\":\"the tailnet listener needs the X-Phone-Token header\"}" dataUsingEncoding:NSUTF8StringEncoding]);
            close(client);
            return;
        }
    }
    NSArray<NSString *> *first = [[request componentsSeparatedByString:@"\r\n"].firstObject componentsSeparatedByString:@" "];
    NSURLComponents *url = first.count > 1 ? [NSURLComponents componentsWithString:[@"http://phone" stringByAppendingString:first[1]]] : nil;
    NSString *command = [url.path stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] ?: @"";
    if (SGDriverHandles(command)) {
        // The phone's loopback is every app's on the phone, Safari's pages included. A page can send a GET
        // anywhere but cannot add a header of its own without a CORS preflight, which this server never
        // allows, so a command needs the header scripts/phone.py sends.
        if ([request rangeOfString:@"\r\nX-Phone-Driver:" options:NSCaseInsensitiveSearch].location == NSNotFound) {
            respond(client, @"403 Forbidden", @"application/json", [@"{\"ok\":false,\"error\":\"a driver command needs the X-Phone-Driver header\"}" dataUsingEncoding:NSUTF8StringEncoding]);
            close(client);
            return;
        }
        NSMutableDictionary<NSString *, NSString *> *params = [NSMutableDictionary dictionary];
        for (NSURLQueryItem *item in url.queryItems) params[item.name] = item.value ?: @"1";
        // One command at a time, so two clients' touches never interleave; the tree is served alongside.
        static dispatch_queue_t commands;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ commands = dispatch_queue_create("spotifyglass.driver", DISPATCH_QUEUE_SERIAL); });
        __block NSData *answer = nil;
        dispatch_sync(commands, ^{ answer = SGDriverRun(command, params); });
        respond(client, @"200 OK", @"application/json", answer);
        close(client);
        return;
    }
#endif
    __block NSString *body = nil;
    if (!SGRunOnMain(5, ^{ body = SGScreenTree(); })) {
        respond(client, @"503 Service Unavailable", @"text/plain", [@"the main thread did not answer in 5 s\n" dataUsingEncoding:NSUTF8StringEncoding]);
    } else {
        respond(client, @"200 OK", @"text/plain", [body dataUsingEncoding:NSUTF8StringEncoding]);
    }
    close(client);
}

// Listens on `address` (network order) and serves each client on a thread of its own: a command may wait
// seconds (wait, longpress). Answers the listening socket, -1 when it could not listen.
static int listenOn(in_addr_t address, BOOL tailnet, dispatch_source_t __strong *source) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(kTreePort);
    addr.sin_addr.s_addr = address;
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0 || listen(fd, 4) != 0) {
        close(fd);
        return -1;
    }
    *source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(*source, ^{
        int client = accept(fd, NULL, NULL);
        if (client < 0) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ serve(client, tailnet); });
    });
    dispatch_source_set_cancel_handler(*source, ^{ close(fd); });
    dispatch_resume(*source);
    return fd;
}

#if SG_DRIVER
// The tailnet listener: the user asked to drive the app from their Mac over Tailscale. It binds the phone's
// exact Tailscale address (a utun interface in 100.64.0.0/10), never every interface and never Wi-Fi or
// cellular, so only the user's own tailnet reaches it, and every request on it needs the token, made once and
// kept in the app's defaults, which the log prints at launch for scripts/phone.py.
static NSString *driverToken(void) {
    static NSString *token;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *const key = @"spotifyglass.driver.token";
        token = [NSUserDefaults.standardUserDefaults stringForKey:key];
        if (token.length < 32) {
            uint8_t bytes[16];
            arc4random_buf(bytes, sizeof(bytes));   // cryptographically random on Darwin
            NSMutableString *hex = [NSMutableString string];
            for (size_t i = 0; i < sizeof(bytes); i++) [hex appendFormat:@"%02x", bytes[i]];
            token = hex;
            [NSUserDefaults.standardUserDefaults setObject:token forKey:key];
        }
    });
    return token;
}

static in_addr_t tailnetAddress(void) {
    struct ifaddrs *list = NULL;
    in_addr_t found = 0;
    if (getifaddrs(&list) != 0) return 0;
    for (struct ifaddrs *i = list; i && !found; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_INET || strncmp(i->ifa_name, "utun", 4) != 0) continue;
        in_addr_t address = ((struct sockaddr_in *)i->ifa_addr)->sin_addr.s_addr;
        if ((ntohl(address) & 0xFFC00000) == 0x64400000) found = address;   // 100.64.0.0/10
    }
    freeifaddrs(list);
    return found;
}

// The VPN can come up, go away or change address after launch: looked at again every 10 s.
static void watchTailnet(void) {
    static dispatch_source_t timer, source;
    static in_addr_t bound;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{
        in_addr_t address = tailnetAddress();
        if (address == bound) return;
        if (source) {
            dispatch_source_cancel(source);
            source = nil;
        }
        bound = 0;
        char text[INET_ADDRSTRLEN] = "";
        inet_ntop(AF_INET, &address, text, sizeof(text));
        if (!address) {
            SGLog(@"driver: no Tailscale address, the tailnet listener is off");
            return;
        }
        if (listenOn(address, YES, &source) < 0) {
            SGLog(@"driver: could not listen on %s:%u", text, kTreePort);
            return;
        }
        bound = address;
        SGLog(@"driver: tailnet listener on %s:%u, token %@", text, kTreePort, driverToken());
    });
    dispatch_resume(timer);
}
#endif

static void startTreeServer(void) {
    static dispatch_source_t source;
    if (listenOn(htonl(INADDR_LOOPBACK), NO, &source) < 0) {   // loopback, which only the cable's iproxy reaches
        SGLog(@"tree server: could not listen on %u", kTreePort);
        return;
    }
    SGLog(@"tree server on 127.0.0.1:%u; on the Mac: iproxy %u:%u, then GET http://127.0.0.1:%u/tree%@", kTreePort, kTreePort, kTreePort, kTreePort,
          SG_DRIVER ? @", or drive the app with scripts/phone.py" : @"");
#if SG_DRIVER
    watchTailnet();
#endif
}

%hook _TtC21NowPlaying_ScrollImpl23NPVScrollViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    if (!SGIsDebugBuild()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            SGDumpScreen(@"now playing view");
        });
    });
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC21NowPlaying_ScrollImpl23NPVScrollViewController"]);
    SGLog(@"loaded, UIGlassEffect %@", NSClassFromString(@"UIGlassEffect") ? @"available" : @"missing");
    if (SGIsDebugBuild()) {
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            SGDumpScreen(@"on background");
        }];
        startTreeServer();
        SGLog(@"debug build: backgrounding the app dumps the visible screen's view tree");
    }
}
