import Foundation

/// Renders the final `.md` file: YAML front matter, a heading, then one line per utterance.
public enum TranscriptMarkdown {
    public struct Meta: Sendable {
        public var title: String
        public var startedAt: Date
        public var duration: Double
        public var app: String
        public var attendees: [String]
        public var meetingLink: String?
        public init(title: String, startedAt: Date, duration: Double, app: String, attendees: [String] = [], meetingLink: String? = nil) {
            self.title = title
            self.startedAt = startedAt
            self.duration = duration
            self.app = app
            self.attendees = attendees
            self.meetingLink = meetingLink
        }
    }

    public static func render(_ utterances: [Utterance], meta: Meta, timeZone: TimeZone = TranscriptNaming.timeZone) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = timeZone
        iso.formatOptions = [.withInternetDateTime]
        let languages = Array(Set(utterances.compactMap(\.language))).sorted()

        var lines = ["---"]
        lines.append("date: \(iso.string(from: meta.startedAt))")
        lines.append("duration: \(Int((meta.duration / 60).rounded()))m")
        lines.append("app: \(yaml(meta.app))")
        lines.append("title: \(yaml(meta.title))")
        if !languages.isEmpty { lines.append("languages: [\(languages.joined(separator: ", "))]") }
        if !meta.attendees.isEmpty { lines.append("attendees: [\(meta.attendees.map(yaml).joined(separator: ", "))]") }
        if let link = meta.meetingLink { lines.append("meeting_link: \(yaml(link))") }
        lines.append("---")
        lines.append("")
        lines.append("# \(meta.title) — \(heading(meta.startedAt, timeZone: timeZone))")
        lines.append("")
        if utterances.isEmpty {
            lines.append("_No speech was detected in this recording._")
        }
        for u in utterances {
            lines.append("**[\(stamp(u.start))] \(label(u.speaker)):** \(u.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    public static func label(_ s: Speaker) -> String {
        switch s {
        case .me: "Me"
        case .them(nil): "Them"
        case .them(let n?): "Them \(n)"
        }
    }

    static func stamp(_ t: Double) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func heading(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    static func yaml(_ s: String) -> String {
        let needsQuotes = s.contains(where: { ":#[]{},&*!|>'\"%@`".contains($0) }) || s.hasPrefix(" ") || s.hasSuffix(" ")
        return needsQuotes ? "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" : s
    }
}
