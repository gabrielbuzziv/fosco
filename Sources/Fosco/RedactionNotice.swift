import os
import UserNotifications

/// Tells the user that a capture was blurred. The screenshot app keeps showing the original, so
/// without this nothing says that what gets pasted is not what is on screen.
@MainActor
final class RedactionNotice: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { isGranted, error in
            log.notice("Notifications allowed: \(isGranted, privacy: .public)\(error.map { ", \($0.localizedDescription)" } ?? "", privacy: .public)")
        }
    }

    func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // One identifier, so a new notice takes the place of the last instead of piling up.
        center.add(UNNotificationRequest(identifier: "redaction", content: content, trigger: nil)) { error in
            if let error { log.error("Could not post the notification: \(error.localizedDescription, privacy: .public)") }
        }
    }

    /// macOS hides the notifications of the app in front; Fosco is in front right after its menu is used.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}

private let log = Logger(subsystem: "com.gabrielbuzzi.fosco", category: "app")
