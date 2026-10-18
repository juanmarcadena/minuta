import AppKit
import MinutaUI
import SwiftUI

/// The Mac's Transcripts window: the shared browser, plus Mac-only window behavior.
struct TranscriptsWindow: View {
    let model: AppModel
    let library: TranscriptLibrary

    var body: some View {
        TranscriptBrowser(library: library, folder: model.transcriptsFolder)
            // Behave like a normal app (Dock icon, ⌘-Tab) while the viewer is open.
            .onAppear { NSApp.setActivationPolicy(.regular); NSApp.activate() }
            .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
