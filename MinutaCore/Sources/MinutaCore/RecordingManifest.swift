import Foundation

/// `meeting.json` next to the audio tracks of one recording. Written at start, updated at stop,
/// so a crash still leaves enough to transcribe what was captured.
public struct RecordingManifest: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        /// File name inside the recording folder, e.g. `me.caf`.
        public var file: String
        /// Host time (seconds, `AudioConvertHostTimeToNanos` / 1e9) of the first sample, to align tracks.
        public var firstSampleHostSeconds: Double?
        /// Loudest sample (0…1). Near zero for a whole call means no audio reached the track.
        public var peak: Double?
        public init(file: String, firstSampleHostSeconds: Double? = nil, peak: Double? = nil) {
            self.file = file
            self.firstSampleHostSeconds = firstSampleHostSeconds
            self.peak = peak
        }
    }

    public var id: UUID
    public var startedAt: Date
    public var endedAt: Date?
    /// Display name of the app the call was in ("Zoom", "Google Meet", "Manual").
    public var app: String
    public var bundleID: String?
    /// `CallApp.id` of the app that triggered the recording, if any.
    public var appID: String?
    /// From the matching calendar event, when there is one.
    public var title: String?
    public var attendees: [String]?
    public var meetingLink: String?
    public var me: Track
    public var them: Track

    public init(id: UUID = UUID(), startedAt: Date, app: String, bundleID: String? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.app = app
        self.bundleID = bundleID
        self.me = Track(file: "me.caf")
        self.them = Track(file: "them.caf")
    }

    /// Seconds to add to `them` timestamps to put them on `me`'s timeline (nil until both tracks got audio).
    public var themOffsetFromMe: Double? {
        guard let m = me.firstSampleHostSeconds, let t = them.firstSampleHostSeconds else { return nil }
        return t - m
    }

    /// Title for the transcript: the calendar event, else "Zoom call", "Google Meet", "Recording".
    public var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty { return title }
        if app == "Manual" { return "Recording" }
        if app == "Google Meet" { return app }
        return "\(app) call"
    }

    /// True when the other side's track stayed silent: usually System Audio Recording is off.
    public func themLooksSilent(duration: Double) -> Bool {
        guard let peak = them.peak else { return false }
        return duration >= 30 && peak < 0.003
    }

    public static let fileName = "meeting.json"

    public func write(to folder: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: folder.appending(path: Self.fileName), options: .atomic)
    }

    public static func read(from folder: URL) throws -> RecordingManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(Self.self, from: Data(contentsOf: folder.appending(path: fileName)))
    }
}

/// Keeps a track's timeline true to the clock: when audio stops arriving for a while
/// (a device switch, a stalled stream), the gap is filled with silence so later words keep
/// their real timestamps and the two tracks stay aligned.
public enum TimelineGap {
    /// Seconds of silence to insert before a buffer that starts `elapsed` seconds after the
    /// track's first sample, when `written` seconds are already on disk.
    public static func silence(elapsed: Double, written: Double, threshold: Double = 0.25) -> Double {
        let gap = elapsed - written
        return gap > threshold ? gap : 0
    }
}
