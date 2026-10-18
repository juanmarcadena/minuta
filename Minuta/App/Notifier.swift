import AppKit
import MinutaCore
import UserNotifications

/// Informational notifications only, per Apple's HIG: one per finished transcript, one if a call's
/// audio went wrong, nothing else. Permission is asked the first time there is something to say.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let transcriptCategory = "transcript"
    static let problemCategory = "problem"
    static let copyAction = "copy"

    private let center = UNUserNotificationCenter.current()
    /// Called when the user clicks a notification about this transcript file.
    var onOpen: ((URL) -> Void)?

    var enabled: Bool { UserDefaults.standard.object(forKey: "notifyTranscripts") as? Bool ?? true }

    override init() {
        super.init()
        center.delegate = self
        let copy = UNNotificationAction(identifier: Self.copyAction, title: String(localized: "Copy Transcript"),
                                        options: [], icon: UNNotificationActionIcon(systemImageName: "doc.on.doc"))
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.transcriptCategory, actions: [copy], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "Transcript ready"), options: []),
            UNNotificationCategory(identifier: Self.problemCategory, actions: [], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "A recording needs attention"), options: []),
        ])
    }

    /// Asks once, in context; later calls return the stored answer without prompting.
    private func authorized() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional: return true
        case .notDetermined: return (try? await center.requestAuthorization(options: [.alert])) ?? false
        default: return false
        }
    }

    func transcriptReady(_ url: URL, title: String, minutes: Int?) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = minutes.map { String(localized: "Transcript ready · \($0) min") } ?? String(localized: "Transcript ready")
        content.categoryIdentifier = Self.transcriptCategory
        content.threadIdentifier = "transcripts"
        content.userInfo = ["file": url.path]
        post(content, id: "transcript-\(url.lastPathComponent)")
    }

    func problem(_ title: String, detail: String) {
        guard enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = detail
        content.categoryIdentifier = Self.problemCategory
        content.threadIdentifier = "problems"
        post(content, id: "problem-\(UUID().uuidString)")
    }

    private func post(_ content: UNMutableNotificationContent, id: String) {
        Task {
            guard await authorized() else { return }
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]   // Minuta is a menu-bar app; show it even when one of its windows is in front
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["file"] as? String else { return }
        let url = URL(filePath: path)
        let action = response.actionIdentifier
        await MainActor.run {
            if action == Self.copyAction {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(TranscriptDocument.parse(text, url: url).plainText, forType: .string)
                }
            } else if action == UNNotificationDefaultActionIdentifier {
                onOpen?(url)
            }
        }
    }
}
