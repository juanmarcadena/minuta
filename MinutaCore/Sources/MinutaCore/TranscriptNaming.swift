import Foundation

/// File names for transcripts: `2026-10-16 1500 - Weekly sync.md`.
public enum TranscriptNaming {
    /// Names and timestamps use the Mac's own time zone.
    public static var timeZone: TimeZone { .current }

    public static func fileName(start: Date, title: String, timeZone: TimeZone = timeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        let stamp = String(format: "%04d-%02d-%02d %02d%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!)
        return "\(stamp) - \(sanitized(title)).md"
    }

    /// Strip characters Finder or iCloud reject and keep names short.
    static func sanitized(_ title: String) -> String {
        let banned = CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r\t")
        let cleaned = title.unicodeScalars.map { banned.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(collapsed.prefix(80)).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".")))
        return trimmed.isEmpty ? "Meeting" : trimmed
    }

    /// Adds " (2)", " (3)"… when a name is already taken.
    public static func uniqueURL(in folder: URL, fileName: String, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let first = folder.appending(path: fileName)
        guard exists(first) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        for n in 2... {
            let url = folder.appending(path: "\(base) (\(n)).md")
            if !exists(url) { return url }
        }
        fatalError("unreachable")
    }
}
