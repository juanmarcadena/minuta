import SwiftUI

@main
struct MinutaApp: App {
    @State private var model = AppModel()
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            Image(systemName: model.phase.isRecording ? "record.circle.fill" : "waveform")
                .accessibilityLabel(model.phase.isRecording ? "Minuta, recording" : "Minuta")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }

        Window("Transcripts", id: "transcripts") {
            TranscriptsWindow(model: model, library: model.library)
        }
        .defaultSize(width: 1080, height: 740)
        .keyboardShortcut("t", modifiers: [.command, .shift])
        // Dev switch: MINUTA_SHOW_TRANSCRIPTS=1 opens the viewer at launch (for screenshots).
        .defaultLaunchBehavior(ProcessInfo.processInfo.environment["MINUTA_SHOW_TRANSCRIPTS"] == "1" ? .presented : .suppressed)

        Window("Welcome to Minuta", id: "welcome") {
            WelcomeView(model: model)
        }
        .windowResizability(.contentSize)
        // A menu-bar app can't pull itself in front of other apps, so this one-time window floats.
        .windowLevel(.floating)
        .defaultLaunchBehavior(onboarded ? .suppressed : .presented)
    }
}
