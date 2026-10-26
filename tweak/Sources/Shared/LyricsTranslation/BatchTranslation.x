#import <dlfcn.h>
#import <objc/message.h>
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/LyricsSources/LyricsSources.h"
#import "Shared/AlbumQueue/AlbumQueue.h"
#import "Settings/SGPageStyle.h"
#import "LyricsTranslation.h"
#import "BatchTranslation.h"

@interface SGEntityPage : NSObject
+ (NSString *)entityURI:(id)controller;
+ (NSString *)playlistURI:(id)controller;
@end

@interface SGBatchCandidateSong : NSObject
@property (nonatomic, copy) NSString *trackID;
@property (nonatomic, copy) NSString *trackURI;
@property (nonatomic, strong) NSArray<SGKaraokeLine *> *lines;
@property (nonatomic, strong) NSArray<NSString *> *texts;
@end
@implementation SGBatchCandidateSong
@end

static char kURIKey, kRowKey, kSeenKey;
static NSString *sg_pendingURI;
static CFTimeInterval sg_markedAt;
static BOOL sg_translating;

static UIWindow *normalAppWindow(UIWindow *preferred) {
    if (preferred && !preferred.hidden && preferred.windowLevel == UIWindowLevelNormal &&
        ![NSStringFromClass(preferred.class) isEqualToString:@"SGRSheetWindow"]) {
        return preferred;
    }
    for (UIWindow *w in preferred.windowScene.windows) {
        if (!w.hidden && w.windowLevel == UIWindowLevelNormal &&
            ![NSStringFromClass(w.class) isEqualToString:@"SGRSheetWindow"]) {
            return w;
        }
    }
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive &&
            scene.activationState != UISceneActivationStateForegroundInactive) continue;
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (!w.hidden && w.windowLevel == UIWindowLevelNormal &&
                ![NSStringFromClass(w.class) isEqualToString:@"SGRSheetWindow"]) {
                return w;
            }
        }
    }
    return preferred;
}

static NSString *SGExtractEntityURI(id object) {
    if (!object || [object isKindOfClass:UIView.class]) return nil;
    Class entityPage = NSClassFromString(@"SGEntityPage");
    if (entityPage && [entityPage respondsToSelector:@selector(entityURI:)]) {
        NSString *str = [entityPage performSelector:@selector(entityURI:) withObject:object];
        NSString *clean = SGSanitizeEntityURI(str);
        if (clean) return clean;
    }
    for (NSString *name in @[@"pageURI", @"playlistURI", @"playlistURL", @"entityURI", @"uri"]) {
        SEL sel = NSSelectorFromString(name);
        if ([object respondsToSelector:sel]) {
            id val = ((id (*)(id, SEL))objc_msgSend)(object, sel);
            NSString *str = [val isKindOfClass:NSURL.class] ? ((NSURL *)val).absoluteString : ([val isKindOfClass:NSString.class] ? (NSString *)val : nil);
            NSString *clean = SGSanitizeEntityURI(str);
            if (clean) return clean;
        }
    }
    return nil;
}

static NSString *SGResolveEntityURIForView(UIView *view) {
    for (UIResponder *r = view; r; r = r.nextResponder) {
        if (![r isKindOfClass:UIViewController.class]) continue;
        UIViewController *vc = (UIViewController *)r;
        NSString *uri = SGExtractEntityURI(vc);
        if (uri) return uri;
        if (vc.parentViewController) {
            uri = SGExtractEntityURI(vc.parentViewController);
            if (uri) return uri;
        }
    }
    return nil;
}

void SGBatchTranslationMarkSource(UIView *view) {
    NSString *resolved = SGResolveEntityURIForView(view);
    if (!SGIsValidEntityURI(resolved)) {
        sg_pendingURI = nil;
        return;
    }
    NSString *entityID = [resolved componentsSeparatedByString:@":"].lastObject;
    NSString *expectedIdent = entityID.length ? [SGAlbumQueueButtonPrefix stringByAppendingString:entityID] : nil;
    BOOL isEntitySource = ![view isKindOfClass:UIControl.class];
    if (!isEntitySource && expectedIdent && [view.accessibilityIdentifier isEqualToString:expectedIdent]) {
        isEntitySource = YES;
    }
    if (!isEntitySource) {
        BOOL inCell = NO, inHeader = NO;
        for (UIView *v = view; v; v = v.superview) {
            if ([v isKindOfClass:UITableViewCell.class] || [v isKindOfClass:UICollectionViewCell.class]) {
                inCell = YES;
                break;
            }
            if ([v.accessibilityIdentifier isEqualToString:@"CreativeWorkPlatform.Header"] ||
                [v.accessibilityIdentifier isEqualToString:@"PL.Header"]) {
                inHeader = YES;
                break;
            }
        }
        if (inHeader && !inCell) isEntitySource = YES;
    }
    if (isEntitySource) {
        sg_pendingURI = resolved;
        sg_markedAt = CACurrentMediaTime();
    } else {
        sg_pendingURI = nil;
    }
}

BOOL SGBatchTranslationIsRunning(void) {
    return sg_translating;
}

static NSArray<NSString *> *textsOfLines(NSArray<SGKaraokeLine *> *lines) {
    NSMutableArray *texts = [NSMutableArray arrayWithCapacity:lines.count];
    for (SGKaraokeLine *line in lines) {
        NSString *text = SGKaraokeLineText(line);
        [texts addObject:text ?: @""];
    }
    return texts;
}

#pragma mark - Track resolution

static void resolveTracks(NSString *uri, void (^completion)(NSArray<NSString *> *trackIDs, NSString *error)) {
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        if (!headers) {
            completion(nil, @"Spotify is not ready");
            return;
        }
        NSMutableArray<NSString *> *collected = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        __block void (^fetchPage)(NSString *);
        fetchPage = ^(NSString *address) {
            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
            req.timeoutInterval = 15;
            req.allHTTPHeaderFields = headers;
            [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
            [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
                NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
                id json = (status == 200 && data.length) ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                if (![json isKindOfClass:NSDictionary.class]) {
                    fetchPage = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil, @"Could not load songs");
                    });
                    return;
                }
                id pages = json[@"pages"];
                NSString *nextURL = nil;
                if ([pages isKindOfClass:NSArray.class]) {
                    for (id page in pages) {
                        if (![page isKindOfClass:NSDictionary.class]) continue;
                        id next = page[@"next_page_url"];
                        if ([next isKindOfClass:NSString.class] && [next length]) nextURL = next;
                        id tracks = page[@"tracks"];
                        if (![tracks isKindOfClass:NSArray.class]) continue;
                        for (id entry in tracks) {
                            if (![entry isKindOfClass:NSDictionary.class]) continue;
                            NSString *tURI = entry[@"uri"];
                            if ([tURI hasPrefix:@"spotify:track:"]) {
                                NSString *tID = [tURI substringFromIndex:@"spotify:track:".length];
                                if (tID.length == 22 && ![seen containsObject:tID]) {
                                    [seen addObject:tID];
                                    [collected addObject:tID];
                                }
                            }
                        }
                    }
                }
                if (nextURL) {
                    fetchPage(nextURL);
                } else {
                    fetchPage = nil;
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(collected, nil);
                    });
                }
            }] resume];
        };
        fetchPage([@"https://spclient.wg.spotify.com/context-resolve/v1/" stringByAppendingString:uri]);
    });
}

#pragma mark - Lyrics fetching for candidates

static void fetchSpotifyColorLyrics(NSString *trackID, NSDictionary<NSString *, NSString *> *headers,
                                    void (^completion)(NSArray<SGKaraokeLine *> *lines)) {
    if (!headers) {
        completion(nil);
        return;
    }
    NSString *address = [NSString stringWithFormat:@"https://spclient.wg.spotify.com/color-lyrics/v2/track/%@?format=json&vocalRemoval=false&market=from_token", trackID];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:address]];
    req.allHTTPHeaderFields = headers;
    [req setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [NSURLProtocol setProperty:@YES forKey:SGLyricsOwnRequestKey inRequest:req];
    [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData *body, NSURLResponse *response, NSError *error) {
        completion(SGKaraokeLinesFromBody(body));
    }] resume];
}

static void fetchLyricsForTrack(NSString *trackID, NSDictionary<NSString *, NSString *> *headers,
                                void (^completion)(NSArray<SGKaraokeLine *> *lines)) {
    NSArray *cached = SGKaraokeLinesForTrack(trackID);
    if (cached.count) {
        completion(cached);
        return;
    }
    if (SGLyricsEnabled()) {
        SGLyricsFetch(trackID, ^(SGLyricsResult *result) {
            NSArray<SGKaraokeLine *> *providerLines = result.karaokeLines;
            if (providerLines.count && SGKaraokeLinesTiming(providerLines) != SGKaraokeTimingNone) {
                SGKaraokeKeepLines(trackID, providerLines);
                if (result.provider) SGLyricsSetCredit(trackID, result.provider);
                completion(providerLines);
                return;
            }
            fetchSpotifyColorLyrics(trackID, headers, ^(NSArray<SGKaraokeLine *> *spotifyLines) {
                if (spotifyLines.count && SGKaraokeLinesTiming(spotifyLines) != SGKaraokeTimingNone) {
                    SGKaraokeKeepLines(trackID, spotifyLines);
                    completion(spotifyLines);
                } else if (providerLines.count) {
                    SGKaraokeKeepLines(trackID, providerLines);
                    if (result.provider) SGLyricsSetCredit(trackID, result.provider);
                    completion(providerLines);
                } else if (spotifyLines.count) {
                    SGKaraokeKeepLines(trackID, spotifyLines);
                    completion(spotifyLines);
                } else {
                    completion(nil);
                }
            });
        });
        return;
    }
    fetchSpotifyColorLyrics(trackID, headers, ^(NSArray<SGKaraokeLine *> *spotifyLines) {
        if (spotifyLines.count) SGKaraokeKeepLines(trackID, spotifyLines);
        completion(spotifyLines);
    });
}

static void filterCandidateSongs(NSArray<NSString *> *trackIDs, NSString *targetLang,
                                 void (^completion)(NSArray<SGBatchCandidateSong *> *candidates, NSUInteger savedCount, NSUInteger sameLangCount)) {
    BOOL skipSaved = SGLyricsBatchSkipSaved();
    BOOL translateAny = SGHidden(SGKeyLyricsTranslateEverySong);
    SGSpclientHeaders(^(NSDictionary<NSString *, NSString *> *headers) {
        NSMutableArray<SGBatchCandidateSong *> *candidates = [NSMutableArray array];
        __block NSUInteger savedCount = 0;
        __block NSUInteger sameLangCount = 0;
        dispatch_group_t group = dispatch_group_create();
        for (NSString *trackID in trackIDs) {
            if (skipSaved && SGLyricsHasSavedTranslation(trackID, targetLang)) {
                savedCount++;
                continue;
            }
            dispatch_group_enter(group);
            fetchLyricsForTrack(trackID, headers, ^(NSArray<SGKaraokeLine *> *lines) {
                if (lines.count) {
                    BOOL hasActualWords = NO;
                    for (SGKaraokeLine *l in lines) {
                        NSString *t = SGKaraokeLineText(l);
                        if (t.length && ![t isEqualToString:@"♪"]) { hasActualWords = YES; break; }
                    }
                    if (hasActualWords) {
                        if (translateAny || SGKaraokeInAnotherLanguage(lines, targetLang)) {
                            SGBatchCandidateSong *song = [SGBatchCandidateSong new];
                            song.trackID = trackID;
                            song.trackURI = [@"spotify:track:" stringByAppendingString:trackID];
                            song.lines = lines;
                            song.texts = textsOfLines(lines);
                            @synchronized (candidates) {
                                [candidates addObject:song];
                            }
                        } else {
                            @synchronized (candidates) {
                                sameLangCount++;
                            }
                        }
                    }
                }
                dispatch_group_leave(group);
            });
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            completion(candidates, savedCount, sameLangCount);
        });
    });
}

#pragma mark - Batch translation execution

void SGBatchTranslateURI(NSString *uri, SGBatchTranslationEngine engine, UIWindow *window) {
    window = normalAppWindow(window);
    if (sg_translating) {
        [SGAlbumQueueNotice showIn:window title:@"Already Translating" detail:@"Wait for this batch" symbol:@"exclamationmark.circle" persistent:NO];
        return;
    }
    sg_translating = YES;
    BOOL isAlbum = SGAlbumQueueIsAlbumURI(uri);
    NSString *entityName = isAlbum ? @"Album" : @"Playlist";
    NSString *targetLang = SGLyricsTranslationTarget();

    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:@"Resolving songs…" symbol:@"translate" persistent:YES];

    resolveTracks(uri, ^(NSArray<NSString *> *trackIDs, NSString *resolveError) {
        if (resolveError || !trackIDs.count) {
            sg_translating = NO;
            [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Could Not Load %@", entityName] detail:resolveError ?: @"No songs found" symbol:@"exclamationmark.circle" persistent:NO];
            return;
        }
        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:@"Checking lyrics…" symbol:@"translate" persistent:YES];
        filterCandidateSongs(trackIDs, targetLang, ^(NSArray<SGBatchCandidateSong *> *candidates, NSUInteger savedCount, NSUInteger sameLangCount) {
            if (!candidates.count) {
                sg_translating = NO;
                if (savedCount > 0 && sameLangCount == 0) {
                    NSString *detail = savedCount == 1 ? @"1 song saved" : [NSString stringWithFormat:@"%lu songs saved", (unsigned long)savedCount];
                    [SGAlbumQueueNotice showIn:window title:@"Already Translated" detail:detail symbol:@"checkmark.circle" persistent:NO];
                } else if (sameLangCount > 0 && savedCount == 0) {
                    [SGAlbumQueueNotice showIn:window title:@"Already in Your Language" detail:nil symbol:@"checkmark.circle" persistent:NO];
                } else if (savedCount > 0) {
                    [SGAlbumQueueNotice showIn:window title:@"Already Translated" detail:nil symbol:@"checkmark.circle" persistent:NO];
                } else {
                    [SGAlbumQueueNotice showIn:window title:@"No Lyrics Found" detail:nil symbol:@"exclamationmark.circle" persistent:NO];
                }
                return;
            }
            NSUInteger total = candidates.count;
            __block NSUInteger completed = 0;

            if (engine == SGBatchTranslationEngineAI) {
                NSUInteger batchSize = SGLyricsBatchSize();
                if (batchSize == 0) batchSize = total;

                NSMutableArray<NSArray<SGBatchCandidateSong *> *> *chunks = [NSMutableArray array];
                for (NSUInteger i = 0; i < total; i += batchSize) {
                    NSUInteger len = MIN(batchSize, total - i);
                    [chunks addObject:[candidates subarrayWithRange:NSMakeRange(i, len)]];
                }

                NSMutableSet<NSString *> *savedTrackIDs = [NSMutableSet set];
                SGTranslationSource *source = SGAITranslatorSource();
                NSString *providerName = SGAITranslatorName() ?: @"AI";
                NSString *translatingTitle = [NSString stringWithFormat:@"Translating %@", entityName];

                void (^saveSongTranslation)(SGBatchCandidateSong *, NSArray<NSString *> *) = ^(SGBatchCandidateSong *song, NSArray<NSString *> *trans) {
                    if (!song || trans.count != song.lines.count || [savedTrackIDs containsObject:song.trackID]) return;
                    for (NSUInteger idx = 0; idx < song.lines.count; idx++) {
                        SGKaraokeLine *line = song.lines[idx];
                        NSString *t = trans[idx];
                        if (t.length) {
                            line.translation = t;
                            line.translationMade = YES;
                        }
                    }
                    SGLyricsSaveTranslation(song.trackID, targetLang, song.lines, source);
                    [savedTrackIDs addObject:song.trackID];
                    completed++;
                };

                __block void (^processChunk)(NSUInteger);
                processChunk = ^(NSUInteger chunkIndex) {
                    if (chunkIndex >= chunks.count) {
                        processChunk = nil;
                        sg_translating = NO;
                        NSString *detail = completed == 1 ? @"1 song saved" : [NSString stringWithFormat:@"%lu songs saved", (unsigned long)completed];
                        [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"%@ Translated", entityName] detail:detail symbol:@"checkmark.circle" persistent:NO];
                        [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                        return;
                    }
                    NSArray<SGBatchCandidateSong *> *chunk = chunks[chunkIndex];
                    NSMutableDictionary<NSString *, NSArray<NSString *> *> *songsMap = [NSMutableDictionary dictionary];
                    NSMutableDictionary<NSString *, SGBatchCandidateSong *> *lookup = [NSMutableDictionary dictionary];
                    for (SGBatchCandidateSong *song in chunk) {
                        songsMap[song.trackURI] = song.texts;
                        lookup[song.trackURI] = song;
                        lookup[song.trackID] = song;
                    }
                    NSString *askDetail = completed > 0
                        ? [NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)completed, (unsigned long)total]
                        : [NSString stringWithFormat:@"Asking %@…", providerName];
                    [SGAlbumQueueNotice showIn:window title:translatingTitle detail:askDetail symbol:@"sparkles" persistent:YES];

                    SGLyricsTranslateBatchWithAI(songsMap, targetLang, ^(NSString *phase) {
                        if (!sg_translating) return;
                        if ([phase isEqualToString:@"Thinking…"]) {
                            NSString *thinkDetail = completed > 0
                                ? [NSString stringWithFormat:@"Thinking • %lu/%lu…", (unsigned long)completed, (unsigned long)total]
                                : @"Thinking…";
                            [SGAlbumQueueNotice showIn:window title:translatingTitle detail:thinkDetail symbol:@"sparkles" persistent:YES];
                        } else if ([phase isEqualToString:@"Writing"]) {
                            NSString *writeDetail = [NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)MIN(completed + 1, total), (unsigned long)total];
                            [SGAlbumQueueNotice showIn:window title:translatingTitle detail:writeDetail symbol:@"sparkles" persistent:YES];
                        }
                    }, ^(NSString *trackKey, NSArray<NSString *> *lines) {
                        if (!sg_translating) return;
                        SGBatchCandidateSong *song = lookup[trackKey];
                        if (!song) {
                            for (SGBatchCandidateSong *c in chunk) {
                                if ([c.trackURI caseInsensitiveCompare:trackKey] == NSOrderedSame ||
                                    [c.trackID caseInsensitiveCompare:trackKey] == NSOrderedSame) {
                                    song = c;
                                    break;
                                }
                            }
                        }
                        if (song && lines.count == song.lines.count && ![savedTrackIDs containsObject:song.trackID]) {
                            saveSongTranslation(song, lines);
                            NSString *progressDetail = [NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)MIN(completed + 1, total), (unsigned long)total];
                            [SGAlbumQueueNotice showIn:window title:translatingTitle detail:progressDetail symbol:@"sparkles" persistent:YES];
                        }
                    }, ^(NSDictionary<NSString *, NSArray<NSString *> *> *results, NSString *error) {
                        if (results.count) {
                            for (SGBatchCandidateSong *song in chunk) {
                                NSArray<NSString *> *trans = results[song.trackURI] ?: results[song.trackID];
                                if (trans.count == song.lines.count) {
                                    saveSongTranslation(song, trans);
                                }
                            }
                        }
                        if (error || !results.count) {
                            processChunk = nil;
                            sg_translating = NO;
                            NSString *title = completed > 0
                                ? [NSString stringWithFormat:@"Translated %lu of %lu", (unsigned long)completed, (unsigned long)total]
                                : @"Translation Failed";
                            NSString *detail = error ?: @"Could not read reply";
                            [SGAlbumQueueNotice showIn:window title:title detail:detail symbol:@"exclamationmark.circle" persistent:NO];
                            if (completed > 0) {
                                [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                            }
                            return;
                        }
                        processChunk(chunkIndex + 1);
                    });
                };
                processChunk(0);
            } else {
                BOOL isAI = (engine == SGBatchTranslationEngineAppleIntelligence);
                NSString *symbol = isAI ? @"apple.intelligence" : @"translate";
                NSString *by = isAI ? SGTranslatedByAppleIntelligence : SGTranslatedOnDevice;
                __block NSString *lastError = nil;
                __block void (^translateNext)(NSUInteger);
                translateNext = ^(NSUInteger idx) {
                    if (idx >= total) {
                        translateNext = nil;
                        sg_translating = NO;
                        if (completed == total) {
                            NSString *detail = completed == 1 ? @"1 song saved" : [NSString stringWithFormat:@"%lu songs saved", (unsigned long)completed];
                            [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"%@ Translated", entityName] detail:detail symbol:@"checkmark.circle" persistent:NO];
                        } else if (completed > 0) {
                            NSString *title = [NSString stringWithFormat:@"Translated %lu of %lu", (unsigned long)completed, (unsigned long)total];
                            NSString *detail = lastError ?: [NSString stringWithFormat:@"%lu songs saved", (unsigned long)completed];
                            [SGAlbumQueueNotice showIn:window title:title detail:detail symbol:@"exclamationmark.circle" persistent:NO];
                        } else {
                            [SGAlbumQueueNotice showIn:window title:@"Translation Failed" detail:lastError ?: @"Could not translate songs" symbol:@"exclamationmark.circle" persistent:NO];
                        }
                        if (completed > 0) {
                            [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                        }
                        return;
                    }
                    SGBatchCandidateSong *song = candidates[idx];
                    [SGAlbumQueueNotice showIn:window title:[NSString stringWithFormat:@"Translating %@", entityName] detail:[NSString stringWithFormat:@"%lu of %lu songs…", (unsigned long)(idx + 1), (unsigned long)total] symbol:symbol persistent:YES];
                    void (^onDone)(NSArray<NSString *> *, NSString *) = ^(NSArray<NSString *> *translations, NSString *err) {
                        if (!err && translations.count == song.lines.count) {
                            for (NSUInteger lIdx = 0; lIdx < song.lines.count; lIdx++) {
                                NSString *t = translations[lIdx];
                                if (t.length) {
                                    song.lines[lIdx].translation = t;
                                    song.lines[lIdx].translationMade = YES;
                                }
                            }
                            SGLyricsSaveTranslation(song.trackID, targetLang, song.lines, [SGTranslationSource by:by model:nil made:nil]);
                            completed++;
                        } else if (err.length) {
                            lastError = err;
                            if ([err hasPrefix:@"Download "] ||
                                [err containsString:@"needs iOS 26"] ||
                                [err containsString:@"does not work in this language"]) {
                                translateNext = nil;
                                sg_translating = NO;
                                NSString *title = completed > 0
                                    ? [NSString stringWithFormat:@"Translated %lu of %lu", (unsigned long)completed, (unsigned long)total]
                                    : @"Translation Failed";
                                [SGAlbumQueueNotice showIn:window title:title detail:err symbol:@"exclamationmark.circle" persistent:NO];
                                if (completed > 0) {
                                    [NSNotificationCenter.defaultCenter postNotificationName:SGLyricsTranslationsDidChangeNotification object:nil];
                                }
                                return;
                            }
                        }
                        translateNext(idx + 1);
                    };
                    if (isAI) {
                        [SGOnDeviceTranslation translateWithAppleIntelligence:song.texts to:targetLang song:SGLyricsSongName(song.trackID) progress:^(NSArray<NSString *> *soFar) {} done:onDone];
                    } else {
                        [SGOnDeviceTranslation translate:song.texts to:targetLang from:window done:onDone];
                    }
                };
                translateNext(0);
            }
        });
    });
}

#pragma mark - Menu & Row UI

@interface SGBatchTranslateRow : UIButton
@property (nonatomic, copy) NSString *uri;
@property (nonatomic, weak) UIViewController *menuController;
@end

@implementation SGBatchTranslateRow {
    UILabel *_title;
    UIImageView *_icon;
    UIImageView *_chevron;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    _title = [UILabel new];
    _title.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _title.adjustsFontForContentSizeCategory = YES;
    _title.textColor = UIColor.whiteColor;

    _icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"translate"]];
    _icon.tintColor = [UIColor colorWithWhite:1 alpha:0.65];
    _icon.contentMode = UIViewContentModeScaleAspectFit;

    _chevron = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"chevron.right"]];
    _chevron.tintColor = [UIColor colorWithWhite:1 alpha:0.35];
    _chevron.contentMode = UIViewContentModeScaleAspectFit;

    for (UIView *v in @[_title, _icon, _chevron]) {
        v.userInteractionEnabled = NO;
        [self addSubview:v];
    }
    self.isAccessibilityElement = YES;
    self.showsMenuAsPrimaryAction = YES;
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _icon.frame = CGRectMake(16, (h - 24) / 2, 24, 24);
    _chevron.frame = CGRectMake(MAX(0, w - 32), (h - 16) / 2, 16, 16);
    _title.frame = CGRectMake(56, 0, MAX(0, w - 96), h);
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = [UIColor colorWithWhite:1 alpha:highlighted ? 0.08 : 0];
}

- (void)configureForURI:(NSString *)uri menuController:(UIViewController *)menu {
    _uri = [uri copy];
    _menuController = menu;
    BOOL isAlbum = SGAlbumQueueIsAlbumURI(uri);
    NSString *rowTitle = isAlbum ? @"Translate Album" : @"Translate Playlist";
    _title.text = rowTitle;
    self.accessibilityLabel = rowTitle;
    self.accessibilityIdentifier = @"spotifyglass.batchTranslate";

    UIWindow *window = normalAppWindow(menu.viewIfLoaded.window);

    NSString *targetLang = SGLyricsTranslationTarget();
    BOOL onDevice = SGFlag(SGKeyLyricsTranslateOnDevice, YES) && SGOnDeviceTranslation.translationAvailable;
    BOOL intelligence = SGFlag(SGKeyLyricsAppleIntelligence, YES) && [SGOnDeviceTranslation appleIntelligenceAvailable:targetLang];
    BOOL ai = SGAITranslatorReady();

    NSMutableArray<UIMenuElement *> *items = [NSMutableArray array];
    __weak UIViewController *weakMenu = menu;
    UIWindow *strongWindow = window;

    if (onDevice) {
        UIAction *action = [UIAction actionWithTitle:@"Translate on iPhone" image:[UIImage systemImageNamed:@"translate"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineOnDevice, strongWindow);
        }];
        action.subtitle = @"Apple's Translate, on this iPhone";
        [items addObject:action];
    }
    if (intelligence) {
        UIAction *action = [UIAction actionWithTitle:@"Translate with Apple Intelligence" image:[UIImage systemImageNamed:@"apple.intelligence"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineAppleIntelligence, strongWindow);
        }];
        action.subtitle = @"On this iPhone";
        [items addObject:action];
    }
    if (ai) {
        NSString *title = [@"Translate with " stringByAppendingString:SGAITranslatorName()];
        NSString *subtitle = [@"Sends the lyrics to " stringByAppendingString:SGAITranslatorRecipient()];
        UIAction *action = [UIAction actionWithTitle:title image:[UIImage systemImageNamed:@"sparkles"] identifier:nil handler:^(UIAction *a) {
            [weakMenu dismissViewControllerAnimated:YES completion:nil];
            SGBatchTranslateURI(uri, SGBatchTranslationEngineAI, strongWindow);
        }];
        action.subtitle = subtitle;
        [items addObject:action];
    }
    if (!onDevice && !intelligence && !ai) {
        UIAction *action = [UIAction actionWithTitle:@"No Translator Configured" image:[UIImage systemImageNamed:@"exclamationmark.circle"] identifier:nil handler:^(UIAction *a) {}];
        action.attributes = UIMenuElementAttributesDisabled;
        action.subtitle = @"Add an API key in Mod Settings > Lyrics";
        [items addObject:action];
    }
    self.menu = [UIMenu menuWithTitle:rowTitle image:[UIImage systemImageNamed:@"translate"] identifier:nil options:0 children:items];
    self.enabled = YES;
}
@end

static UITableView *tableInView(UIView *view, NSUInteger depth) {
    if ([view isKindOfClass:UITableView.class]) return (UITableView *)view;
    if (depth > 6) return nil;
    for (UIView *child in view.subviews) {
        UITableView *table = tableInView(child, depth + 1);
        if (table) return table;
    }
    return nil;
}

void SGBatchTranslationInstall(UIViewController *menu) {
    NSString *uri = objc_getAssociatedObject(menu, &kURIKey);
    if (!uri && !objc_getAssociatedObject(menu, &kSeenKey)) {
        objc_setAssociatedObject(menu, &kSeenKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (CACurrentMediaTime() - sg_markedAt <= 1.5 && SGIsValidEntityURI(sg_pendingURI)) {
            uri = SGSanitizeEntityURI(sg_pendingURI);
        }
        sg_pendingURI = nil;
        if (!uri) {
            typedef UIView *(*RecentPageFn)(void);
            RecentPageFn recentPage = (RecentPageFn)dlsym(RTLD_DEFAULT, "SGRPinnedMoreRecentPage");
            UIView *page = recentPage ? recentPage() : nil;
            if (page) uri = SGResolveEntityURIForView(page);
        }
        if (SGIsValidEntityURI(uri)) {
            uri = SGSanitizeEntityURI(uri);
            objc_setAssociatedObject(menu, &kURIKey, uri, OBJC_ASSOCIATION_COPY_NONATOMIC);
        }
    }
    if (!SGIsValidEntityURI(uri)) return;

    UITableView *table = tableInView(menu.viewIfLoaded, 0);
    if (!table) return;

    SGBatchTranslateRow *row = objc_getAssociatedObject(menu, &kRowKey);
    if (!row) {
        row = [[SGBatchTranslateRow alloc] initWithFrame:CGRectZero];
        objc_setAssociatedObject(menu, &kRowKey, row, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [row configureForURI:uri menuController:menu];

    CGFloat rowHeight = MAX(56, [UIFont preferredFontForTextStyle:UIFontTextStyleBody].lineHeight + 24);
    CGFloat width = table.bounds.size.width;
    if (width <= 0) width = menu.viewIfLoaded.bounds.size.width;
    if (width <= 0) width = UIScreen.mainScreen.bounds.size.width;

    UIView *existingFooter = table.tableFooterView;
    if (existingFooter == row) {
        if (!CGSizeEqualToSize(row.bounds.size, CGSizeMake(width, rowHeight))) {
            [UIView performWithoutAnimation:^{
                row.frame = CGRectMake(0, 0, width, rowHeight);
                table.tableFooterView = row;
                [table invalidateIntrinsicContentSize];
                [table layoutIfNeeded];
            }];
        }
        return;
    }

    if (existingFooter && ![existingFooter isKindOfClass:UIControl.class] && [existingFooter.subviews containsObject:row]) {
        return;
    }
    if (existingFooter && existingFooter.bounds.size.height > 0) {
        NSArray<UIView *> *existingRows = [existingFooter isKindOfClass:UIControl.class] ? @[existingFooter] : [existingFooter.subviews copy];
        UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, width, existingFooter.bounds.size.height + rowHeight)];
        container.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        CGFloat y = 0;
        for (UIView *sub in existingRows) {
            if (sub == row) continue;
            sub.frame = CGRectMake(0, y, width, sub.bounds.size.height);
            y += sub.bounds.size.height;
            [container addSubview:sub];
        }
        row.frame = CGRectMake(0, y, width, rowHeight);
        y += rowHeight;
        [container addSubview:row];
        container.frame = CGRectMake(0, 0, width, y);
        [UIView performWithoutAnimation:^{
            table.tableFooterView = container;
            [table invalidateIntrinsicContentSize];
            [table layoutIfNeeded];
        }];
        return;
    }

    [UIView performWithoutAnimation:^{
        row.frame = CGRectMake(0, 0, width, rowHeight);
        table.tableFooterView = row;
        [table invalidateIntrinsicContentSize];
        [table layoutIfNeeded];
    }];
}

%hook _TtC24ContextMenu_InternalImpl25ContextMenuViewController
- (void)viewWillAppear:(BOOL)animated {
    SGBatchTranslationInstall((UIViewController *)self);
    %orig;
}
- (void)viewDidLayoutSubviews {
    %orig;
    SGBatchTranslationInstall((UIViewController *)self);
}
%end

%ctor {
    %init;
    SGRequireClasses(@[@"_TtC24ContextMenu_InternalImpl25ContextMenuViewController"]);
}
