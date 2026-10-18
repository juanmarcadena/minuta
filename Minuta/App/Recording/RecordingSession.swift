import Foundation
import MinutaCore

/// One meeting being recorded: a folder in Application Support with me.caf, them.caf and meeting.json.
final class RecordingSession {
    static let recordingsRoot = URL.applicationSupportDirectory.appending(path: "Minuta/Recordings", directoryHint: .isDirectory)

    let folder: URL
    private(set) var manifest: RecordingManifest
    private let mic = MicRecorder()
    private let tap = SystemAudioTap()

    init(app: String, appID: String? = nil, startedAt: Date = .now, event: CalendarContext.EventInfo? = nil) throws {
        manifest = RecordingManifest(startedAt: startedAt, app: app)
        manifest.appID = appID
        manifest.title = event?.title
        manifest.attendees = event?.attendees
        manifest.meetingLink = event?.link
        folder = Self.recordingsRoot.appending(path: manifest.id.uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try manifest.write(to: folder)
    }

    func start(tapTarget: SystemAudioTap.Target) throws {
        try mic.start(writingTo: folder.appending(path: manifest.me.file))
        do {
            try tap.start(target: tapTarget, writingTo: folder.appending(path: manifest.them.file))
        } catch {
            mic.stop()
            throw error
        }
    }

    func refreshTap() { tap.refreshProcesses() }

    var seconds: Double { mic.secondsWritten }

    /// Throws the recording away (too short to be a meeting).
    func discard() {
        mic.stop()
        tap.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    /// Stops both tracks, records alignment info and returns the finished manifest.
    @discardableResult
    func stop() throws -> RecordingManifest {
        manifest.me.firstSampleHostSeconds = mic.firstSampleHostSeconds
        manifest.them.firstSampleHostSeconds = tap.firstSampleHostSeconds
        manifest.me.peak = mic.peak
        manifest.them.peak = tap.peak
        mic.stop()
        tap.stop()
        manifest.endedAt = .now
        try manifest.write(to: folder)
        return manifest
    }

    /// How many times audio moved to another device during the call (for the debug log).
    var deviceChanges: Int { mic.deviceChanges + tap.deviceChanges }

    var problems: [String] {
        [mic.lastError.map { "Mic: \($0.localizedDescription)" },
         tap.lastError.map { "Call audio: \($0.localizedDescription)" }].compactMap { $0 }
    }
}
