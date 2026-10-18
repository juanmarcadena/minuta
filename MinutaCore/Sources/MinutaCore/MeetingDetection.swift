import Foundation

/// An app Minuta treats as a call app: when it uses the mic, a meeting may be starting.
public struct CallApp: Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    /// Bundle ID prefixes of the app and its helper processes (audio often runs in a helper).
    public let bundlePrefixes: [String]
    /// Text in a calendar event's URL, location or notes that marks a meeting held in this app.
    public let linkMarkers: [String]

    public func owns(bundleID: String) -> Bool {
        bundlePrefixes.contains { bundleID.hasPrefix($0) }
    }

    public static let all: [CallApp] = [
        CallApp(id: "zoom", name: "Zoom", bundlePrefixes: ["us.zoom."], linkMarkers: ["zoom.us/"]),
        CallApp(id: "teams", name: "Teams", bundlePrefixes: ["com.microsoft.teams"], linkMarkers: ["teams.microsoft.com", "teams.live.com"]),
        // Safari plays and records through shared WebKit helper processes.
        CallApp(id: "safari", name: "Safari", bundlePrefixes: ["com.apple.Safari", "com.apple.WebKit"],
                linkMarkers: ["meet.google.com", "zoom.us/", "teams.microsoft.com", "teams.live.com"]),
        CallApp(id: "chrome", name: "Chrome", bundlePrefixes: ["com.google.Chrome"],
                linkMarkers: ["meet.google.com", "zoom.us/", "teams.microsoft.com", "teams.live.com"]),
        CallApp(id: "slack", name: "Slack", bundlePrefixes: ["com.tinyspeck.slackmacgap"], linkMarkers: ["slack.com/huddle"]),
        CallApp(id: "whatsapp", name: "WhatsApp", bundlePrefixes: ["net.whatsapp.WhatsApp", "desktop.WhatsApp"], linkMarkers: []),
        CallApp(id: "facetime", name: "FaceTime", bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced"], linkMarkers: ["facetime.apple.com"]),
    ]

    public static func app(id: String) -> CallApp? { all.first { $0.id == id } }

    /// Which call app owns a bundle ID, if any, among the enabled ones.
    public static func owner(of bundleID: String, enabled: Set<String>) -> CallApp? {
        all.first { enabled.contains($0.id) && $0.owns(bundleID: bundleID) }
    }

    /// Name for the transcript when there is no calendar event: a browser call with a Meet link is "Google Meet".
    public func displayName(meetingLink: String?) -> String {
        guard id == "safari" || id == "chrome", let link = meetingLink else { return name }
        if link.contains("meet.google.com") { return "Google Meet" }
        if link.contains("zoom.us/") { return "Zoom" }
        if link.contains("teams.") { return "Teams" }
        return name
    }
}

/// Decides when a call starts and ends from which call apps are using the mic.
/// Pure and clock-driven so every rule is unit tested; the app feeds it once a second.
public struct MeetingDetector: Sendable {
    public struct Config: Sendable {
        /// Recording starts the moment a call app opens the mic, so the first words are kept.
        /// If the mic closes again within this time it was dictation or a voice note: thrown away at once.
        public var armDelay: TimeInterval = 20
        /// Mic off this long ends an automatic recording (mute in most apps keeps the mic open; leaving closes it).
        public var quietToStop: TimeInterval = 30
        /// Automatic recordings shorter than this, with no calendar event, are thrown away.
        public var minimumLength: TimeInterval = 60
        public init() {}
    }

    public enum Action: Equatable, Sendable {
        case start(appID: String)
        /// `discard`: too short to be a meeting; delete instead of transcribing.
        case stop(discard: Bool)
    }

    public enum State: Equatable, Sendable {
        case idle
        /// Recording, but not yet sure it is a call (mic open for less than `armDelay`).
        case armed(appID: String, since: Date)
        /// `appID` nil = manual recording with no call app; it only stops by hand.
        case recording(appID: String?, since: Date, automatic: Bool, quietSince: Date?)
        /// The user stopped a call by hand; don't re-arm until that app releases the mic.
        case suppressed(appID: String)
    }

    public private(set) var state: State = .idle
    public var config: Config

    public init(config: Config = Config()) {
        self.config = config
    }

    /// - Parameters:
    ///   - micApps: ids of enabled call apps using the mic right now.
    ///   - hasEvent: whether the calendar has a meeting on now that matches the app.
    public mutating func update(now: Date, micApps: Set<String>, hasEvent: (String) -> Bool) -> Action? {
        switch state {
        case .idle:
            guard let app = Self.pick(micApps) else { return nil }
            state = .armed(appID: app, since: now)
            return .start(appID: app)

        case .armed(let app, let since):
            guard micApps.contains(app) else {
                state = .idle  // the next tick re-arms if another call app holds the mic
                return .stop(discard: true)
            }
            if now.timeIntervalSince(since) >= config.armDelay {
                state = .recording(appID: app, since: since, automatic: true, quietSince: nil)
            }
            return nil

        case .recording(let app, let since, let automatic, let quietSince):
            guard let app else { return nil }  // manual with no call app
            if micApps.contains(app) {
                if quietSince != nil { state = .recording(appID: app, since: since, automatic: automatic, quietSince: nil) }
                return nil
            }
            let quiet = quietSince ?? now
            if quietSince == nil { state = .recording(appID: app, since: since, automatic: automatic, quietSince: now) }
            guard now.timeIntervalSince(quiet) >= config.quietToStop else { return nil }
            let length = quiet.timeIntervalSince(since)
            let discard = automatic && length < config.minimumLength && !hasEvent(app)
            state = .idle
            return .stop(discard: discard)

        case .suppressed(let app):
            if !micApps.contains(app) { state = .idle }
            return nil
        }
    }

    /// The user pressed Start. `appID` is the call app using the mic now, if any.
    public mutating func manualStart(appID: String?, now: Date) {
        state = .recording(appID: appID, since: now, automatic: false, quietSince: nil)
    }

    /// The user pressed Stop. Never discards.
    public mutating func manualStop(micApps: Set<String>) {
        switch state {
        case .recording(let app?, _, _, _) where micApps.contains(app), .armed(let app, _) where micApps.contains(app):
            state = .suppressed(appID: app)
        default:
            state = .idle
        }
    }

    /// Stable choice when several call apps use the mic: catalog order.
    public static func pick(_ apps: Set<String>) -> String? {
        CallApp.all.first { apps.contains($0.id) }?.id
    }
}
