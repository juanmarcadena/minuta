import AppKit
import MinutaCore
import SwiftUI

/// Settings window: a pane per area, as Apple's HIG describes for macOS settings
/// (toolbar of panes, title follows the pane, reopens on the last pane used).
struct SettingsView: View {
    @Bindable var model: AppModel
    @AppStorage("settingsPane") private var pane = "general"

    var body: some View {
        TabView(selection: $pane) {
            Tab("General", systemImage: "gearshape", value: "general") {
                GeneralPane(model: model)
            }
            Tab("Recording", systemImage: "record.circle", value: "recording") {
                RecordingPane(model: model)
            }
            Tab("Calendar", systemImage: "calendar", value: "calendar") {
                CalendarPane(model: model)
            }
            Tab("Transcripts", systemImage: "text.bubble", value: "transcripts") {
                TranscriptsPane(model: model)
            }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @AppStorage("notifyTranscripts") private var notify = true

    var body: some View {
        Form {
            Section {
                Toggle("Open Minuta at login", isOn: $model.launchAtLogin)
            } footer: {
                Text("Minuta lives in the menu bar. It needs to be running to notice your calls.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify me when a transcript is ready", isOn: $notify)
            } footer: {
                Text("One notification per call, and one if a recording had a problem. Nothing else.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct RecordingPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Toggle("Record calls automatically", isOn: $model.autoRecord)
            } footer: {
                Text("Minuta starts recording when one of these apps opens the mic and stops 30 seconds after the call ends. Mic uses under 20 seconds, and calls under a minute with no calendar event, are thrown away. It records only that app's sound.")
                    .foregroundStyle(.secondary)
            }
            Section("Apps") {
                ForEach(CallApp.all) { app in
                    Toggle(app.name, isOn: Binding(
                        get: { model.enabledApps.contains(app.id) },
                        set: { on in
                            if on { model.enabledApps.insert(app.id) } else { model.enabledApps.remove(app.id) }
                        }))
                }
            }
            .disabled(!model.autoRecord)
        }
        .formStyle(.grouped)
    }
}

private struct CalendarPane: View {
    let model: AppModel

    var body: some View {
        Form {
            Section {
                switch model.calendar.access {
                case .granted:
                    Label("Calendar access is on", systemImage: "checkmark.circle")
                case .unknown:
                    Button("Allow Calendar Access…") { Task { await model.calendar.requestAccess() } }
                case .denied:
                    LabeledContent("Calendar access is off") {
                        Button("Open Privacy Settings…") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                        }
                    }
                }
            } footer: {
                Text("Minuta reads your calendars to name each transcript after its meeting, list who attended, and spell their names right. It never changes your calendar.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TranscriptsPane: View {
    @Bindable var model: AppModel
    @AppStorage("language") private var language = "auto"
    @AppStorage("vocabulary") private var vocabulary = AppModel.defaultVocabulary
    @State private var copied = false

    static let mcpCommand = "claude mcp add -s user minuta -- /Applications/Minuta.app/Contents/MacOS/minuta-mcp"

    var body: some View {
        Form {
            Section {
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
                    Text(verbatim: "Español").tag("es")
                    Text(verbatim: "English").tag("en")
                }
            }
            Section {
                TextField("Names and terms", text: $vocabulary, prompt: Text("Company, product and people names"), axis: .vertical)
                    .lineLimit(2...4)
            } footer: {
                Text("Spelled the way you write them here. Separate with commas.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Claude Code") {
                    Button(copied ? "Copied" : "Copy Setup Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
                        copied = true
                    }
                }
            } header: {
                Text("AI assistants")
            } footer: {
                Text("Minuta includes a read-only MCP server so assistants like Claude can search and read your transcripts on this Mac. For other apps, add a stdio server with the path Minuta.app/Contents/MacOS/minuta-mcp.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.transcriptsFolder
        panel.prompt = String(localized: "Use Folder")
        if panel.runModal() == .OK, let url = panel.url {
            model.transcriptsFolder = url
        }
    }
}
