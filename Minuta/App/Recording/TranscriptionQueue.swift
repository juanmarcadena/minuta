import Foundation
import MinutaCore
import MinutaTranscription

/// Transcribes finished recordings one at a time, writes the Markdown, then deletes the audio.
/// Anything left in the Recordings folder (a crash, a quit mid-transcription) is picked up at launch.
@Observable
final class TranscriptionQueue {
    private(set) var pending: [URL] = []
    private(set) var current: URL?
    private(set) var progress: String?
    /// Most recent transcripts written this session, newest first.
    private(set) var written: [URL] = []
    var lastError: String?
    /// Called on the main actor after each transcript is saved.
    @ObservationIgnored var onWritten: ((URL) -> Void)?

    var count: Int { pending.count + (current == nil ? 0 : 1) }

    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private lazy var transcriber = Transcriber(
        modelsBase: URL.applicationSupportDirectory.appending(path: "Minuta/Models", directoryHint: .isDirectory)
    ) { [weak self] message in
        TranscriptionQueue.log(message)
        Task { @MainActor in self?.progress = message }
    }

    /// With MINUTA_DEBUG=1, every progress line also goes to ~/Library/Logs/Minuta/transcription.log.
    nonisolated static func log(_ message: String) {
        guard ProcessInfo.processInfo.environment["MINUTA_DEBUG"] == "1" else { return }
        let dir = URL.libraryDirectory.appending(path: "Logs/Minuta", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "transcription.log")
        let line = "\(Date.now.ISO8601Format()) \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    /// Where to write, which language, which words to spell right. Read at the start of each job.
    var settings: () -> (folder: URL, language: String?, vocabulary: [String]) = {
        (URL.documentsDirectory, nil, [])
    }

    func enqueue(_ folder: URL) {
        guard folder != current, !pending.contains(folder) else { return }
        pending.append(folder)
        startIfIdle()
    }

    /// Recording folders that never got a transcript (crash, quit, or a failed job).
    func recoverLeftovers(excluding active: URL? = nil) {
        let root = RecordingSession.recordingsRoot
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where folder != active && FileManager.default.fileExists(atPath: folder.appending(path: RecordingManifest.fileName).path) {
            enqueue(folder)
        }
    }

    private func startIfIdle() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            while let self, !self.pending.isEmpty {
                let folder = self.pending.removeFirst()
                self.current = folder
                await self.process(folder)
                self.current = nil
                self.progress = nil
            }
            await self?.transcriber.unload()  // give the memory back between meetings
            self?.worker = nil
        }
    }

    private func process(_ folder: URL) async {
        let (outFolder, language, vocabulary) = settings()
        do {
            let manifest = try RecordingManifest.read(from: folder)
            // Attendee names from the calendar are the words most worth spelling right.
            let names = (manifest.attendees ?? []).filter { !$0.contains("@") }
            let options = Transcriber.Options(language: language, vocabulary: vocabulary + names)
            let result = try await transcriber.transcribe(folder: folder, options: options)
            let title = manifest.displayTitle
            let markdown = TranscriptMarkdown.render(result.utterances, meta: .init(
                title: title, startedAt: manifest.startedAt, duration: result.duration, app: manifest.app,
                attendees: manifest.attendees ?? [], meetingLink: manifest.meetingLink))

            try FileManager.default.createDirectory(at: outFolder, withIntermediateDirectories: true)
            let url = TranscriptNaming.uniqueURL(in: outFolder, fileName: TranscriptNaming.fileName(start: manifest.startedAt, title: title))
            try markdown.write(to: url, atomically: true, encoding: .utf8)

            // Only delete the audio once the transcript is really on disk.
            let saved = try String(contentsOf: url, encoding: .utf8)
            guard saved == markdown else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.removeItem(at: folder)
            written.insert(url, at: 0)
            EventLog.write("transcript \(folder.lastPathComponent) → \(url.lastPathComponent) (\(result.utterances.count) lines)")
            onWritten?(url)
        } catch {
            lastError = "Transcription failed for \(folder.lastPathComponent): \(error.localizedDescription). The audio was kept."
            EventLog.write("transcription failed \(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }
}
