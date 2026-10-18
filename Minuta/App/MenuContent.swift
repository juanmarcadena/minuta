import AppKit
import SwiftUI

/// The menu shown from the menu bar icon (HIG: a menu, not a popover; same items always, disabled when unavailable).
struct MenuContent: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    private func showTranscripts(_ url: URL? = nil) {
        if let url { model.library.selection = url }
        NSApp.activate()
        openWindow(id: "transcripts")
    }

    var body: some View {
        Text(model.statusLine)

        if let error = model.lastError ?? model.queue.lastError {
            Text(error)
        }

        if let next = model.nextMeeting {
            Button(Self.nextLine(next, now: model.now)) {
                if let link = next.link, let url = URL(string: link) { model.open(url) }
            }
            .disabled(next.link == nil)
        }

        Divider()

        Button("Start Recording") {
            Task { await model.startManualRecording() }
        }
        .keyboardShortcut("r")
        .disabled(model.phase.isRecording)

        Button("Stop Recording") {
            model.stopRecording()
        }
        .keyboardShortcut(".")
        .disabled(!model.phase.isRecording)

        Divider()

        Button("Show Transcripts…") { showTranscripts() }
            .keyboardShortcut("t")

        Menu("Recent Transcripts") {
            ForEach(model.recentTranscripts, id: \.self) { url in
                Button(url.deletingPathExtension().lastPathComponent) { showTranscripts(url) }
            }
        }
        .disabled(model.recentTranscripts.isEmpty)

        Button("Open Transcripts Folder") {
            model.openTranscriptsFolder()
        }
        .keyboardShortcut("o")

        Divider()

        Menu("Debug") {
            Button("Show Apps Using Audio…") { model.showAudioProcesses() }
            Button("Reveal Last Recording") { model.revealLastRecording() }
                .disabled(model.lastRecording == nil)
        }

        Divider()

        Button("Settings…") {
            // A menu-bar-only app must come forward or Settings opens behind other windows.
            NSApp.activate()
            openSettings()
        }
        .keyboardShortcut(",")

        Button("Quit Minuta") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// "Next: Weekly sync in 5 min" (or "at 15:00" when more than 15 minutes away).
    static func nextLine(_ e: CalendarContext.EventInfo, now: Date) -> String {
        let minutes = Int((e.start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 15 { return "Next: \(e.title) in \(max(1, minutes)) min" }
        return "Next: \(e.title) at \(e.start.formatted(date: .omitted, time: .shortened))"
    }
}
