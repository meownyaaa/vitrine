// Compiled into both the tweak and extension/LiveActivity: ActivityKit pairs the two sides by the
// attributes' type name and App Intents by the intent's, so this must stay identical in both.
import ActivityKit
import AppIntents
import Foundation

@available(iOS 16.1, *)
struct SGLyricsAttributes: ActivityAttributes {
    // Which of the three the activity shows, SGLiveActivityView's values.
    enum View: Int, Codable, Hashable {
        case lyrics, queue, panel
    }

    // The control menu's tabs.
    enum Tab: Int, Codable, Hashable, CaseIterable {
        case controls, queue, timer
    }

    struct Track: Codable, Hashable {
        var title: String
        var artist: String
        // What a tap on the track asks the player for.
        var uri: String
    }

    struct ContentState: Codable, Hashable {
        var view: View
        var paused: Bool
        // Lyrics: the line being sung and the one after it.
        var line: String
        var nextLine: String
        // Queue, and the control menu's queue tab: the tracks up next.
        var tracks: [Track]
        // The control menu.
        var tab: Tab
        var title: String
        var artist: String
        var shuffle: Bool
        var repeatMode: Int   // 0 off, 1 the playlist or album, 2 the track
        var timerEnd: Date?   // the sleep timer's end, nil when none is set
        var timerEndOfTrack: Bool
        // The cover's color as RRGGBB, darkened for white text; nil before it is read.
        var tint: String?
        // When the track started and ends at the speed it plays, for a progress bar that runs by itself;
        // nil when the length is not known. Paused, the bar holds at `pausedAt`.
        var trackStart: Date?
        var trackEnd: Date?
        var pausedAt: Double?
        // The line's translation, when the lyrics have one and translations are shown.
        var translation: String?
        // The cover as a JPEG of a few dozen pixels a side, nil before it is read or when it does not fit.
        // Optional, as everything added later is, so an activity left by the build before still decodes.
        var cover: Data?
        // The lyrics' size, SGLiveActivityTextSize's values: 0 small, 1 medium, 2 large.
        var textSize: Int?
        // The sleep timer pauses at the end of the album or playlist playing.
        var timerEndOfAlbum: Bool?
        // The page's options (LiveActivity.h), nil in a state from a build before them, which reads as each
        // one's default. The lyric lines' alignment, SGLiveActivityAlignment's values: 0 left, 1 center.
        var alignment: Int?
        // The track has no lyrics with a time on them, so the lyrics view has no line to show for all of it,
        // and what it shows then, SGLiveActivityWithoutLyrics's values: 0 a note under the track, 1 the track large.
        var noLyrics: Bool?
        var withoutLyrics: Int?
        // The card's colors, SGLiveActivityColors's values: 0 Spotify's (the cover's color, darkened, behind
        // green), 1 the cover's (the same behind `accent`, the cover's color lightened, RRGGBB), 2 white on the
        // system's own background.
        var colors: Int?
        var accent: String?
        // The track's progress bar; nil or true shows it.
        var progressBar: Bool?
    }
}

// The same activity under a second name. Apple Watch and CarPlay show an activity's own small layout
// only when its widget declares that family, which only an iOS 18 widget can, and a widget built for
// iOS 17 still has to cover the old type. So from iOS 18 the tweak asks for this one, and the iOS 18
// widget is the one that answers it.
@available(iOS 16.1, *)
struct SGLyricsWatchAttributes: ActivityAttributes {
    typealias ContentState = SGLyricsAttributes.ContentState
}

// LiveActivityIntents run in the app's process, where the tweak acts on these notifications.
let SGLiveActivityPlayNotification = Notification.Name("SGLiveActivityPlay")
let SGLiveActivityActionNotification = Notification.Name("SGLiveActivityAction")

@available(iOS 17.0, *)
struct SGPlayQueuedTrackIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Play a track up next"
    static let isDiscoverable = false

    @Parameter(title: "Track")
    var uri: String

    init() {}

    init(_ uri: String) {
        self.uri = uri
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityPlayNotification, object: uri)
        return .result()
    }
}

// A control menu action: tab:N, toggle, previous, next, shuffle, repeat, timer:15|30|60|track|album|add|cancel.
@available(iOS 17.0, *)
struct SGLiveActivityActionIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Control menu action"
    static let isDiscoverable = false

    @Parameter(title: "Action")
    var action: String

    init() {}

    init(_ action: String) {
        self.action = action
    }

    func perform() async throws -> some IntentResult {
        NotificationCenter.default.post(name: SGLiveActivityActionNotification, object: action)
        return .result()
    }
}

// The shortcuts: Siri, the Shortcuts app and the Action button run these, as do the controls in Control
// Center and on the lock screen (extension/LiveActivity). A LiveActivityIntent or an AudioPlaybackIntent
// is performed in the app's process wherever it is run from, so each lands in Spotify, launched in the
// background when it is not running, where LiveActivity.x acts on SGShortcutNotification. Its observer
// runs on the main thread inside the post and writes what it did into the reply: "said", a line for Siri,
// or "failed", why it could not. No answer at all means Spotify's player is not up yet, which a launch in
// the background takes a moment for, so the intent asks again.
let SGShortcutNotification = Notification.Name("SGShortcut")

@available(iOS 16.0, *)
struct SGShortcutError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

// What Spotify answered `action` with: one of SGLiveActivityActionIntent's actions, like, or sing:MODE.
@MainActor
@available(iOS 16.0, *)
private func askSpotify(_ action: String) async throws -> String {
    // ponytail: 8 s of asking, untimed on a phone; raise it if a launch in the background takes longer.
    for _ in 0..<32 {
        let reply = NSMutableDictionary()
        NotificationCenter.default.post(name: SGShortcutNotification, object: action, userInfo: ["reply": reply])
        if let failed = reply["failed"] as? String { throw SGShortcutError(message: failed) }
        if let said = reply["said"] as? String { return said }
        try await Task.sleep(nanoseconds: 250_000_000)
    }
    throw SGShortcutError(message: "Spotify isn't ready yet. Open it and try again.")
}

@available(iOS 16.0, *)
enum SGSleepTimerLength: String, AppEnum {
    // The raw values are the timer action's, timer:VALUE.
    case fifteen = "15", thirty = "30", hour = "60", endOfTrack = "track", endOfAlbum = "album", off = "cancel"

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Timer"
    static let caseDisplayRepresentations: [SGSleepTimerLength: DisplayRepresentation] = [
        .fifteen: "15 Minutes",
        .thirty: "30 Minutes",
        .hour: "1 Hour",
        .endOfTrack: "End of Track",
        .endOfAlbum: "End of Album",
        .off: "Off",
    ]
}

@available(iOS 16.0, *)
enum SGSingMode: String, AppEnum {
    case toggle, on, off

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Karaoke"
    static let caseDisplayRepresentations: [SGSingMode: DisplayRepresentation] = [
        .toggle: "Toggle",
        .on: "Turn On",
        .off: "Turn Off",
    ]
}

@available(iOS 17.0, *)
struct SGLikeIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Like This Song"
    static let description = IntentDescription("Adds the song playing in Spotify to Liked Songs.")

    init() {}

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await askSpotify("like"))")
    }
}

@available(iOS 17.0, *)
struct SGPlayPauseIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Pauses Spotify, or plays it when it is paused.")

    init() {}

    func perform() async throws -> some IntentResult {
        _ = try await askSpotify("toggle")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SGNextTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Next Track"
    static let description = IntentDescription("Skips to the next track in Spotify.")

    init() {}

    func perform() async throws -> some IntentResult {
        _ = try await askSpotify("next")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SGPreviousTrackIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Previous Track"
    static let description = IntentDescription("Goes back a track in Spotify, or to the start of this one.")

    init() {}

    func perform() async throws -> some IntentResult {
        _ = try await askSpotify("previous")
        return .result()
    }
}

@available(iOS 17.0, *)
struct SGSingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Karaoke"
    static let description = IntentDescription("Turns the vocals down in Spotify so you can sing along, or brings them back.")

    @Parameter(title: "Karaoke", default: .toggle)
    var mode: SGSingMode

    init() {}

    init(_ mode: SGSingMode) {
        self.mode = mode
    }

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$mode) Karaoke")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await askSpotify("sing:\(mode.rawValue)"))")
    }
}

@available(iOS 17.0, *)
struct SGSleepTimerIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sleep Timer"
    static let description = IntentDescription("Pauses Spotify after a while or at the end of the track or the album, or turns the timer off.")

    @Parameter(title: "Length")
    var length: SGSleepTimerLength

    init() {}

    init(_ length: SGSleepTimerLength) {
        self.length = length
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Set the sleep timer to \(\.$length)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(try await askSpotify("timer:\(length.rawValue)"))")
    }
}
