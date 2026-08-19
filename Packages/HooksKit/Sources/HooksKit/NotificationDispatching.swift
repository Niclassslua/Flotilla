import Foundation
import UserNotifications

public protocol NotificationDispatching: Sendable {
    func notifyWaitingForInput(sessionTitle: String, sessionID: UUID) async
    func notifySessionFinished(sessionTitle: String, sessionID: UUID) async
}

/// Real macOS notification via `UserNotifications`. Strictly observational
/// like the rest of HooksKit — it only ever posts a local notification, it
/// has no access to session process control.
public struct SystemNotificationDispatcher: NotificationDispatching {
    /// Must match `FlotillaNotificationDelegate.waitingForInputCategoryIdentifier`
    /// in the app target — the category (and its "Reply" action) is
    /// registered there, since `UNNotificationCategory` registration needs
    /// a delegate/app-lifecycle hook that HooksKit deliberately has no
    /// access to. Kept as a literal on both sides rather than a shared
    /// constant, since HooksKit cannot depend on the app target.
    public static let waitingForInputCategoryIdentifier = "WAITING_FOR_INPUT"

    public init() {}

    public func notifyWaitingForInput(sessionTitle: String, sessionID: UUID) async {
        let request = Self.waitingForInputRequest(sessionTitle: sessionTitle, sessionID: sessionID)
        try? await UNUserNotificationCenter.current().add(request)
    }

    public func notifySessionFinished(sessionTitle: String, sessionID: UUID) async {
        let request = Self.finishedRequest(sessionTitle: sessionTitle, sessionID: sessionID)
        try? await UNUserNotificationCenter.current().add(request)
    }

    /// Builds the request without posting it — separated out so the
    /// userInfo/threadIdentifier/categoryIdentifier it sets can be asserted
    /// on directly in a unit test, rather than only observable by way of a
    /// real (and in a test target, unauthorized) `UNUserNotificationCenter`.
    public static func waitingForInputRequest(sessionTitle: String, sessionID: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Needs Your Input"
        content.body = "\(sessionTitle) is waiting for a response."
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString
        content.categoryIdentifier = Self.waitingForInputCategoryIdentifier
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }

    public static func finishedRequest(sessionTitle: String, sessionID: UUID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "Session Finished"
        content.body = "\(sessionTitle) has finished."
        content.sound = .default
        content.userInfo = ["sessionID": sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString
        return UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    }
}
