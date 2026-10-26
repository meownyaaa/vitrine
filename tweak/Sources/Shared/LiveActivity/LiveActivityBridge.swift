// ActivityKit is Swift only, so LiveActivity.x reaches it through this class.
import ActivityKit
import Foundation
import os
import UIKit

@available(iOS 17.0, *)
@objc(SGLiveActivityBridge)
public final class SGLiveActivityBridge: NSObject {
    private static let log = Logger(subsystem: "spotifyglass", category: "live activity")
    // Under ActivityKit's 4096, with room for its own wrapping.
    private static let maxStateBytes = 3800
    // Each state is stale this long after it is sent: three times LiveActivity.x's kRefresh, which sends
    // even an unchanged card again, so only a card Spotify can no longer feed goes stale.
    private static let staleAfter: TimeInterval = 60

    private typealias State = SGLyricsAttributes.ContentState

    // Either type's activities: one left from before an update to iOS 18 carries on under its own.
    private static func live<A>(_ activities: [Activity<A>]) -> [String] {
        activities.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.id)
    }

    // Ended by end() but maybe not yet by ActivityKit, which goes one change at a time: not showing from the call on,
    // so a fresh one can be asked for at once.
    private static let ending = OSAllocatedUnfairLock(initialState: Set<String>())

    private static var showing: [String] {
        let gone = ending.withLock { $0 }
        return (live(Activity<SGLyricsAttributes>.activities) + live(Activity<SGLyricsWatchAttributes>.activities))
            .filter { !gone.contains($0) }
    }

    @objc public static var isShowing: Bool { !showing.isEmpty }

    // When the one showing was asked for, kept across launches so one kept from a launch in the background is aged
    // too. Nil when unknown.
    private static let startedKey = "spotifyglass.liveActivity.startedAt"
    @objc public static var startedAt: Date? {
        guard let id = showing.first, let stored = UserDefaults.standard.dictionary(forKey: startedKey),
              stored["id"] as? String == id else { return nil }
        return stored["at"] as? Date
    }

    @objc public static var canStart: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    // show() and end() are called on main (LiveActivity.x), so the sender never waits for it.
    private static var inBackground: Bool {
        MainActor.assumeIsolated { UIApplication.shared.applicationState == .background }
    }

    // Updates and ends go out one at a time in the order asked for, since ActivityKit applies
    // concurrent ones in whatever order they finish. An update still waiting gives way to a newer one.
    private enum Change: Sendable {
        case update(String, ActivityContent<State>, background: Bool)
        case end([String], background: Bool)
    }

    private struct Pending: Sendable {
        var changes: [Change] = []
        var sending = false
        // When the change being sent went out. One ActivityKit never answers would otherwise hold every
        // later change behind it and freeze the card; past kStuckAfter a new sender takes over.
        var sentAt: Date?
        // Changes taken to send so far, so a second try can tell another sender has gone since.
        var taken = 0
    }

    private static let kStuckAfter: TimeInterval = 5

    private static let pending = OSAllocatedUnfairLock(initialState: Pending())

    private static func queue(_ change: Change) {
        let start = pending.withLock { pending in
            if case .update(let id, _, _) = change, case .update(let waiting, _, _)? = pending.changes.last, waiting == id {
                pending.changes.removeLast()
            }
            pending.changes.append(change)
            if pending.sending, let at = pending.sentAt, Date().timeIntervalSince(at) < kStuckAfter { return false }
            if pending.sending { log.notice("[spotifyglass] live activity: an update has not landed in \(kStuckAfter, privacy: .public) s, sending on past it") }
            pending.sending = true
            // Set now, not when send() takes its first change: a nil here reads as stuck to the next call.
            pending.sentAt = Date()
            return true
        }
        if start { Task { await send() } }
    }

    // In the background, iOS lets a process update its activity only while it does more than play audio
    // (liveactivitiesd: "Process is only playing background media so is forbidden to update activity"),
    // and ActivityKit drops a refused update without a word. A background task is that something more. Begun and
    // ended off the main thread (UIKit allows both there), so a busy main thread cannot hold a send up; ended once.
    private final class BackgroundTask: @unchecked Sendable {
        private let id = OSAllocatedUnfairLock(initialState: UIBackgroundTaskIdentifier.invalid)

        init() {
            let begun = UIApplication.shared.beginBackgroundTask(withName: "live activity") { [weak self] in self?.end() }
            id.withLock { $0 = begun }
        }

        func end() {
            let ending = id.withLock { id -> UIBackgroundTaskIdentifier in
                defer { id = .invalid }
                return id
            }
            if ending != .invalid { UIApplication.shared.endBackgroundTask(ending) }
        }
    }

    private static func update(_ id: String, _ content: ActivityContent<State>) async {
        await Activity<SGLyricsAttributes>.activities.first { $0.id == id }?.update(content)
        await Activity<SGLyricsWatchAttributes>.activities.first { $0.id == id }?.update(content)
    }

    private static func end(_ ids: [String]) async {
        for activity in Activity<SGLyricsAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for activity in Activity<SGLyricsWatchAttributes>.activities where ids.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    // iOS grants the background task asynchronously, so a change sent just after it begins can still be refused
    // without a word (4 of 53 updates on the phone, each fine a second later). True once a second has gone by with
    // nothing newer queued and no other sender at work; checked in steps, so a newer change is not held up.
    private static func quietForASecond(since taken: Int) async -> Bool {
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 100_000_000)
            let quiet = pending.withLock { pending -> Bool in
                guard pending.changes.isEmpty, pending.taken == taken else { return false }
                pending.sentAt = Date()
                return true
            }
            if !quiet { return false }
        }
        return true
    }

    // The last state sent, to tell which updates are worth the second copy.
    private static let lastSent = OSAllocatedUnfairLock<State?>(initialState: nil)

    // A dropped line is replaced by the next line or kRefresh's resend within seconds, and an unchanged state
    // was already sent, so only a change to the track, controls or timer gets the second copy.
    private static func onlyLinesChanged(_ state: State) -> Bool {
        lastSent.withLock { last in
            defer { last = state }
            guard var before = last else { return false }
            before.line = state.line
            before.nextLine = state.nextLine
            before.translation = state.translation
            return before == state
        }
    }

    private static func send() async {
        // One task over the whole run of queued changes, so none of them goes out without it.
        let task = BackgroundTask()
        defer { task.end() }
        while let (change, taken) = pending.withLock({ pending -> (Change, Int)? in
            if pending.changes.isEmpty {
                pending.sending = false
                pending.sentAt = nil
                return nil
            }
            pending.sentAt = Date()
            pending.taken += 1
            return (pending.changes.removeFirst(), pending.taken)
        }) {
            switch change {
            case .update(let id, let content, let background):
                let again = !onlyLinesChanged(content.state) && background
                await update(id, content)
                if again, await quietForASecond(since: taken) { await update(id, content) }
            case .end(let ids, let background):
                await end(ids)
                // Rare, and ending one already ended does nothing: a second later it goes again whatever came since.
                if background {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await end(ids)
                }
            }
        }
    }

    // A new activity can only be requested while the app is in the foreground; an update works from the background.
    // One call per new state. View and tab are SGLiveActivityView's and SGLiveActivityTab's values;
    // titles, artists and URIs pair up by index, the tracks up next; timerEnd is nil without a timer.
    @objc public static func show(view: Int, paused: Bool, line: String, nextLine: String,
                                  titles: [String], artists: [String], uris: [String],
                                  tab: Int, title: String, artist: String, shuffle: Bool, repeatMode: Int,
                                  timerEnd: Date?, timerEndOfTrack: Bool, timerEndOfAlbum: Bool,
                                  tint: String?, trackStart: Date?, trackEnd: Date?, pausedAt: NSNumber?, translation: String?,
                                  cover: Data?, textSize: Int, alignment: Int, noLyrics: Bool, withoutLyrics: Int,
                                  colors: Int, accent: String?, progressBar: Bool) {
        let tracks = titles.indices.map {
            SGLyricsAttributes.Track(title: titles[$0], artist: artists[$0], uri: uris[$0])
        }
        var state = SGLyricsAttributes.ContentState(
            view: SGLyricsAttributes.View(rawValue: view) ?? .lyrics, paused: paused,
            line: line, nextLine: nextLine, tracks: tracks,
            tab: SGLyricsAttributes.Tab(rawValue: tab) ?? .controls, title: title, artist: artist,
            shuffle: shuffle, repeatMode: repeatMode, timerEnd: timerEnd, timerEndOfTrack: timerEndOfTrack,
            tint: tint, trackStart: trackStart, trackEnd: trackEnd, pausedAt: pausedAt?.doubleValue,
            translation: translation, cover: cover, textSize: textSize, timerEndOfAlbum: timerEndOfAlbum,
            alignment: alignment, noLyrics: noLyrics, withoutLyrics: withoutLyrics, colors: colors, accent: accent,
            progressBar: progressBar)
        // ActivityKit drops a state over 4 KB without a word and the card freezes, so with long lines and
        // a busy cover the cover gives way.
        if cover != nil, let size = try? JSONEncoder().encode(state).count, size > maxStateBytes {
            state.cover = nil
            log.notice("[spotifyglass] live activity: \(size, privacy: .public) bytes, sent without the cover")
        }
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: staleAfter))
        if let id = showing.first {
            queue(.update(id, content, background: inBackground))
            return
        }
        guard canStart else {
            log.notice("[spotifyglass] live activity: activities are off for this app")
            return
        }
        do {
            let id: String
            if #available(iOS 18.0, *) {
                id = try Activity.request(attributes: SGLyricsWatchAttributes(), content: content, pushType: nil).id
            } else {
                id = try Activity.request(attributes: SGLyricsAttributes(), content: content, pushType: nil).id
            }
            UserDefaults.standard.set(["id": id, "at": Date()], forKey: startedKey)
            log.notice("[spotifyglass] live activity: started \(id, privacy: .public)")
        } catch {
            log.error("[spotifyglass] live activity: request failed: \(String(describing: error), privacy: .public)")
        }
    }

    // Named now, so an activity requested after this call is not ended with them.
    @objc public static func end() {
        let ids = Activity<SGLyricsAttributes>.activities.map(\.id) + Activity<SGLyricsWatchAttributes>.activities.map(\.id)
        ending.withLock { $0.formUnion(ids) }
        queue(.end(ids, background: inBackground))
    }

    // At termination: ends them all, past the queue, and holds the calling thread until they are ended,
    // two seconds at most, since the process is gone once the notification returns and an end still in
    // flight goes with it. The cap also keeps an ActivityKit that waits on the main thread from hanging it.
    @objc public static func endBeforeExit() {
        // Not `showing`: one end() has named may not be ended yet.
        if (live(Activity<SGLyricsAttributes>.activities) + live(Activity<SGLyricsWatchAttributes>.activities)).isEmpty { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in Activity<SGLyricsAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            for activity in Activity<SGLyricsWatchAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            log.notice("[spotifyglass] live activity: not ended in time at exit")
        }
    }
}
