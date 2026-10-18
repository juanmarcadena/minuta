import Foundation

/// Read-only queries over transcripts, shaped for an AI agent: readable IDs (the file name),
/// small pages with a cursor, and results that say how to narrow down when there are too many.
public struct TranscriptQuery: Sendable {
    public let documents: [TranscriptDocument]
    public let timeZone: TimeZone

    public init(documents: [TranscriptDocument], timeZone: TimeZone = .current) {
        self.documents = documents.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        self.timeZone = timeZone
    }

    /// Loads every `.md` in a folder.
    public static func load(folder: URL, timeZone: TimeZone = .current) -> TranscriptQuery {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let docs = files.filter { $0.pathExtension.lowercased() == "md" }.compactMap { url -> TranscriptDocument? in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            var doc = TranscriptDocument.parse(text, url: url)
            if doc.date == nil { doc.date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
            return doc
        }
        return TranscriptQuery(documents: docs, timeZone: timeZone)
    }

    // MARK: IDs and dates

    /// A meeting's ID is its file name without `.md`, e.g. "2026-10-16 1500 - Weekly sync".
    public static func id(of doc: TranscriptDocument) -> String { doc.url.deletingPathExtension().lastPathComponent }

    public func document(id: String) -> TranscriptDocument? {
        let wanted = id.hasSuffix(".md") ? String(id.dropLast(3)) : id
        return documents.first { Self.id(of: $0) == wanted }
    }

    /// Accepts "2026-10-16", "2026-10-16T15:00", or a full ISO 8601 date-time.
    /// `endOfDay` turns a bare date into the end of that day (for "to" bounds).
    public func parseDate(_ s: String, endOfDay: Bool = false) -> Date? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let parts = s.split(whereSeparator: { "-T:".contains($0) }).compactMap { Int($0) }
        guard parts.count >= 3 else { return nil }
        var c = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        if parts.count >= 5 {
            c.hour = parts[3]; c.minute = parts[4]
        } else if endOfDay {
            c.hour = 23; c.minute = 59; c.second = 59
        }
        return cal.date(from: c)
    }

    public func formatDate(_ d: Date?) -> String {
        guard let d else { return "unknown date" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "EEE yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    // MARK: List

    public struct MeetingSummary: Codable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var date: String
        public var duration_minutes: Int?
        public var app: String?
        public var attendees: [String]
        public var speakers: [String]
        public var meeting_link: String?
        public var line_count: Int
    }

    public func summary(_ d: TranscriptDocument) -> MeetingSummary {
        MeetingSummary(id: Self.id(of: d), title: d.title, date: formatDate(d.date), duration_minutes: d.durationMinutes,
                       app: d.app, attendees: d.attendees, speakers: d.speakers, meeting_link: d.meetingLink,
                       line_count: d.lines.count)
    }

    public struct Page<T: Codable & Sendable>: Codable, Sendable {
        public var items: [T]
        public var total: Int
        /// Pass back as `cursor` to get the next page; nil when there is no more.
        public var next_cursor: String?
    }

    /// Meetings newest first, filtered by date range, a word in the title or attendees, and app.
    public func listMeetings(from: Date? = nil, to: Date? = nil, query: String? = nil, app: String? = nil,
                             limit: Int = 20, cursor: String? = nil) -> Page<MeetingSummary> {
        let words = Self.words(query)
        let matches = documents.filter { d in
            if let from, let date = d.date, date < from { return false }
            if let to, let date = d.date, date > to { return false }
            if let app, !(d.app ?? "").localizedCaseInsensitiveContains(app) { return false }
            let haystack = TranscriptDocument.fold(([d.title] + d.attendees).joined(separator: " "))
            return words.allSatisfy { haystack.contains($0) }
        }
        return Self.page(matches.map(summary), limit: limit, cursor: cursor)
    }

    // MARK: Search

    public struct Hit: Codable, Equatable, Sendable {
        public var meeting_id: String
        public var meeting_title: String
        public var meeting_date: String
        public var time: String
        public var speaker: String
        public var text: String
        /// The line before and after, so the hit makes sense on its own.
        public var context_before: String?
        public var context_after: String?
    }

    /// Lines containing every word of the query (case and accents ignored), newest meeting first.
    public func search(_ query: String, from: Date? = nil, to: Date? = nil, speaker: String? = nil,
                       limit: Int = 20, cursor: String? = nil) -> Page<Hit> {
        let words = Self.words(query)
        guard !words.isEmpty else { return Page(items: [], total: 0, next_cursor: nil) }
        var hits: [Hit] = []
        for d in documents {
            if let from, let date = d.date, date < from { continue }
            if let to, let date = d.date, date > to { continue }
            for (i, line) in d.lines.enumerated() {
                if let speaker, line.speaker.caseInsensitiveCompare(speaker) != .orderedSame { continue }
                let folded = TranscriptDocument.fold(line.text)
                guard words.allSatisfy({ folded.contains($0) }) else { continue }
                hits.append(Hit(meeting_id: Self.id(of: d), meeting_title: d.title, meeting_date: formatDate(d.date),
                                time: TranscriptDocument.clock(line.time), speaker: line.speaker, text: line.text,
                                context_before: i > 0 ? "\(d.lines[i - 1].speaker): \(d.lines[i - 1].text)" : nil,
                                context_after: i + 1 < d.lines.count ? "\(d.lines[i + 1].speaker): \(d.lines[i + 1].text)" : nil))
            }
        }
        return Self.page(hits, limit: limit, cursor: cursor)
    }

    // MARK: Transcript

    public struct TranscriptText: Codable, Sendable {
        public var meeting: MeetingSummary
        public var text: String
        /// True when only part of the call fits; `next_start_time` continues it.
        public var truncated: Bool
        public var next_start_time: String?
    }

    /// The conversation as "[mm:ss] Speaker: text" lines, optionally only between two times,
    /// capped at `maxCharacters` with a pointer to where to continue.
    public func transcript(_ d: TranscriptDocument, start: Double? = nil, end: Double? = nil,
                           detailed: Bool = false, maxCharacters: Int = 24_000) -> TranscriptText {
        var out = ""
        var truncated = false
        var next: String?
        if detailed {
            out += "# \(d.title)\n\(formatDate(d.date))"
            if let m = d.durationMinutes { out += " · \(m) min" }
            if let app = d.app { out += " · \(app)" }
            out += "\n"
            if !d.attendees.isEmpty { out += "Attendees: \(d.attendees.joined(separator: ", "))\n" }
            if let link = d.meetingLink { out += "Link: \(link)\n" }
            out += "\n"
        }
        for line in d.lines {
            if let start, line.time < start { continue }
            if let end, line.time > end { break }
            let row = "[\(TranscriptDocument.clock(line.time))] \(line.speaker): \(line.text)\n"
            if out.count + row.count > maxCharacters {
                truncated = true
                next = TranscriptDocument.clock(line.time)
                break
            }
            out += row
        }
        if d.lines.isEmpty { out += "(No speech was detected in this recording.)\n" }
        return TranscriptText(meeting: summary(d), text: out, truncated: truncated, next_start_time: next)
    }

    /// "12:30", "1:02:05" or plain seconds → seconds.
    public static func parseClock(_ s: String) -> Double? {
        let parts = s.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    // MARK: Helpers

    static func words(_ query: String?) -> [String] {
        TranscriptDocument.fold(query ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
    }

    static func page<T>(_ all: [T], limit: Int, cursor: String?) -> Page<T> {
        let start = max(0, Int(cursor ?? "0") ?? 0)
        let size = min(max(limit, 1), 100)
        let slice = Array(all.dropFirst(start).prefix(size))
        let end = start + slice.count
        return Page(items: slice, total: all.count, next_cursor: end < all.count ? String(end) : nil)
    }
}
