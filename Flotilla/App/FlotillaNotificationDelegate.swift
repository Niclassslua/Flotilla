import Foundation
import UserNotifications
import HooksKit

/// Receives clicks and inline replies on Flotilla's "Needs Your Input"
/// notifications: selects the session the notification was about, and — if
/// the click carried reply text — forwards it into that session's PTY.
///
/// `UNUserNotificationCenterDelegate` requires an `NSObject` conformer, and
/// its callbacks are not guaranteed to arrive on the main actor, so every
/// handler hops to `@MainActor` before touching `navigator`. Marked
/// `@unchecked Sendable` on that basis — the only mutable-looking state
/// (`navigator`, `onReply`) is never touched off the main actor.
final class FlotillaNotificationDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let replyActionIdentifier = "REPLY_ACTION"

    private let navigator: WorkspaceNavigator
    private let onReply: @MainActor (UUID, String) -> Void

    init(navigator: WorkspaceNavigator, onReply: @escaping @MainActor (UUID, String) -> Void) {
        self.navigator = navigator
        self.onReply = onReply
        super.init()
        registerCategories()
    }

    private func registerCategories() {
        let reply = UNTextInputNotificationAction(
            identifier: Self.replyActionIdentifier,
            title: "Reply",
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Type a response…"
        )
        let category = UNNotificationCategory(
            identifier: SystemNotificationDispatcher.waitingForInputCategoryIdentifier,
            actions: [reply],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Shows the banner even while Flotilla is the frontmost app — without
    /// this, the system's default behavior for a foreground app is to
    /// suppress the banner entirely, which is not what "Needs Your Input"
    /// should ever do.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let sessionID = Self.sessionID(from: response.notification.request.content.userInfo) else { return }

        let replyText = (response as? UNTextInputNotificationResponse)?.userText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let navigator = self.navigator
        let onReply = self.onReply
        Task { @MainActor in
            navigator.selection = .session(sessionID)
            if let replyText, !replyText.isEmpty {
                onReply(sessionID, replyText)
            }
        }
    }

    /// Pure so it's unit-testable without constructing real
    /// `UNNotification`/`UNNotificationRequest` framework objects.
    static func sessionID(from userInfo: [AnyHashable: Any]) -> UUID? {
        guard let raw = userInfo["sessionID"] as? String else { return nil }
        return UUID(uuidString: raw)
    }
}
