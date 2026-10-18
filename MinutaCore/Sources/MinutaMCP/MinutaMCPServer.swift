// A read-only MCP server (stdio) over Minuta's call transcripts.
//
// Tools follow Anthropic's "Writing effective tools for agents": few, task-shaped tools;
// readable IDs (the file name); concise vs detailed output; small pages with a cursor;
// errors that say how to fix the call. Nothing is written and nothing leaves the Mac.
import Foundation
import MCP
import MinutaCore

public enum MinutaMCPServer {
    // MARK: - Where the transcripts are

    /// MINUTA_TRANSCRIPTS or --folder win; otherwise the folder set in Minuta's settings
    /// (read from the enclosing Minuta.app's preferences), else the default folder.
    static func transcriptsFolder() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--folder"), i + 1 < args.count { return URL(filePath: args[i + 1]) }
        if let env = ProcessInfo.processInfo.environment["MINUTA_TRANSCRIPTS"], !env.isEmpty { return URL(filePath: env) }
        var dir = URL(filePath: args[0]).resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.path != "/" {
            if dir.pathExtension == "app", let id = Bundle(url: dir)?.bundleIdentifier {
                if let saved = savedFolder(appID: id) { return saved }
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL.documentsDirectory.appending(path: "Minuta Transcripts", directoryHint: .isDirectory)
    }

    /// Reads Minuta's "transcriptsFolder" setting straight from the app's preferences domain.
    /// (The helper has its own bundle identity, so UserDefaults.standard would be the wrong domain.)
    static func savedFolder(appID: String) -> URL? {
        guard let value = CFPreferencesCopyAppValue("transcriptsFolder" as CFString, appID as CFString) else { return nil }
        if let path = value as? String { return URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
        if let data = value as? Data,
           let url = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) as URL? { return url }
        return nil
    }

    static let folder = transcriptsFolder()
    static func load() -> TranscriptQuery { TranscriptQuery.load(folder: folder) }

    // MARK: - Tool definitions

    static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ])
    }

    static func prop(_ type: String, _ description: String, extra: [String: Value] = [:]) -> Value {
        .object(["type": .string(type), "description": .string(description)].merging(extra) { a, _ in a })
    }

    static let dateHelp = "Local date \"YYYY-MM-DD\" or date-time \"YYYY-MM-DDTHH:MM\"."
    static let pageProps: [String: Value] = [
        "limit": prop("integer", "Page size, 1–100. Default 20.", extra: ["minimum": .int(1), "maximum": .int(100)]),
        "cursor": prop("string", "next_cursor from a previous call, to get the next page."),
    ]
    static let readOnly = Tool.Annotations(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    static let tools: [Tool] = [
        Tool(
            name: "minuta_list_meetings",
            title: "List recorded meetings",
            description: """
            Lists calls Minuta has transcribed, newest first. Use it to find a meeting's id before reading it, \
            or to answer "what calls did I have this week / with Dana / on Zoom".
            Each meeting has: id (pass to minuta_get_transcript), title (calendar event title, or e.g. "Zoom call"), \
            local date and time, duration, app, attendees from the calendar, and the speakers in the transcript \
            ("Me" is the user; "Them", "Them 1", "Them 2" are other people, not yet matched to names).
            Filters combine: from/to dates, query (words that must all appear in the title or attendee names; \
            accents and case ignored), app ("Zoom", "Google Meet", "Teams", "Safari", "WhatsApp"…).
            """,
            inputSchema: schema([
                "from": prop("string", "Only meetings on or after this. " + dateHelp),
                "to": prop("string", "Only meetings on or before this (a bare date includes the whole day). " + dateHelp),
                "query": prop("string", "Words to match in title or attendees, e.g. \"pricing\" or \"dana\"."),
                "app": prop("string", "Call app name, partial match."),
                "response_format": prop("string", "\"concise\" (default: one line per meeting) or \"detailed\" (adds attendees, speakers, link).",
                                        extra: ["enum": .array([.string("concise"), .string("detailed")])]),
            ].merging(pageProps) { a, _ in a }),
            annotations: readOnly
        ),
        Tool(
            name: "minuta_search_transcripts",
            title: "Search what was said",
            description: """
            Finds lines in call transcripts that contain every word of the query (accents and case ignored), \
            newest meeting first, with the line before and after for context. Use it for "where did we talk about X", \
            "what did they say about pricing", "when did I promise Y".
            Transcripts are mostly Spanish and English, sometimes mixed; search in the language the words were \
            likely said, or try both (e.g. "precio" and "price"). Speech-to-text can misspell names: if a name finds \
            nothing, try a shorter part of it or a related word. Prefer several small searches over one long query.
            Then use minuta_get_transcript with the meeting_id and a time range around a hit to read more.
            """,
            inputSchema: schema([
                "query": prop("string", "Words that must all appear in the line, e.g. \"precio minuto\"."),
                "from": prop("string", "Only meetings on or after this. " + dateHelp),
                "to": prop("string", "Only meetings on or before this. " + dateHelp),
                "speaker": prop("string", "Only lines by this speaker: \"Me\", \"Them\", \"Them 1\"…"),
            ].merging(pageProps) { a, _ in a }, required: ["query"]),
            annotations: readOnly
        ),
        Tool(
            name: "minuta_get_transcript",
            title: "Read a meeting transcript",
            description: """
            Returns one call's transcript as "[mm:ss] Speaker: text" lines. "Me" is the user; "Them"/"Them N" \
            are the other people (match them to attendees from context when it's clear, and say when it's a guess).
            For long calls, read a part with start_time/end_time (e.g. around a search hit); if the result is \
            truncated, call again with start_time = next_start_time. Use response_format "detailed" to also get \
            title, date, duration, app, attendees and the meeting link.
            Speech-to-text errors happen, especially in names, numbers and amounts: quote them as approximate.
            """,
            inputSchema: schema([
                "meeting_id": prop("string", "The id from minuta_list_meetings or minuta_search_transcripts, e.g. \"2026-10-16 1500 - Weekly sync\"."),
                "start_time": prop("string", "Start at this point of the call, \"mm:ss\" or \"h:mm:ss\". Default: beginning."),
                "end_time": prop("string", "Stop at this point of the call. Default: end."),
                "response_format": prop("string", "\"concise\" (default) or \"detailed\" (adds the meeting header).",
                                        extra: ["enum": .array([.string("concise"), .string("detailed")])]),
            ], required: ["meeting_id"]),
            annotations: readOnly
        ),
    ]

    // MARK: - Handlers

    static func structured<T: Encodable>(_ value: T) -> Value? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    static func fail(_ message: String) -> CallTool.Result {
        .init(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    static func ok<T: Encodable>(_ text: String, _ data: T) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], structuredContent: structured(data), isError: false)
    }

    static func today(_ q: TranscriptQuery) -> String {
        "Today is \(q.formatDate(.now).prefix(14))."
    }

    static func dates(_ a: [String: Value], _ q: TranscriptQuery) -> (Date?, Date?, String?) {
        var from: Date?, to: Date?
        if let s = a["from"]?.stringValue {
            guard let d = q.parseDate(s) else { return (nil, nil, "Couldn't read from=\"\(s)\". \(dateHelp) \(today(q))") }
            from = d
        }
        if let s = a["to"]?.stringValue {
            guard let d = q.parseDate(s, endOfDay: true) else { return (nil, nil, "Couldn't read to=\"\(s)\". \(dateHelp) \(today(q))") }
            to = d
        }
        return (from, to, nil)
    }

    static func emptyFolderHint(_ q: TranscriptQuery) -> String {
        q.documents.isEmpty ? " There are no transcripts yet in \(folder.path(percentEncoded: false))." : ""
    }

    static func short(_ s: String, _ max: Int = 220) -> String {
        s.count <= max ? s : String(s.prefix(max)) + "…"
    }

    static func handle(_ name: String, _ a: [String: Value]) -> CallTool.Result {
        let q = load()
        let limit = a["limit"]?.intValue ?? 20
        let cursor = a["cursor"]?.stringValue
        let detailed = a["response_format"]?.stringValue == "detailed"

        switch name {
        case "minuta_list_meetings":
            let (from, to, err) = dates(a, q)
            if let err { return fail(err) }
            let page = q.listMeetings(from: from, to: to, query: a["query"]?.stringValue, app: a["app"]?.stringValue,
                                      limit: limit, cursor: cursor)
            guard !page.items.isEmpty else {
                return ok("No meetings match." + emptyFolderHint(q) + " Try fewer filters or a wider date range. " + today(q), page)
            }
            var lines = page.items.map { m -> String in
                var s = "- \(m.id)  ·  \(m.date)"
                if let d = m.duration_minutes { s += " · \(d) min" }
                if let app = m.app { s += " · \(app)" }
                if detailed {
                    if !m.attendees.isEmpty { s += "\n  attendees: \(m.attendees.joined(separator: ", "))" }
                    s += "\n  speakers: \(m.speakers.joined(separator: ", ")) · \(m.line_count) lines"
                    if let link = m.meeting_link { s += "\n  link: \(link)" }
                }
                return s
            }
            lines.insert("\(page.total) meeting(s); showing \(page.items.count).", at: 0)
            if let next = page.next_cursor { lines.append("More: call again with cursor=\"\(next)\".") }
            return ok(lines.joined(separator: "\n"), page)

        case "minuta_search_transcripts":
            guard let query = a["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                return fail("query is required, e.g. {\"query\": \"precio minuto\"}.")
            }
            let (from, to, err) = dates(a, q)
            if let err { return fail(err) }
            let page = q.search(query, from: from, to: to, speaker: a["speaker"]?.stringValue, limit: limit, cursor: cursor)
            guard !page.items.isEmpty else {
                return ok("No lines contain all of: \(query)." + emptyFolderHint(q)
                          + " Try fewer or shorter words, the other language, or no speaker/date filter.", page)
            }
            var lines = ["\(page.total) matching line(s); showing \(page.items.count)."]
            for h in page.items {
                lines.append("\n[\(h.meeting_id)] \(h.meeting_date), at \(h.time)")
                if let b = h.context_before { lines.append("  " + short(b)) }
                lines.append("> \(h.speaker): \(h.text)")
                if let c = h.context_after { lines.append("  " + short(c)) }
            }
            if let next = page.next_cursor { lines.append("\nMore: call again with cursor=\"\(next)\", or narrow with from/to or speaker.") }
            return ok(lines.joined(separator: "\n"), page)

        case "minuta_get_transcript":
            guard let id = a["meeting_id"]?.stringValue else {
                return fail("meeting_id is required. Get one from minuta_list_meetings.")
            }
            guard let doc = q.document(id: id) else {
                let hint = id.split(separator: "-").last.map { $0.trimmingCharacters(in: .whitespaces) }
                let close = q.listMeetings(query: hint, limit: 3).items.map(\.id)
                return fail("No meeting with id \"\(id)\"." + (close.isEmpty ? " Use minuta_list_meetings to find the exact id."
                             : " Did you mean: " + close.map { "\"\($0)\"" }.joined(separator: ", ") + "?"))
            }
            var start: Double?, end: Double?
            if let s = a["start_time"]?.stringValue {
                guard let t = TranscriptQuery.parseClock(s) else { return fail("Couldn't read start_time=\"\(s)\". Use \"mm:ss\" or \"h:mm:ss\".") }
                start = t
            }
            if let s = a["end_time"]?.stringValue {
                guard let t = TranscriptQuery.parseClock(s) else { return fail("Couldn't read end_time=\"\(s)\". Use \"mm:ss\" or \"h:mm:ss\".") }
                end = t
            }
            let t = q.transcript(doc, start: start, end: end, detailed: detailed)
            var text = t.text
            if t.truncated, let next = t.next_start_time {
                text += "\n[Truncated. Continue with start_time=\"\(next)\".]"
            }
            return ok(text, t)

        default:
            return fail("Unknown tool \"\(name)\". Available: minuta_list_meetings, minuta_search_transcripts, minuta_get_transcript.")
        }
    }

    // MARK: - Server

    /// Serves MCP over stdin/stdout until the client disconnects.
    public static func run() async throws {
        // stdout carries the protocol; diagnostics go to stderr.
        FileHandle.standardError.write(Data("minuta-mcp: reading transcripts from \(folder.path(percentEncoded: false)) (exe \(CommandLine.arguments[0]))\n".utf8))
        let server = Server(
            name: "minuta",
            version: "1.0.0",
            title: "Minuta",
            instructions: """
            Read-only access to the user's call transcripts recorded by Minuta on this Mac (Zoom, Meet, Teams, \
            WhatsApp…). Typical flow: minuta_list_meetings or minuta_search_transcripts to find the call, then \
            minuta_get_transcript (with a time range for long calls). "Me" is the user. Transcripts come from \
            on-device speech-to-text: names and numbers may be misspelled.
            """,
            capabilities: .init(tools: .init(listChanged: false))
        )
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            handle(params.name, params.arguments ?? [:])
        }
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
