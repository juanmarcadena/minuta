import AVFoundation
import SwiftUI

/// First launch: ask for the three permissions in one place, offer open-at-login, then get out of the way.
struct WelcomeView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("onboarded") private var onboarded = false
    @State private var micGranted = AVAudioApplication.shared.recordPermission == .granted
    @State private var systemAudioAsked = false
    @State private var openAtLogin = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Minuta").font(.title2.bold())
                    Text("A transcript of every call, written on this Mac.")
                        .foregroundStyle(.secondary)
                }
            }

            step("Microphone", detail: "Your side of the call.", done: micGranted) {
                Task { micGranted = await MicRecorder.requestPermission() }
            }
            step("System audio", detail: "The other people. macOS asks once; choose Allow.", done: systemAudioAsked) {
                model.requestSystemAudioAccess()
                systemAudioAsked = true
            }
            step("Calendar", detail: "Names each transcript after its meeting. Read-only.", done: model.calendar.access == .granted) {
                Task { await model.calendar.requestAccess() }
            }

            Toggle("Open Minuta when I log in", isOn: $openAtLogin)

            Text("Audio never leaves this Mac and is deleted once the transcript is saved. Let people know you're transcribing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Done") {
                    if openAtLogin { model.launchAtLogin = true }
                    onboarded = true
                    dismissWindow(id: "welcome")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear { NSApp.activate() }
    }

    private func step(_ title: String, detail: String, done: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(done ? "Allowed" : "Allow…", action: action)
                .disabled(done)
        }
    }
}
