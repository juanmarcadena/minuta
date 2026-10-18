import Foundation

/// A transcript read back from its `.md` file (the format `TranscriptMarkdown` writes).
public struct TranscriptDocument: Hashable, Sendable, Identifiable {
    public struct Line: Hashable, Sendable, Identifiable {
        public var id: Int
        /// Seconds from the start of the recording.
        public var time: Double
        /// "Me", "Them", "Them 2"…
        public var speaker: String
        public var text: String
        public var isMe: Bool { speaker == "Me" }
    }

    public var url: URL
    public var title: String
    public var date: Date?
    public var durationMinutes: Int?
    public var app: String?
    public var languages: [String]
    public var attendees: [String]
    public var meetingLink: String?
    public var lines: [Line]

    public var id: URL { url }

    /// Distinct speakers in order of first appearance.
    public var speakers: [String] {
        var seen: [String] = []
        for l in lines where !seen.contains(l.speaker) { seen.append(l.speaker) }
        return seen
    }

    /// Everything a search should match, folded for case and accents.
    public var searchableText: String {
        Self.fold(([title] + attendees + lines.map(\.text)).joined(separator: "\n"))
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// Plain text for the clipboard: "Me (00:03): …".
    public var plainText: String {
        var out = [title]
        if let date { out.append(date.formatted(date: .long, time: .shortened)) }
        if !attendees.isEmpty { out.append("With: " + attendees.joined(separator: ", ")) }
        out.append("")
        out += lines.map { "\($0.speaker) (\(Self.clock($0.time))): \($0.text)" }
        return out.joined(separator: "\n")
    }

    public static func clock(_ t: Double) -> String {
        let s = Int(t)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Parsing

    public static func parse(_ markdown: String, url: URL) -> TranscriptDocument {
        var front: [String: String] = [:]
        var body = Substring(markdown)
        if markdown.hasPrefix("---\n"), let end = markdown.range(of: "\n---\n", range: markdown.index(markdown.startIndex, offsetBy: 4)..<markdown.endIndex) {
            for line in markdown[markdown.index(markdown.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if let hash = value.range(of: "  #") { value = String(value[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
                front[key] = unquote(value)
            }
            body = markdown[end.upperBound...]
        }

        var lines: [Line] = []
        let pattern = /^\*\*\[(\d{2}):(\d{2}):(\d{2})\] ([^:*]+):\*\* (.*)$/
        for raw in body.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let m = try? pattern.firstMatch(in: String(raw)) else { continue }
            let t = Double(m.1)! * 3600 + Double(m.2)! * 60 + Double(m.3)!
            lines.append(Line(id: lines.count, time: t, speaker: String(m.4), text: String(m.5)))
        }

        let iso = ISO8601DateFormatter()
        return TranscriptDocument(
            url: url,
            title: front["title"] ?? url.deletingPathExtension().lastPathComponent,
            date: front["date"].flatMap { iso.date(from: $0) },
            durationMinutes: front["duration"].flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "m"))) },
            app: front["app"],
            languages: list(front["languages"]),
            attendees: list(front["attendees"]),
            meetingLink: front["meeting_link"],
            lines: lines)
    }

    static func unquote(_ s: String) -> String {
        guard s.count >= 2, s.hasPrefix("\""), s.hasSuffix("\"") else { return s }
        return String(s.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
    }

    static func list(_ s: String?) -> [String] {
        guard var s, s.hasPrefix("["), s.hasSuffix("]") else { return [] }
        s = String(s.dropFirst().dropLast())
        // Split on commas outside quotes.
        var items: [String] = [], current = "", quoted = false
        for c in s {
            if c == "\"" { quoted.toggle(); current.append(c) }
            else if c == ",", !quoted { items.append(current); current = "" }
            else { current.append(c) }
        }
        items.append(current)
        return items.map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }
}
