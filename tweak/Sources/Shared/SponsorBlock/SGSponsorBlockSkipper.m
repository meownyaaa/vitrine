// Core SponsorBlock skipper conforming to SGPlayerStateObserver.
// Ported from EeveeSpotify Reincarnated (GPL-3.0).
#import "SGSponsorBlockSkipper.h"
#import "SGSponsorBlockAPI.h"
#import "SGSponsorBlockToast.h"
#import "SGSponsorBlockOverlay.h"
#import "Core/SGCore.h"
#import "Shared/Lyrics/Lyrics.h"
#import "Shared/Player/PlayerState.h"
#import <QuartzCore/QuartzCore.h>

@interface SGSponsorBlockSkipper ()
- (void)preferencesDidChange;
- (void)promptDurationSettingDidIncrease;
@end

@implementation SGSponsorBlockSkipper {
    NSString *_currentEpisodeID;
    NSArray<SGSponsorBlockSegment *> *_currentSegments;
    NSArray<NSString *> *_loadedCategories;
    NSArray<NSString *> *_fetchingCategories;
    NSMutableSet<NSString *> *_playthroughAllowed;
    NSMutableSet<NSString *> *_dismissedUUIDs;
    NSMutableSet<NSString *> *_emptyEpisodeKeys;
    NSMutableDictionary<NSString *, NSNumber *> *_failedEpisodeTimes;
    NSMutableSet<NSString *> *_promptedUUIDs;
    NSMutableDictionary<NSString *, NSNumber *> *_recordedDurationByUUID;
    NSMutableDictionary<NSString *, NSArray<NSString *> *> *_chainedUUIDsByUUID;
    SGSponsorBlockSegment *_activePromptSegment;
    BOOL _fetchInFlight;
    NSUInteger _fetchGeneration;
    BOOL _eeveeChecked;
    BOOL _eeveeActive;

    double _episodeInitialPosition;
    double _episodeDuration;
    BOOL _checkedInitialResume;
    double _lastPosition;
    CFTimeInterval _lastPositionStamp;
    double _playbackSpeed;
    BOOL _isPlaying;
    BOOL _isLoading;
    CFTimeInterval _lastSeekStamp;

    BOOL _hasPreSeekPosition;
    double _preSeekPosition;
    CFTimeInterval _preSeekStamp;
    BOOL _hasPendingSeek;
    double _pendingSeekTarget;
    CFTimeInterval _pendingSeekDeadline;
    NSString *_pendingSeekSegmentUUID;

    dispatch_source_t _pollTimer;
}

+ (instancetype)sharedSkipper {
    static SGSponsorBlockSkipper *skipper;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        skipper = [SGSponsorBlockSkipper new];
    });
    return skipper;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _playthroughAllowed = [NSMutableSet new];
    _dismissedUUIDs = [NSMutableSet new];
    _emptyEpisodeKeys = [NSMutableSet new];
    _failedEpisodeTimes = [NSMutableDictionary new];
    _promptedUUIDs = [NSMutableSet new];
    _recordedDurationByUUID = [NSMutableDictionary new];
    _chainedUUIDsByUUID = [NSMutableDictionary new];
    _currentSegments = @[];
    _loadedCategories = @[];
    _fetchingCategories = @[];
    _playbackSpeed = 1.0;
    return self;
}

- (NSString *)currentEpisodeID {
    return _currentEpisodeID;
}

- (NSArray<SGSponsorBlockSegment *> *)currentSegments {
    return _currentSegments;
}

- (double)episodeDuration {
    return _episodeDuration;
}

- (void)start {
    SGAddPlayerStateObserver(self);
    SPTPlayerState *initial = SGPlayerState();
    if (initial) [self playerStateDidReport:initial];

    __weak typeof(self) weakSelf = self;
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                    object:nil
                                                     queue:nil
                                                usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || self->_isLoading || self->_lastPositionStamp == 0 || !self->_currentEpisodeID || !self->_currentSegments.count) return;
            CFTimeInterval now = CACurrentMediaTime();
            if (![self syncFromLivePlayerForEpisode:self->_currentEpisodeID at:now]) return;
            double est = [self estimatedPositionAt:now];
            if (self->_isPlaying) [self startPolling];
            [self reconcileSegmentsAtPosition:est];
            [self checkAndSkipAtPosition:est];
        });
    }];
}

// Whether EeveeSpotify Reincarnated is loaded with its own SponsorBlock enabled,
// in which case we stand aside so both tweaks do not double-seek the same episode.
static BOOL queryEeveeSponsorBlockActive(void) {
    if (!SGEeveeSpotifyInjected()) return NO;
    NSData *data = [NSUserDefaults.standardUserDefaults dataForKey:@"sponsorBlock"];
    if (![data isKindOfClass:NSData.class] || !data.length) return NO;
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![dict isKindOfClass:NSDictionary.class]) return NO;
    id enabled = dict[@"enabled"];
    return [enabled respondsToSelector:@selector(boolValue)] && [enabled boolValue];
}

- (BOOL)eeveeSponsorBlockActive {
    if (!_eeveeChecked) {
        _eeveeActive = queryEeveeSponsorBlockActive();
        _eeveeChecked = YES;
    }
    return _eeveeActive;
}

static NSString *extractEpisodeID(NSString *uri) {
    if (!uri.length) return nil;
    NSString *sub = nil;
    if ([uri hasPrefix:@"spotify:episode:"]) {
        sub = [uri substringFromIndex:@"spotify:episode:".length];
    } else {
        NSRange range = [uri rangeOfString:@"/episode/"];
        if (range.location != NSNotFound) {
            sub = [uri substringFromIndex:range.location + range.length];
        }
    }
    if (!sub.length) return nil;
    NSRange q = [sub rangeOfString:@"?"];
    if (q.location != NSNotFound) sub = [sub substringToIndex:q.location];
    return sub.length ? sub : nil;
}

static NSArray<NSString *> *enabledCategories(void) {
    NSMutableArray<NSString *> *cats = [NSMutableArray array];
    for (NSString *cat in SGSponsorBlockAllCategories()) {
        if (SGSponsorBlockCategoryBehavior(cat) != SGSponsorBlockBehaviorOff) {
            [cats addObject:cat];
        }
    }
    return cats;
}

static void performSeek(double targetSec) {
    id player = SGPlayer() ?: SGKaraokePlayer();
    if (player && [player respondsToSelector:@selector(seekTo:)]) {
        [(id<SPTPlayer>)player seekTo:targetSec];
    } else {
        SGKaraokeSeek((NSInteger)llround(targetSec * 1000.0));
    }
}

- (double)estimatedPositionAt:(CFTimeInterval)now {
    return _isPlaying ? (_lastPosition + (now - _lastPositionStamp) * _playbackSpeed) : _lastPosition;
}

- (BOOL)hasActivePendingSeekAt:(CFTimeInterval)now {
    return _hasPendingSeek && now <= _pendingSeekDeadline;
}

- (BOOL)hasUpcomingSegmentsAfterPosition:(double)pos {
    NSTimeInterval minDuration = SGSponsorBlockMinDuration();
    for (SGSponsorBlockSegment *seg in _currentSegments) {
        if (![seg.actionType isEqualToString:@"skip"]) continue;
        if (seg.duration < minDuration) continue;
        if ([_playthroughAllowed containsObject:seg.uuid]) continue;
        SGSponsorBlockBehavior beh = SGSponsorBlockCategoryBehavior(seg.category);
        if (beh != SGSponsorBlockBehaviorSkip && beh != SGSponsorBlockBehaviorPrompt) continue;
        if (seg.end > pos) return YES;
    }
    return NO;
}

// Returns wall-clock seconds until the next SponsorBlock action or boundary, or < 0 if none.
- (double)wallDelayUntilNextEventAt:(double)pos now:(CFTimeInterval)now {
    if (_hasPendingSeek) {
        return MAX(0.05, (_pendingSeekDeadline - now) + 0.05);
    }

    double speed = (_playbackSpeed > 0) ? _playbackSpeed : 1.0;
    NSTimeInterval minDuration = SGSponsorBlockMinDuration();
    BOOL respectManual = SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual);
    double minDelay = -1.0;

    if (_activePromptSegment) {
        double delta = _activePromptSegment.end - pos;
        if (delta > 0) minDelay = delta / speed;
        else return 0.0;
    }

    for (SGSponsorBlockSegment *seg in _currentSegments) {
        if (![seg.actionType isEqualToString:@"skip"]) continue;
        if (seg.duration < minDuration) continue;
        if ([_playthroughAllowed containsObject:seg.uuid]) continue;
        SGSponsorBlockBehavior beh = SGSponsorBlockCategoryBehavior(seg.category);
        if (beh != SGSponsorBlockBehaviorSkip && beh != SGSponsorBlockBehaviorPrompt) continue;

        BOOL manualDismissed = (respectManual && [_dismissedUUIDs containsObject:seg.uuid]);
        BOOL wantsAutoSkip = (beh == SGSponsorBlockBehaviorSkip && !manualDismissed);
        BOOL wantsPrompt = (beh == SGSponsorBlockBehaviorPrompt || manualDismissed) && ![_promptedUUIDs containsObject:seg.uuid];

        if (pos >= seg.start && pos < seg.end) {
            double remaining = seg.end - pos;
            if (wantsAutoSkip && remaining >= 0.8) {
                NSTimeInterval cooldownRemaining = 1.2 - (now - _lastSeekStamp);
                if (cooldownRemaining > 0.0) {
                    double wait = MAX(0.05, cooldownRemaining);
                    if (minDelay < 0.0 || wait < minDelay) minDelay = wait;
                } else {
                    return 0.0;
                }
            } else if (wantsPrompt && remaining >= 1.0) {
                if ([SGSponsorBlockToast isPresentingUndoToast] && _lastSeekStamp > 0) {
                    NSTimeInterval grace = MIN(4.0, MAX(1.5, remaining - 2.0));
                    NSTimeInterval graceRemaining = grace - (now - _lastSeekStamp);
                    if (graceRemaining > 0.0) {
                        double wait = MAX(0.05, graceRemaining);
                        if (minDelay < 0.0 || wait < minDelay) minDelay = wait;
                    } else {
                        return 0.0;
                    }
                } else {
                    return 0.0;
                }
            }
            double endDelay = remaining / speed;
            if (endDelay > 0 && (minDelay < 0.0 || endDelay < minDelay)) {
                minDelay = endDelay;
            }
        } else if (seg.start > pos) {
            double startDelay = (seg.start - pos) / speed;
            if (minDelay < 0.0 || startDelay < minDelay) {
                minDelay = startDelay;
            }
        }
    }
    return minDelay;
}

- (void)clearPendingSeekState {
    _hasPendingSeek = NO;
    _pendingSeekTarget = 0;
    _pendingSeekDeadline = 0;
    _pendingSeekSegmentUUID = nil;
    _hasPreSeekPosition = NO;
    _preSeekPosition = 0;
    _preSeekStamp = 0;
}

- (void)rollbackTimedOutPendingSeek {
    if (_pendingSeekSegmentUUID) {
        NSNumber *recorded = _recordedDurationByUUID[_pendingSeekSegmentUUID];
        if (recorded) {
            [_recordedDurationByUUID removeObjectForKey:_pendingSeekSegmentUUID];
            SGUndoRecordSponsorBlockSkip(recorded.doubleValue);
        }
        [_playthroughAllowed addObject:_pendingSeekSegmentUUID];
        for (NSString *chained in _chainedUUIDsByUUID[_pendingSeekSegmentUUID]) {
            [_playthroughAllowed addObject:chained];
        }
        [_chainedUUIDsByUUID removeObjectForKey:_pendingSeekSegmentUUID];
        if ([SGSponsorBlockToast isPresentingUndoToast]) {
            [SGSponsorBlockToast dismissImmediate:YES];
        }
    }
    [self clearPendingSeekState];
}

// Updates position, playback speed, duration, and playing state from SGPlayerState() if it matches
// episodeID and no seek is in flight. Returns NO if the player is currently loading.
- (BOOL)syncFromLivePlayerForEpisode:(NSString *)episodeID at:(CFTimeInterval)now {
    SPTPlayerState *live = SGPlayerState();
    if (!live || [self hasActivePendingSeekAt:now] || ![extractEpisodeID(SGURIString(live.track.URI)) isEqualToString:episodeID]) {
        return !_isLoading;
    }
    if ([live respondsToSelector:@selector(isLoading)] && live.isLoading) {
        _isLoading = YES;
        return NO;
    }
    double rawPos = live.isPaused ? live.positionAsOfTimestamp : live.position;
    if (isfinite(rawPos) && rawPos >= 0) {
        if (_lastPositionStamp == 0 && !_checkedInitialResume) {
            _episodeInitialPosition = rawPos;
        }
        _lastPosition = rawPos;
        _lastPositionStamp = now;
    }
    _playbackSpeed = ([live respondsToSelector:@selector(playbackSpeed)] && live.playbackSpeed > 0) ? live.playbackSpeed : 1.0;
    if (isfinite(live.duration) && live.duration > 0) {
        _episodeDuration = live.duration;
    }
    _isPlaying = live.isPlaying && !live.isPaused;
    _isLoading = NO;
    return YES;
}

// Match EeveeSpotify: if the user resumed an episode already mid-segment (initial position > 1.5s
// past seg.start, so segments starting at 0:00 still auto-skip even after network fetch latency),
// dismiss auto-skip for that segment when Respect Manual Scrub is on so it prompts instead.
- (void)checkInitialResumeAtPosition:(double)pos {
    if (_checkedInitialResume || !_currentSegments.count) return;
    _checkedInitialResume = YES;
    if (!SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual)) return;
    double initPos = _episodeInitialPosition;
    for (SGSponsorBlockSegment *seg in _currentSegments) {
        if (initPos >= seg.start + 1.5 && initPos < seg.end && pos >= seg.start && pos < seg.end) {
            [_dismissedUUIDs addObject:seg.uuid];
            [_promptedUUIDs removeObject:seg.uuid];
        }
    }
}

- (void)resetPerEpisodeState {
    [self stopPolling];
    if (_activePromptSegment || _currentEpisodeID) {
        _activePromptSegment = nil;
        [SGSponsorBlockToast dismissImmediate:YES];
    }
    _currentEpisodeID = nil;
    _currentSegments = @[];
    _loadedCategories = @[];
    _fetchingCategories = @[];
    _fetchInFlight = NO;
    _fetchGeneration++;
    [_playthroughAllowed removeAllObjects];
    [_dismissedUUIDs removeAllObjects];
    [_promptedUUIDs removeAllObjects];
    [_recordedDurationByUUID removeAllObjects];
    [_chainedUUIDsByUUID removeAllObjects];
    _episodeInitialPosition = 0;
    _episodeDuration = 0;
    _checkedInitialResume = NO;
    _lastPosition = 0;
    _lastPositionStamp = 0;
    _isPlaying = NO;
    _isLoading = NO;
    _lastSeekStamp = 0;
    [self clearPendingSeekState];
    [SGSponsorBlockOverlay refreshAll];
}

- (void)clearEpisodeState {
    [self resetPerEpisodeState];
    [_failedEpisodeTimes removeAllObjects];
}

- (void)preferencesDidChange {
    dispatch_block_t work = ^{
        [SGSponsorBlockOverlay refreshAll];
        self->_eeveeChecked = NO;
        if (!SGFlag(SGKeySponsorBlockEnabled, NO) || [self eeveeSponsorBlockActive]) {
            [self clearEpisodeState];
            return;
        }
        [SGSponsorBlockToast updateActiveToastTimeout];

        SPTPlayerState *state = SGPlayerState();
        if (!state) return;

        NSString *episodeID = extractEpisodeID(SGURIString(state.track.URI));
        if (!episodeID) {
            if (self->_currentEpisodeID || self->_currentSegments.count || self->_pollTimer) {
                [self clearEpisodeState];
            }
            return;
        }

        if (![episodeID isEqualToString:self->_currentEpisodeID]) {
            [self playerStateDidReport:state];
            return;
        }

        NSArray<NSString *> *cats = enabledCategories();
        if (!cats.count) {
            [self reconcileSegmentsAtPosition:self->_lastPosition];
            [self fetchSegmentsForEpisode:episodeID categories:@[] episodeKey:@""];
            return;
        }

        NSSet<NSString *> *wantedSet = [NSSet setWithArray:cats];
        NSSet<NSString *> *coveredSet = [NSSet setWithArray:self->_fetchInFlight ? self->_fetchingCategories : self->_loadedCategories];
        if (!coveredSet.count || ![wantedSet isSubsetOfSet:coveredSet]) {
            NSString *episodeKey = [NSString stringWithFormat:@"%@|%@", episodeID, [cats componentsJoinedByString:@","]];
            self->_currentSegments = @[];
            self->_loadedCategories = @[];
            [self fetchSegmentsForEpisode:episodeID categories:cats episodeKey:episodeKey];
            return;
        }

        if (self->_fetchInFlight || self->_isLoading || self->_lastPositionStamp == 0) return;

        CFTimeInterval now = CACurrentMediaTime();
        if (![self syncFromLivePlayerForEpisode:episodeID at:now]) return;
        double est = [self estimatedPositionAt:now];
        [self reconcileSegmentsAtPosition:est];
        if (self->_isPlaying && self->_currentSegments.count > 0) {
            [self startPolling];
        }
        [self checkAndSkipAtPosition:est];
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

- (void)promptDurationSettingDidIncrease {
    dispatch_block_t work = ^{
        if (self->_activePromptSegment && ![SGSponsorBlockToast isPresentingPromptForSegment:self->_activePromptSegment]) {
            [self->_promptedUUIDs removeObject:self->_activePromptSegment.uuid];
            self->_activePromptSegment = nil;
        }
        if (!self->_activePromptSegment && self->_currentSegments.count && self->_lastPositionStamp > 0 && !self->_isLoading) {
            double est = [self estimatedPositionAt:CACurrentMediaTime()];
            for (SGSponsorBlockSegment *seg in self->_currentSegments) {
                if (est >= seg.start && est < seg.end && seg.uuid.length) {
                    [self->_promptedUUIDs removeObject:seg.uuid];
                }
            }
        }
    };
    if (NSThread.isMainThread) work();
    else dispatch_async(dispatch_get_main_queue(), work);
}

// PlayerState.x calls playerStateDidReport: on the main thread for every state update
// (before playerStateDidChange: when the state key changes).
- (void)playerStateDidChange:(SPTPlayerState *)state {}

- (void)playerStateDidReport:(SPTPlayerState *)state {
    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || [self eeveeSponsorBlockActive]) {
        if (_currentEpisodeID || _currentSegments.count || _pollTimer) {
            [self clearEpisodeState];
        }
        return;
    }

    NSString *episodeID = extractEpisodeID(SGURIString(state.track.URI));
    if (!episodeID) {
        if (_currentEpisodeID || _currentSegments.count || _pollTimer) {
            [self clearEpisodeState];
        }
        return;
    }

    BOOL isLoading = [state respondsToSelector:@selector(isLoading)] && state.isLoading;
    BOOL isPlaying = state.isPlaying && !state.isPaused;
    double rawPos = state.isPaused ? state.positionAsOfTimestamp : state.position;
    double pos = (isfinite(rawPos) && rawPos >= 0) ? rawPos : 0.0;
    double speed = ([state respondsToSelector:@selector(playbackSpeed)] && state.playbackSpeed > 0) ? state.playbackSpeed : 1.0;
    CFTimeInterval now = CACurrentMediaTime();

    NSArray<NSString *> *cats = enabledCategories();
    NSString *episodeKey = [NSString stringWithFormat:@"%@|%@", episodeID, [cats componentsJoinedByString:@","]];

    BOOL isNewEpisode = ![episodeID isEqualToString:_currentEpisodeID];
    if (isNewEpisode) {
        [self resetPerEpisodeState];
        _currentEpisodeID = episodeID;
        _episodeDuration = (isfinite(state.duration) && state.duration > 0) ? state.duration : 0;
        _isLoading = isLoading;
        [self fetchSegmentsForEpisode:episodeID categories:cats episodeKey:episodeKey];
    }

    if (isLoading) {
        _isLoading = YES;
        _playbackSpeed = speed;
        if (isfinite(state.duration) && state.duration > 0) {
            _episodeDuration = state.duration;
        }
        [self stopPolling];
        return;
    }
    _isLoading = NO;

    BOOL firstStateForEpisode = isNewEpisode || (_lastPositionStamp == 0);
    if (firstStateForEpisode && !_checkedInitialResume) {
        _episodeInitialPosition = pos;
    }

    BOOL pendingActive = [self hasActivePendingSeekAt:now];
    BOOL isOwnSeek = NO;
    BOOL isStaleSeekCallback = NO;
    BOOL isManualSeek = NO;
    BOOL seekTimedOut = NO;

    if (_hasPendingSeek) {
        double seekElapsed = MAX(0.0, now - _lastSeekStamp) * _playbackSpeed;
        double preSeekElapsed = MAX(0.0, now - _preSeekStamp) * _playbackSpeed;
        BOOL nearTarget = (fabs(pos - _pendingSeekTarget) < 3.0 ||
                           (pos >= _pendingSeekTarget - 0.5 && pos <= _pendingSeekTarget + seekElapsed + 3.0));
        BOOL nearPreSeek = (_hasPreSeekPosition && pos >= _preSeekPosition - 0.5 && pos <= _preSeekPosition + preSeekElapsed + 3.0);
        if (nearTarget) {
            isOwnSeek = YES;
        } else if (pendingActive) {
            if (nearPreSeek) {
                isStaleSeekCallback = YES;
            } else {
                isManualSeek = YES;
            }
        } else if (nearPreSeek) {
            seekTimedOut = YES;
        } else {
            isManualSeek = YES;
        }
    } else {
        double elapsed = (!firstStateForEpisode && _isPlaying) ? (now - _lastPositionStamp) : 0.0;
        double expected = _lastPosition + elapsed * _playbackSpeed;
        double delta = pos - expected;
        isManualSeek = (!firstStateForEpisode && fabs(delta) > 2.0);
    }

    if (seekTimedOut) {
        [self rollbackTimedOutPendingSeek];
    } else if (isOwnSeek || isManualSeek) {
        [self clearPendingSeekState];
    }
    BOOL respectManual = SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual);

    if (isManualSeek) {
        _lastSeekStamp = 0;
        if ([SGSponsorBlockToast isPresentingUndoToast]) {
            [SGSponsorBlockToast dismissImmediate:YES];
        }
        if (!_checkedInitialResume) {
            _episodeInitialPosition = pos;
        }
        [_playthroughAllowed removeAllObjects];
        for (SGSponsorBlockSegment *seg in _currentSegments) {
            if (pos >= seg.start && pos < seg.end) {
                if (respectManual) [_dismissedUUIDs addObject:seg.uuid];
                [_promptedUUIDs removeObject:seg.uuid];
                if (_activePromptSegment && [_activePromptSegment.uuid isEqualToString:seg.uuid]) {
                    _activePromptSegment = nil;
                }
            } else if (pos < seg.start) {
                [_dismissedUUIDs removeObject:seg.uuid];
                [_promptedUUIDs removeObject:seg.uuid];
            }
        }
    }

    if (!isStaleSeekCallback) {
        _lastPosition = pos;
        _lastPositionStamp = now;
    }
    _playbackSpeed = speed;
    _isPlaying = isPlaying;
    if (isfinite(state.duration) && state.duration > 0) {
        if (_episodeDuration != state.duration) {
            _episodeDuration = state.duration;
            [SGSponsorBlockOverlay refreshAll];
        }
    }

    if (!isNewEpisode && _currentSegments.count == 0 && !_fetchInFlight && cats.count > 0) {
        BOOL alreadyCovered = (_loadedCategories.count > 0 &&
                               [[NSSet setWithArray:cats] isSubsetOfSet:[NSSet setWithArray:_loadedCategories]]);
        if (!alreadyCovered && ![_emptyEpisodeKeys containsObject:episodeKey]) {
            NSNumber *failedStamp = _failedEpisodeTimes[episodeKey];
            if (!failedStamp || (now - failedStamp.doubleValue) >= 30.0) {
                [self fetchSegmentsForEpisode:episodeID categories:cats episodeKey:episodeKey];
            }
        }
    }

    [self checkInitialResumeAtPosition:_lastPosition];

    if (_isPlaying && _currentSegments.count > 0) {
        [self startPolling];
    } else {
        [self stopPolling];
    }

    if (!isStaleSeekCallback) {
        [self reconcileSegmentsAtPosition:_lastPosition];
        if (_isPlaying || isManualSeek) {
            [self checkAndSkipAtPosition:_lastPosition];
        }
    }
}

- (void)fetchSegmentsForEpisode:(NSString *)episodeID
                     categories:(NSArray<NSString *> *)cats
                     episodeKey:(NSString *)episodeKey {
    NSUInteger gen = ++_fetchGeneration;
    if (!cats.count) {
        _currentSegments = @[];
        _loadedCategories = cats;
        _fetchingCategories = @[];
        _fetchInFlight = NO;
        [self stopPolling];
        return;
    }
    _fetchInFlight = YES;
    _fetchingCategories = [cats copy];
    __weak typeof(self) weakSelf = self;
    [SGSponsorBlockAPI fetchSegmentsForEpisode:episodeID categories:cats completion:^(NSArray<SGSponsorBlockSegment *> *segments, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (self->_fetchGeneration != gen || ![self->_currentEpisodeID isEqualToString:episodeID]) return;
        self->_fetchInFlight = NO;
        self->_fetchingCategories = @[];

        if (error) {
            self->_loadedCategories = @[];
            self->_currentSegments = @[];
            self->_failedEpisodeTimes[episodeKey] = @(CACurrentMediaTime());
            [self stopPolling];
            [SGSponsorBlockOverlay refreshAll];
            return;
        }
        [self->_failedEpisodeTimes removeObjectForKey:episodeKey];
        self->_loadedCategories = cats;
        self->_currentSegments = segments ?: @[];
        [SGSponsorBlockOverlay refreshAll];
        if (self->_currentSegments.count == 0) {
            [self->_emptyEpisodeKeys addObject:episodeKey];
            [self stopPolling];
            return;
        }

        CFTimeInterval now = CACurrentMediaTime();
        if (![self syncFromLivePlayerForEpisode:episodeID at:now]) return;
        if (self->_isLoading || self->_lastPositionStamp == 0) return;

        double est = [self estimatedPositionAt:now];
        [self checkInitialResumeAtPosition:est];
        [self reconcileSegmentsAtPosition:est];
        if (self->_isPlaying) {
            [self startPolling];
        }
        [self checkAndSkipAtPosition:est];
    }];
}

- (void)startPolling {
    [self stopPolling];
    if (!_isPlaying || !_currentSegments.count) return;

    CFTimeInterval now = CACurrentMediaTime();
    double pos = [self estimatedPositionAt:now];
    double wallDelay = [self wallDelayUntilNextEventAt:pos now:now];
    if (wallDelay < 0.0) return;

    double delay = MAX(0.05, wallDelay);

    _pollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    uint64_t nsec = (uint64_t)(delay * NSEC_PER_SEC);
    dispatch_source_set_timer(_pollTimer, dispatch_time(DISPATCH_TIME_NOW, nsec), DISPATCH_TIME_FOREVER, 50 * NSEC_PER_MSEC);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(_pollTimer, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || !self->_isPlaying) return;
        CFTimeInterval fireNow = CACurrentMediaTime();
        double currentPos = [self estimatedPositionAt:fireNow];
        [self reconcileSegmentsAtPosition:currentPos];
        [self checkAndSkipAtPosition:currentPos];
        [self startPolling];
    });
    dispatch_resume(_pollTimer);
}

- (void)stopPolling {
    if (!_pollTimer) return;
    dispatch_source_cancel(_pollTimer);
    _pollTimer = nil;
}

- (void)reconcileSegmentsAtPosition:(double)pos {
    BOOL respectManual = SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual);

    if (_activePromptSegment) {
        SGSponsorBlockBehavior activeBehavior = SGSponsorBlockCategoryBehavior(_activePromptSegment.category);
        BOOL activeManualDismissed = (respectManual && [_dismissedUUIDs containsObject:_activePromptSegment.uuid]);
        BOOL shouldStillPrompt = (activeBehavior == SGSponsorBlockBehaviorPrompt) ||
                                 (activeBehavior == SGSponsorBlockBehaviorSkip && activeManualDismissed);
        if (pos >= _activePromptSegment.end || pos < _activePromptSegment.start || !shouldStillPrompt) {
            SGSponsorBlockSegment *stale = _activePromptSegment;
            _activePromptSegment = nil;
            [SGSponsorBlockToast dismissIfPromptForSegment:stale];
        }
    }

    if (_playthroughAllowed.count) {
        NSMutableSet<NSString *> *finished = [NSMutableSet set];
        for (NSString *uuid in _playthroughAllowed) {
            for (SGSponsorBlockSegment *s in _currentSegments) {
                if ([s.uuid isEqualToString:uuid] && pos >= s.end) {
                    [finished addObject:uuid];
                    break;
                }
            }
        }
        if (finished.count) [_playthroughAllowed minusSet:finished];
    }

    // Re-allow prompt when manually rewound before segment start or when category/scrub settings
    // disabled prompting for the segment; keep completed segments in _promptedUUIDs while pos >= s.end.
    if (_promptedUUIDs.count) {
        NSMutableSet<NSString *> *stalePrompts = [NSMutableSet set];
        for (NSString *uuid in _promptedUUIDs) {
            for (SGSponsorBlockSegment *s in _currentSegments) {
                if ([s.uuid isEqualToString:uuid]) {
                    SGSponsorBlockBehavior b = SGSponsorBlockCategoryBehavior(s.category);
                    BOOL manualDismissed = (respectManual && [_dismissedUUIDs containsObject:uuid]);
                    BOOL canPrompt = (b == SGSponsorBlockBehaviorPrompt) || (b == SGSponsorBlockBehaviorSkip && manualDismissed);
                    if (pos < s.start || !canPrompt) {
                        [stalePrompts addObject:uuid];
                    }
                    break;
                }
            }
        }
        if (stalePrompts.count) [_promptedUUIDs minusSet:stalePrompts];
    }

    if (_pollTimer && _currentSegments.count && ![self hasUpcomingSegmentsAfterPosition:pos]) {
        [self stopPolling];
    }
}

// Performs the seek for an auto-skip or accepted skip prompt, chaining contiguous auto-skip
// segments and recording any subsumed overlapping segments so Undo covers the entire span.
- (void)skipSegment:(SGSponsorBlockSegment *)seg fromPosition:(double)pos at:(CFTimeInterval)now {
    if (_activePromptSegment) {
        SGSponsorBlockSegment *stale = _activePromptSegment;
        _activePromptSegment = nil;
        [SGSponsorBlockToast dismissIfPromptForSegment:stale];
    }

    BOOL respectManual = SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual);
    NSTimeInterval minDuration = SGSponsorBlockMinDuration();

    double target = seg.end + 0.05;
    NSMutableArray<NSString *> *chainedUUIDs = [NSMutableArray array];
    BOOL extended = YES;
    while (extended) {
        extended = NO;
        for (SGSponsorBlockSegment *next in _currentSegments) {
            if (next == seg || ![next.actionType isEqualToString:@"skip"]) continue;
            if (next.duration < minDuration) continue;
            if ([_playthroughAllowed containsObject:next.uuid]) continue;
            if (respectManual && [_dismissedUUIDs containsObject:next.uuid]) continue;
            if (SGSponsorBlockCategoryBehavior(next.category) != SGSponsorBlockBehaviorSkip) continue;
            if (next.start <= target + 0.5 && next.end > target) {
                target = next.end + 0.05;
                if (next.uuid.length && ![chainedUUIDs containsObject:next.uuid]) {
                    [chainedUUIDs addObject:next.uuid];
                }
                extended = YES;
            }
        }
    }
    for (SGSponsorBlockSegment *subsumed in _currentSegments) {
        if (subsumed == seg || !subsumed.uuid.length) continue;
        if (subsumed.start < target && subsumed.end > pos && ![chainedUUIDs containsObject:subsumed.uuid]) {
            [chainedUUIDs addObject:subsumed.uuid];
        }
    }

    [_dismissedUUIDs removeObject:seg.uuid];
    for (NSString *uuid in chainedUUIDs) {
        [_dismissedUUIDs removeObject:uuid];
    }

    double rawEnd = target - 0.05;
    if (_episodeDuration > 1.0 && target >= _episodeDuration - 0.25) {
        target = MIN(_episodeDuration - 0.05, MAX(pos + 0.1, _episodeDuration - 0.25));
        if (target <= pos) target = MIN(_episodeDuration - 0.02, pos + 0.05);
        rawEnd = MIN(rawEnd, _episodeDuration);
    }

    _hasPreSeekPosition = YES;
    _preSeekPosition = pos;
    _preSeekStamp = now;
    _hasPendingSeek = YES;
    _pendingSeekTarget = target;
    _pendingSeekDeadline = now + 2.5;
    _pendingSeekSegmentUUID = [seg.uuid copy];
    _lastSeekStamp = now;
    _lastPosition = pos;
    _lastPositionStamp = now;

    NSTimeInterval skippedDuration = MAX(0.0, rawEnd - pos);
    _recordedDurationByUUID[seg.uuid] = @(skippedDuration);
    if (chainedUUIDs.count) _chainedUUIDsByUUID[seg.uuid] = [chainedUUIDs copy];
    else [_chainedUUIDsByUUID removeObjectForKey:seg.uuid];
    SGRecordSponsorBlockSkip(skippedDuration);

    performSeek(target);
    if (_isPlaying && _currentSegments.count > 0) {
        [self startPolling];
    }

    if (UIApplication.sharedApplication.applicationState != UIApplicationStateBackground) {
        if (SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockHaptics)) {
            UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
            [feedback impactOccurred];
        }
        if (SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockShowToast)) {
            __weak typeof(self) weakSelf = self;
            [SGSponsorBlockToast showWithCategory:seg.category duration:skippedDuration undoHandler:^{
                [weakSelf undoSkipForSegment:seg];
            }];
        }
    }
}

- (void)checkAndSkipAtPosition:(double)pos {
    if (!SGFlag(SGKeySponsorBlockEnabled, NO) || [self eeveeSponsorBlockActive]) return;
    if (!_currentEpisodeID || !_currentSegments.count) return;
    CFTimeInterval now = CACurrentMediaTime();
    if (_hasPendingSeek) {
        if (now <= _pendingSeekDeadline) return;
        [self rollbackTimedOutPendingSeek];
    }

    [self reconcileSegmentsAtPosition:pos];

    BOOL respectManual = SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockRespectManual);
    NSTimeInterval minDuration = SGSponsorBlockMinDuration();

    // Pass 1: Auto-Skip eligible segments first so an overlapping Prompt segment at the same
    // timestamp never flashes a prompt right before an immediate auto-skip.
    if (_isPlaying) {
        for (SGSponsorBlockSegment *seg in _currentSegments) {
            if (![seg.actionType isEqualToString:@"skip"] || seg.duration < minDuration) continue;
            if ([_playthroughAllowed containsObject:seg.uuid]) continue;
            if (respectManual && [_dismissedUUIDs containsObject:seg.uuid]) continue;
            if (SGSponsorBlockCategoryBehavior(seg.category) != SGSponsorBlockBehaviorSkip) continue;

            if (pos >= seg.start && (seg.end - pos) >= 0.8) {
                if (now - _lastSeekStamp < 1.2) return;
                [self skipSegment:seg fromPosition:pos at:now];
                return;
            }
        }
    }

    // Pass 2: Present a Skip prompt if the category is set to Prompt, or if the user manually
    // sought into an Auto-Skip segment while Respect Manual Scrub is active.
    for (SGSponsorBlockSegment *seg in _currentSegments) {
        if (![seg.actionType isEqualToString:@"skip"] || seg.duration < minDuration) continue;
        if ([_playthroughAllowed containsObject:seg.uuid]) continue;

        SGSponsorBlockBehavior behavior = SGSponsorBlockCategoryBehavior(seg.category);
        if (behavior == SGSponsorBlockBehaviorOff || behavior == SGSponsorBlockBehaviorShowOnly) continue;

        BOOL isManualSeekDismissed = (respectManual && [_dismissedUUIDs containsObject:seg.uuid]);
        if (behavior != SGSponsorBlockBehaviorPrompt && !isManualSeekDismissed) continue;

        double remaining = seg.end - pos;
        if (pos >= seg.start && remaining >= 1.0) {
            if (UIApplication.sharedApplication.applicationState == UIApplicationStateBackground) continue;
            if ([_promptedUUIDs containsObject:seg.uuid]) continue;
            if (_activePromptSegment && [SGSponsorBlockToast isPresentingPromptForSegment:_activePromptSegment]) continue;
            if ([SGSponsorBlockToast isPresentingUndoToast] && _lastSeekStamp > 0) {
                NSTimeInterval grace = MIN(4.0, MAX(1.5, remaining - 2.0));
                if ((now - _lastSeekStamp) < grace) continue;
            }

            __weak typeof(self) weakSelf = self;
            [SGSponsorBlockToast showPromptForSegment:seg
                                            remaining:remaining
                                          skipHandler:^{
                [weakSelf userDidAcceptSkipPromptForSegment:seg];
            }];
            if ([SGSponsorBlockToast isPresentingPromptForSegment:seg]) {
                [_promptedUUIDs addObject:seg.uuid];
                for (SGSponsorBlockSegment *nested in _currentSegments) {
                    if (nested != seg && nested.uuid.length &&
                        nested.start >= seg.start && nested.end <= seg.end + 1.0) {
                        [_promptedUUIDs addObject:nested.uuid];
                    }
                }
                _activePromptSegment = seg;
                if (SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockHaptics)) {
                    UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
                    [feedback impactOccurred];
                }
            }
        }
    }
}

- (void)userDidAcceptSkipPromptForSegment:(SGSponsorBlockSegment *)seg {
    if (!seg || !_currentEpisodeID || ![_currentSegments containsObject:seg]) return;
    if (_activePromptSegment && [_activePromptSegment.uuid isEqualToString:seg.uuid]) {
        _activePromptSegment = nil;
    }
    CFTimeInterval now = CACurrentMediaTime();
    double currentPos = [self estimatedPositionAt:now];
    if (currentPos < seg.start - 0.5 || (seg.end - currentPos) <= 0.05) return;
    [self skipSegment:seg fromPosition:currentPos at:now];
}

- (void)undoSkipForSegment:(SGSponsorBlockSegment *)seg {
    if (!seg || !_currentEpisodeID || ![_currentSegments containsObject:seg]) return;
    CFTimeInterval now = CACurrentMediaTime();
    double currentPos = [self estimatedPositionAt:now];
    [_playthroughAllowed addObject:seg.uuid];
    for (NSString *chainedUUID in _chainedUUIDsByUUID[seg.uuid]) {
        [_playthroughAllowed addObject:chainedUUID];
    }
    [_chainedUUIDsByUUID removeObjectForKey:seg.uuid];

    double target = MAX(0.0, seg.start - 0.25);
    _hasPreSeekPosition = YES;
    _preSeekPosition = currentPos;
    _preSeekStamp = now;
    _hasPendingSeek = YES;
    _pendingSeekTarget = target;
    _pendingSeekDeadline = now + 2.5;
    _pendingSeekSegmentUUID = nil;
    _lastSeekStamp = now;
    _lastPosition = currentPos;
    _lastPositionStamp = now;

    NSNumber *recorded = _recordedDurationByUUID[seg.uuid];
    [_recordedDurationByUUID removeObjectForKey:seg.uuid];
    SGUndoRecordSponsorBlockSkip(recorded ? recorded.doubleValue : seg.duration);

    performSeek(target);
    if (_isPlaying && _currentSegments.count > 0) {
        [self startPolling];
    }
    if (SGSponsorBlockSubSwitchEnabled(SGKeySponsorBlockHaptics)) {
        UIImpactFeedbackGenerator *feedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [feedback impactOccurred];
    }
}

@end

NSTimeInterval SGSponsorBlockMinDuration(void) {
    NSString *val = SGString(SGKeySponsorBlockMinDuration);
    if (val.length) {
        double d = [val doubleValue];
        if (isfinite(d) && d >= 0.0 && d <= 30.0) return d;
    }
    return 0.0;
}

void SGSetSponsorBlockMinDuration(NSTimeInterval duration) {
    duration = round(MAX(0.0, MIN(30.0, duration)) * 2.0) / 2.0;
    [NSUserDefaults.standardUserDefaults setDouble:duration forKey:SGKeySponsorBlockMinDuration];
    SGPrefsChanged();
    SGSponsorBlockPreferencesDidChange();
}

NSTimeInterval SGSponsorBlockToastDuration(void) {
    NSString *val = SGString(SGKeySponsorBlockToastDuration);
    if (val.length) {
        double d = [val doubleValue];
        if (isfinite(d) && d >= 1.0 && d <= 8.0) return d;
    }
    return 3.0;
}

void SGSetSponsorBlockToastDuration(NSTimeInterval duration) {
    duration = round(MAX(1.0, MIN(8.0, duration)) * 5.0) / 5.0;
    [NSUserDefaults.standardUserDefaults setDouble:duration forKey:SGKeySponsorBlockToastDuration];
    SGPrefsChanged();
    SGSponsorBlockPreferencesDidChange();
}

NSTimeInterval SGSponsorBlockPromptDuration(void) {
    NSString *val = SGString(SGKeySponsorBlockPromptDuration);
    if (val.length) {
        double d = [val doubleValue];
        if (isfinite(d) && d >= 5.0 && d <= SGSponsorBlockPromptDurationInfinite) return d;
    }
    return SGSponsorBlockPromptDurationInfinite;
}

void SGSetSponsorBlockPromptDuration(NSTimeInterval duration) {
    duration = round(MAX(5.0, MIN(SGSponsorBlockPromptDurationInfinite, duration)) / 5.0) * 5.0;
    NSTimeInterval previous = SGSponsorBlockPromptDuration();
    [NSUserDefaults.standardUserDefaults setDouble:duration forKey:SGKeySponsorBlockPromptDuration];
    SGPrefsChanged();
    if (duration > previous) {
        [[SGSponsorBlockSkipper sharedSkipper] promptDurationSettingDidIncrease];
    }
    SGSponsorBlockPreferencesDidChange();
}

void SGSponsorBlockStart(void) {
    [[SGSponsorBlockSkipper sharedSkipper] start];
}

void SGSponsorBlockPreferencesDidChange(void) {
    [[SGSponsorBlockSkipper sharedSkipper] preferencesDidChange];
}
