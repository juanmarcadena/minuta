import AppKit
import MinutaCore
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("language") private var language = "auto"
    @AppStorage("vocabulary") private var vocabulary = AppModel.defaultVocabulary

    var body: some View {
        Form {
            Section("Transcripts") {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.transcriptsFolder.path(percentEncoded: false))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Picker("Language", selection: $language) {
                    Text("Automatic").tag("auto")
                    Text("Español").tag("es")
                    Text("English").tag("en")
                }
                TextField("Names and terms", text: $vocabulary, prompt: Text("Company, product and people names"), axis: .vertical)
                    .lineLimit(2...4)
                Text("Spelled the way you write them here. Separate with commas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                Toggle("Record calls automatically", isOn: $model.autoRecord)
                ForEach(CallApp.all) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { model.enabledApps.contains(app.id) },
                        set: { on in
                            if on { model.enabledApps.insert(app.id) } else { model.enabledApps.remove(app.id) }
                        }))
                }
                .disabled(!model.autoRecord)
                Text("Minuta starts recording when one of these apps opens the mic and stops 30 seconds after the call ends. Mic uses under 20 seconds, and calls under a minute with no calendar event, are thrown away. It records only that app's sound.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Calendar") {
                switch model.calendar.access {
                case .granted:
                    Label("Transcripts are named after the meeting on your calendar", systemImage: "checkmark.circle")
                case .unknown:
                    Button("Allow Calendar Access…") { Task { await model.calendar.requestAccess() } }
                case .denied:
                    LabeledContent("Calendar access is off") {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            }

            Section("General") {
                Toggle("Open Minuta at login", isOn: $model.launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.transcriptsFolder
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            model.transcriptsFolder = url
        }
    }
}
