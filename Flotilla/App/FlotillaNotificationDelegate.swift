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
    static let fixCIActionIdentifier = "FIX_CI_ACTION"

    private let navigator: WorkspaceNavigator
    private let onReply: @MainActor (UUID, String) -> Void
    private let onFixCI: @MainActor (UUID) -> Void
    private let shouldPresentInForeground: @Sendable () -> Bool

    init(
        navigator: WorkspaceNavigator,
        onReply: @escaping @MainActor (UUID, String) -> Void,
        onFixCI: @escaping @MainActor (UUID) -> Void = { _ in },
        shouldPresentInForeground: @escaping @Sendable () -> Bool = { true }
    ) {
        self.navigator = navigator
        self.onReply = onReply
        self.onFixCI = onFixCI
        self.shouldPresentInForeground = shouldPresentInForeground
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
        let ciFailed = UNNotificationCategory(
            identifier: SystemNotificationDispatcher.ciFailedCategoryIdentifier,
            actions: [UNNotificationAction(identifier: Self.fixCIActionIdentifier, title: "Fix with Agent", options: [])],
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category, ciFailed])
    }

    static func presentationOptions(shouldPresentInForeground: Bool) -> UNNotificationPresentationOptions {
        shouldPresentInForeground ? [.banner, .sound] : []
    }

    /// Shows the banner when configured to present in the foreground (e.g. Always).
    /// When set to Never or Only when not active, foreground presentation is suppressed
    /// by passing empty presentation options.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(Self.presentationOptions(shouldPresentInForeground: shouldPresentInForeground()))
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
        let onFixCI = self.onFixCI
        let isCIFailure = response.notification.request.content.categoryIdentifier
            == SystemNotificationDispatcher.ciFailedCategoryIdentifier
        let isFixRequest = response.actionIdentifier == Self.fixCIActionIdentifier
        Task { @MainActor in
            if isFixRequest {
                onFixCI(sessionID)
                return
            }
            if isCIFailure {
                navigator.requestChecks(for: sessionID)
            } else {
                navigator.selection = .session(sessionID)
            }
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
