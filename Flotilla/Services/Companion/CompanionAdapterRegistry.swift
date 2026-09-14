import Foundation
import SessionKit
import CompanionKit
import HooksKit

@MainActor
final class CompanionAdapterRegistry {
    private let support: URL
    var screen: ((UUID) async -> String?)?
    var send: ((UUID, Data) -> Void)?
    var bridge: ClaudePermissionBridge?
    private var adapters: [UUID: any CompanionSessionAdapter] = [:]
    private var refreshing: Set<UUID> = []
    var onChange: (() -> Void)?

    init(support: URL) { self.support = support }

    func adapter(for session: Session) -> (any CompanionSessionAdapter)? {
        if let adapter = adapters[session.id] {
            adapter.session = session
            return adapter
        }
        if session.agent == .claudeCode, let screen, let send, let bridge {
            let adapter = ClaudeCompanionAdapter(session: session, bridge: bridge, support: support, screen: screen, send: { send(session.id, $0) })
            adapters[session.id] = adapter; return adapter
        }
        guard let descriptor = CompanionRuntimeDescriptor.read(session.id, support: support) else { return nil }
        let adapter: any CompanionSessionAdapter
        switch session.agent {
        case .codexCLI:
            adapter = CodexCompanionAdapter(session: session, endpoint: descriptor.endpoint, screen: screen.map { screen in { await screen(session.id) } }, send: send.map { send in { send(session.id, $0) } })
        case .openCode: adapter = OpenCodeCompanionAdapter(session: session, descriptor: descriptor)
        case .antigravity:
            guard let screen, let send else { return nil }
            adapter = AntigravityCompanionAdapter(session: session, descriptor: descriptor, support: support, screen: screen, send: { send(session.id, $0) })
        default: return nil
        }
        adapters[session.id] = adapter
        return adapter
    }

    func refresh(_ sessions: [Session]) async {
        let valid = Set(sessions.map(\.id))
        for id in Array(adapters.keys) where !valid.contains(id) { remove(id) }
        for session in sessions where !refreshing.contains(session.id) {
            guard let adapter = adapter(for: session) else { continue }
            refreshing.insert(session.id)
            Task { [weak self] in
                try? await adapter.refresh()
                self?.refreshing.remove(session.id)
                self?.onChange?()
            }
        }
        onChange?()
    }

    func pending(_ session: Session) -> [PendingInteraction] { adapter(for: session)?.pending ?? [] }
    func remove(_ id: UUID) { adapters.removeValue(forKey: id)?.close() }
    func close() { for adapter in adapters.values { adapter.close() }; adapters.removeAll() }
}
