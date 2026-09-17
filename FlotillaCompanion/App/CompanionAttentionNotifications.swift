import Foundation
import UserNotifications
import CompanionKit

/// Local preview of attention events received over the live Mac connection.
/// The encrypted socket is suspended with the app, so this cannot deliver a
/// new event while the phone is asleep; that needs a push transport.
@MainActor
final class CompanionAttentionNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = CompanionAttentionNotifications()

    private enum ID {
        static let permission = "flotilla.attention.permission"
        static let generic = "flotilla.attention.generic"
        static let approve = "flotilla.attention.approve"
        static let deny = "flotilla.attention.deny"
        static let view = "flotilla.attention.view"
    }

    private weak var store: CompanionStore?

    func configure(store: CompanionStore) {
        self.store = store
        let approve = UNNotificationAction(identifier: ID.approve, title: "Approve")
        let deny = UNNotificationAction(identifier: ID.deny, title: "Deny", options: [.destructive])
        let view = UNNotificationAction(identifier: ID.view, title: "View Session", options: [.foreground])
        let permission = UNNotificationCategory(
            identifier: ID.permission, actions: [approve, deny, view], intentIdentifiers: [], options: []
        )
        let generic = UNNotificationCategory(
            identifier: ID.generic, actions: [view], intentIdentifiers: [], options: []
        )
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([permission, generic])
        Task { try? await center.requestAuthorization(options: [.alert, .badge, .sound]) }
        if let remote = store.data as? RemoteCompanionDataSource {
            remote.onAttention = { [weak self] macID, event in
                self?.post(event, macID: macID)
            }
        }
    }

    private func post(_ event: SessionAttentionEvent, macID: String) {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.summary
        content.sound = .default
        content.categoryIdentifier = event.permissionID == nil ? ID.generic : ID.permission
        content.userInfo = [
            "macID": macID,
            "sessionID": event.sessionID.uuidString,
            "permissionID": event.permissionID?.uuidString ?? ""
        ]
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "attention.\(event.sessionID.uuidString).\(UUID().uuidString)", content: content, trigger: nil)
        )
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let sessionID = (info["sessionID"] as? String).flatMap(UUID.init(uuidString:))
        let permissionID = (info["permissionID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        completionHandler()
        Task { @MainActor in
            guard let sessionID, let store = Self.shared.store else { return }
            if action == ID.approve || action == ID.deny {
                guard let permissionID,
                      let card = store.pendingInteractions(for: sessionID).first(where: { $0.id == permissionID }),
                      case .permission(let request) = card.kind,
                      action != ID.deny || request.allowsDenyAndStop != false else { return }
                _ = await store.answer(permissionID, in: sessionID, with: action == ID.approve ? .allow : .deny)
            } else if let macID = store.mac(forSession: sessionID)?.id {
                store.path = [.fleet(macID), .session(sessionID)]
            }
        }
    }
}
