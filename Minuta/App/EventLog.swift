import Foundation

/// One line per event in ~/Library/Logs/Minuta/minuta.log (recording started/stopped, device
/// switches, errors) so problems during real use can be looked at afterwards. No transcript text.
nonisolated enum EventLog {
    static let url = URL.libraryDirectory.appending(path: "Logs/Minuta/minuta.log")
    private static let queue = DispatchQueue(label: "minuta.log")

    static func write(_ message: String) {
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
