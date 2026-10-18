import Foundation
import MinutaCore
import Observation

/// All transcripts in the folder, newest first, kept current while the viewer is open.
@MainActor
@Observable
public final class TranscriptLibrary {
    public init() {}

    public private(set) var documents: [TranscriptDocument] = []
    public private(set) var isLoading = false
    /// Which transcript the viewer shows; set from the menu before opening the window.
    public var selection: URL?

    @ObservationIgnored private var folder: URL?
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var searchIndex: [URL: String] = [:]

    public func open(folder: URL) {
        if self.folder != folder {
            self.folder = folder
            watch(folder)
        }
        reload()
    }

    public func reload() {
        guard let folder else { return }
        isLoading = true
        Task {
            let docs = await Self.load(folder)
            documents = docs
            searchIndex = Dictionary(uniqueKeysWithValues: docs.map { ($0.url, $0.searchableText) })
            if let selection, !docs.contains(where: { $0.url == selection }) { self.selection = docs.first?.url }
            isLoading = false
        }
    }

    /// Transcripts whose title, attendees or words contain every word of the query (case and accents ignored).
    public func filtered(_ query: String) -> [TranscriptDocument] {
        let words = TranscriptDocument.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return documents }
        return documents.filter { doc in
            let text = searchIndex[doc.url] ?? doc.searchableText
            return words.allSatisfy { text.contains($0) }
        }
    }

    /// Reads and parses every `.md` off the main actor.
    nonisolated static func load(_ folder: URL) async -> [TranscriptDocument] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> TranscriptDocument? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                var doc = TranscriptDocument.parse(text, url: url)
                if doc.date == nil {
                    doc.date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate
                }
                return doc
            }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Reloads when files are added, removed or renamed in the folder.
    private func watch(_ folder: URL) {
        watcher?.cancel()
        let fd = Darwin.open(folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
    }
}
