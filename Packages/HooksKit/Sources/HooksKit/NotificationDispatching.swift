import Foundation
import UserNotifications

public protocol NotificationDispatching: Sendable {
    func notifyWaitingForInput(sessionTitle: String) async
}

/// Real macOS notification via `UserNotifications`. Strictly observational
/// like the rest of HooksKit — it only ever posts a local notification, it
/// has no access to session process control.
public struct SystemNotificationDispatcher: NotificationDispatching {
    public init() {}

    public func notifyWaitingForInput(sessionTitle: String) async {
        let content = UNMutableNotificationContent()
        content.title = "Needs Your Input"
        content.body = "\(sessionTitle) is waiting for a response."
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
