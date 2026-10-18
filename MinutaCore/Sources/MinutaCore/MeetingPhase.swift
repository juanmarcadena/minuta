import Foundation

/// Where Minuta is in a meeting's life. Hardware-free so the transitions can be unit tested.
public enum MeetingPhase: Equatable, Sendable {
    case idle
    /// A meeting app opened the mic; waiting to be sure it is a call.
    case armed(app: String, since: Date)
    case recording(app: String, since: Date)
    /// Mic went quiet or Stop was pressed; waiting before closing the recording.
    case finishing(app: String, since: Date)
    case transcribing(pending: Int)

    public var isRecording: Bool {
        if case .recording = self { return true }
        return false
    }

    /// One line for the top of the menu.
    public func statusLine(now: Date = .now) -> String {
        switch self {
        case .idle:
            return "Idle"
        case .armed(let app, _):
            return "\(app) is using the mic…"
        case .recording(let app, let since):
            return "Recording \(app) — \(Self.clock(now.timeIntervalSince(since)))"
        case .finishing(let app, _):
            return "Finishing \(app) recording…"
        case .transcribing(let pending):
            return pending == 1 ? "Transcribing 1 meeting" : "Transcribing \(pending) meetings"
        }
    }

    public static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        let (h, m, r) = (s / 3600, (s % 3600) / 60, s % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }
}
