import AppKit
import MinutaCore
import MinutaUI
import Observation
import ServiceManagement

/// App-wide state: detection, recording, and the hand-off to transcription.
@Observable
final class AppModel {
    var phase: MeetingPhase = .idle
    var lastError: String?
    /// Folder of the last finished recording, for the debug menu.
    var lastRecording: URL?
    /// Ticks once a second; drives detection and the menu's timer line.
    var now = Date.now
    let queue = TranscriptionQueue()
    let calendar = CalendarContext()
    let library = TranscriptLibrary()
    @ObservationIgnored let notifier = Notifier()
    /// Bumped to ask the menu-bar label (always alive) to open the Transcripts window.
    var transcriptsWindowRequest = 0

    @ObservationIgnored private var session: RecordingSession?
    @ObservationIgnored private var starting = false
    @ObservationIgnored private var detector = MeetingDetector()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var ticks = 0
    /// Newest transcripts in the folder, for the menu. Refreshed every 15 s and after each save.
    var recentTranscripts: [URL] = []
    /// Next calendar meeting within the hour, for the menu.
    var nextMeeting: CalendarContext.EventInfo?

    static let defaultVocabulary = ""

    init() {
        UserDefaults.standard.register(defaults: [
            "autoRecord": true,
            "enabledApps": CallApp.all.map(\.id),
        ])
        queue.settings = {
            let d = UserDefaults.standard
            let language = d.string(forKey: "language").flatMap { $0 == "auto" ? nil : $0 }
            let vocabulary = (d.string(forKey: "vocabulary") ?? Self.defaultVocabulary)
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return (self.transcriptsFolder, language, vocabulary)
        }
        queue.recoverLeftovers()
        queue.onWritten = { [weak self] url in
            self?.refreshRecent()
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let doc = TranscriptDocument.parse(text, url: url)
                self?.notifier.transcriptReady(url, title: doc.title, minutes: doc.durationMinutes)
            }
        }
        queue.onFailed = { [weak self] message in
            self?.notifier.problem(String(localized: "A transcript couldn't be made"), detail: message)
        }
        notifier.onOpen = { [weak self] url in
            guard let self else { return }
            library.selection = url
            transcriptsWindowRequest += 1
        }
        refreshRecent()
        calendar.refreshAccess()
        if calendar.access == .unknown {
            Task { await calendar.requestAccess() }
        }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Settings

    var autoRecord: Bool {
        get { access(keyPath: \.autoRecord); return UserDefaults.standard.bool(forKey: "autoRecord") }
        set { withMutation(keyPath: \.autoRecord) { UserDefaults.standard.set(newValue, forKey: "autoRecord") } }
    }

    var enabledApps: Set<String> {
        get {
            access(keyPath: \.enabledApps)
            return Set(UserDefaults.standard.stringArray(forKey: "enabledApps") ?? [])
        }
        set { withMutation(keyPath: \.enabledApps) { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "enabledApps") } }
    }

    /// The line at the top of the menu.
    var statusLine: String {
        if phase != .idle || queue.count == 0 { return Self.text(for: phase, now: now) }
        let base = Self.text(for: .transcribing(pending: queue.count), now: now)
        return queue.progress.map { "\(base) — \($0)" } ?? base
    }

    /// The menu's status line, in the user's language.
    static func text(for phase: MeetingPhase, now: Date) -> String {
        switch phase {
        case .idle:
            return String(localized: "Idle")
        case .armed(let app, _):
            return String(localized: "\(app) is using the mic…")
        case .recording(let app, let since):
            return String(localized: "Recording \(app) — \(MeetingPhase.clock(now.timeIntervalSince(since)))")
        case .finishing(let app, _):
            return String(localized: "Finishing \(app) recording…")
        case .transcribing(let pending):
            return String(localized: "Transcribing \(pending) meetings")
        }
    }

    // MARK: Detection

    /// Enabled call apps (by `CallApp.id`) that have the mic open right now.
    func callAppsUsingMic() -> Set<String> {
        let me = getpid()
        let enabled = enabledApps
        let processes = (try? AudioProcess.all()) ?? []
        return Set(processes.filter { $0.isRunningInput && $0.pid != me }
            .compactMap { CallApp.owner(of: $0.bundleID, enabled: enabled)?.id })
    }

    private func tick() {
        now = .now
        ticks += 1
        let recording = session != nil
        guard autoRecord || recording else { return }

        let micApps = callAppsUsingMic()
        let action = detector.update(now: now, micApps: micApps) { [calendar] id in
            calendar.hasEvent(for: CallApp.app(id: id))
        }
        switch action {
        case .start(let appID)?:
            Task { await startRecording(appID: appID) }
        case .stop(let discard)?:
            finishRecording(discard: discard)
        case nil:
            break
        }
        if recording, ticks % 5 == 0 { session?.refreshTap() }
        if ticks % 15 == 1 {
            refreshRecent()
            nextMeeting = calendar.nextMeeting(now: now)
        }
    }

    // MARK: Recording

    /// Menu "Start Recording": records the call app using the mic, or everything if none is.
    func startManualRecording() async {
        guard session == nil, !starting else { return }
        let appID = MeetingDetector.pick(callAppsUsingMic())
        detector.manualStart(appID: appID, now: .now)
        await startRecording(appID: appID)
    }

    private func startRecording(appID: String?) async {
        guard session == nil, !starting else { return }
        starting = true
        defer { starting = false }
        lastError = nil
        guard await MicRecorder.requestPermission() else {
            lastError = String(localized: "Microphone access is off. Turn it on in System Settings → Privacy & Security → Microphone.")
            detector.manualStop(micApps: [])
            return
        }
        let app = appID.flatMap(CallApp.app(id:))
        let event = calendar.currentEvent(for: app)
        let name = app?.displayName(meetingLink: event?.link) ?? "Manual"
        let target: SystemAudioTap.Target = app.map { .apps(bundlePrefixes: $0.bundlePrefixes) } ?? .allExceptSelf
        do {
            let session = try RecordingSession(app: name, appID: appID, event: event)
            try session.start(tapTarget: target)
            // The mic may have closed while we were starting (a dictation blip): nothing to keep.
            if detector.state == .idle {
                session.discard()
                return
            }
            self.session = session
            phase = .recording(app: event?.title ?? name, since: session.manifest.startedAt)
            EventLog.write("start \(appID ?? "manual") \"\(session.manifest.displayTitle)\" \(session.folder.lastPathComponent)")
        } catch {
            lastError = String(localized: "Couldn't start recording: \(error.localizedDescription)")
            EventLog.write("start failed: \(error.localizedDescription)")
            detector.manualStop(micApps: [])
        }
    }

    /// Menu "Stop Recording".
    func stopRecording() {
        detector.manualStop(micApps: callAppsUsingMic())
        finishRecording(discard: false)
    }

    private func finishRecording(discard: Bool) {
        guard let session else { return }
        self.session = nil
        phase = .idle
        if discard {
            session.discard()
            EventLog.write("discard \(session.folder.lastPathComponent) (too short)")
            return
        }
        do {
            let manifest = try session.stop()
            var problems = session.problems
            let duration = (manifest.endedAt ?? .now).timeIntervalSince(manifest.startedAt)
            if manifest.appID != nil, manifest.themLooksSilent(duration: duration) {
                problems.append(String(localized: "No sound came from \(manifest.app) during \"\(manifest.displayTitle)\". If the other side talked, turn on Minuta in System Settings → Privacy & Security → Screen & System Audio Recording."))
            }
            lastError = problems.isEmpty ? nil : problems.joined(separator: "; ")
            if let first = problems.first {
                notifier.problem(String(localized: "Problem with “\(manifest.displayTitle)”"), detail: first)
            }
            EventLog.write(String(format: "stop %@ %.0fs device-changes=%d me-peak=%.3f them-peak=%.3f%@",
                                  session.folder.lastPathComponent, duration, session.deviceChanges,
                                  manifest.me.peak ?? 0, manifest.them.peak ?? 0,
                                  problems.isEmpty ? "" : " problems: " + problems.joined(separator: "; ")))
            lastRecording = session.folder
            queue.enqueue(session.folder)
        } catch {
            lastError = String(localized: "Couldn't finish recording: \(error.localizedDescription)")
        }
    }

    /// Starts a one-second system-audio capture so macOS shows its permission prompt now,
    /// not in the middle of the first call.
    func requestSystemAudioAccess() {
        let tap = SystemAudioTap()
        let url = FileManager.default.temporaryDirectory.appending(path: "minuta-permission-\(UUID().uuidString).caf")
        do {
            try tap.start(target: .allExceptSelf, writingTo: url)
        } catch {
            lastError = String(localized: "System audio: \(error.localizedDescription)")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            tap.stop()
            try? FileManager.default.removeItem(at: url)
        }
    }

    func refreshRecent() {
        let folder = transcriptsFolder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recentTranscripts = files.filter { $0.pathExtension == "md" }
            .map { ($0, (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
            .prefix(5).map(\.0)
    }

    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    func revealLastRecording() {
        guard let lastRecording else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
    }

    /// Debug: which apps Core Audio sees using the mic or speakers right now.
    func showAudioProcesses() {
        let text: String
        do {
            let rows = try AudioProcess.all()
                .filter { $0.isRunningInput || $0.isRunningOutput }
                .map { "\($0.isRunningInput ? "🎙" : "  ") \($0.isRunningOutput ? "🔊" : "  ")  \($0.bundleID.isEmpty ? "(no bundle ID)" : $0.bundleID)  pid \($0.pid)" }
            text = rows.isEmpty ? "No app is using the mic or speakers." : rows.joined(separator: "\n")
        } catch {
            text = error.localizedDescription
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = String(localized: "Apps using audio now")
        alert.informativeText = text
        alert.addButton(withTitle: String(localized: "Copy"))
        alert.addButton(withTitle: String(localized: "Close"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    // MARK: Transcripts folder

    static let defaultTranscriptsFolder = URL.documentsDirectory.appending(path: "Minuta Transcripts", directoryHint: .isDirectory)

    var transcriptsFolder: URL {
        get {
            access(keyPath: \.transcriptsFolder)
            return UserDefaults.standard.url(forKey: "transcriptsFolder") ?? Self.defaultTranscriptsFolder
        }
        set {
            withMutation(keyPath: \.transcriptsFolder) {
                UserDefaults.standard.set(newValue, forKey: "transcriptsFolder")
            }
        }
    }

    func openTranscriptsFolder() {
        do {
            try FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(transcriptsFolder)
        } catch {
            lastError = String(localized: "Couldn't open \(transcriptsFolder.path): \(error.localizedDescription)")
        }
    }

    // MARK: Launch at login (ServiceManagement)

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    lastError = String(localized: "Launch at login: \(error.localizedDescription)")
                }
            }
        }
    }
}
