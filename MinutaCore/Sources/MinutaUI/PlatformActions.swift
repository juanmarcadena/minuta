import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The few things the viewer does that differ per platform.
enum PlatformActions {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #else
        UIPasteboard.general.string = text
        #endif
    }

    #if os(macOS)
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    #endif

    /// Recoverable: the Trash on macOS, the Files app's Recently Deleted elsewhere.
    static func trash(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.recycle([url])
        #else
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        #endif
    }
}
