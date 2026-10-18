import AppKit

/// The standard macOS About panel (icon, name, version and copyright come from the app bundle),
/// with credits for what Minuta is built on and a link to the source.
enum AboutPanel {
    static let repository = URL(string: "https://github.com/juanmarcadena/minuta")!

    @MainActor static func show() {
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: center]

        let credits = NSMutableAttributedString(string: String(localized: "Call transcripts on your Mac. No bot, nothing uploaded.") + "\n\n", attributes: plain)
        credits.append(NSAttributedString(string: String(localized: "Transcription by WhisperKit (Argmax). Speaker separation by SpeakerKit. MCP server built with the Model Context Protocol Swift SDK.") + "\n\n", attributes: plain))
        var link = plain
        link[.link] = repository
        link[.foregroundColor] = NSColor.linkColor
        credits.append(NSAttributedString(string: "github.com/juanmarcadena/minuta", attributes: link))

        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
