import AppKit
import SwiftUI

@main
struct MinutaApp: App {
    @State private var model = AppModel()
    @AppStorage("onboarded") private var onboarded = false

    var body: some Scene {
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
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

/// The menu-bar icon. It is always alive, so it also opens the Transcripts window when a
/// notification is clicked (SwiftUI opens windows from views, not from the model).
struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Minuta's own mark (template image, adapts to light/dark); a clear record symbol while recording.
        (model.phase.isRecording ? Image(systemName: "record.circle.fill") : Image("MenuBarIcon"))
            .accessibilityLabel(model.phase.isRecording ? "Minuta, recording" : "Minuta")
            .onChange(of: model.transcriptsWindowRequest) {
                NSApp.activate()
                openWindow(id: "transcripts")
            }
    }
}
