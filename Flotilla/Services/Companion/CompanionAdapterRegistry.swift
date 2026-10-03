import Foundation
import SessionKit
import CompanionKit
import HooksKit

@MainActor
final class CompanionAdapterRegistry {
    private let support: URL
    var screen: ((UUID) async -> String?)?
    var send: ((UUID, Data) -> Void)?
    /// Submits a prompt through the tmux-backed delivery path
    /// (`AppStore.deliverMessage`). Raw PTY writes only *type* into an
    /// agent's composer; this is the path that also *submits*.
    var deliver: ((UUID, String) async throws -> Void)?
    var bridge: ClaudePermissionBridge?
    private var adapters: [UUID: any CompanionSessionAdapter] = [:]
    private var refreshing: Set<UUID> = []
    private var publishTask: Task<Void, Never>?
    var onChange: (() -> Void)?

    init(support: URL) { self.support = support }

    func adapter(for session: Session) -> (any CompanionSessionAdapter)? {
        if let adapter = adapters[session.id] {
            adapter.session = session
            return adapter
        }
        if session.agent == .claudeCode || session.agent == .cursorAgent, let screen, let send, let bridge {
            let adapter: any CompanionSessionAdapter
            if session.agent == .cursorAgent {
                // Without the tmux-backed delivery seam there is no way to
                // submit a phone prompt; returning nil lets the router fall
                // back to `AppStore.deliverMessage` directly.
                guard let deliver else { return nil }
                adapter = CursorCompanionAdapter(session: session, screen: screen, send: { send(session.id, $0) }, deliver: { try await deliver(session.id, $0) })
            } else {
                adapter = ClaudeCompanionAdapter(session: session, bridge: bridge, support: support, screen: screen, send: { send(session.id, $0) })
            }
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
        case .claudeCode, .cursorAgent:
            return nil
        }
        if let codex = adapter as? CodexCompanionAdapter {
            codex.onChange = { [weak self] in self?.schedulePublish() }
        }
        if let openCode = adapter as? OpenCodeCompanionAdapter {
            openCode.onChange = { [weak self] in self?.schedulePublish() }
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
                self?.schedulePublish()
            }
        }
    }

    private func schedulePublish() {
        guard publishTask == nil else { return }
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(75))
            guard !Task.isCancelled else { return }
            self?.publishTask = nil
            self?.onChange?()
        }
    }

    func pending(_ session: Session) -> [PendingInteraction] { adapter(for: session)?.pending ?? [] }

    func suppressesTerminalFallback(for session: Session) -> Bool {
        adapter(for: session)?.suppressesTerminalFallback ?? false
    }
    func remove(_ id: UUID) { adapters.removeValue(forKey: id)?.close() }
    func close() { publishTask?.cancel(); publishTask = nil; for adapter in adapters.values { adapter.close() }; adapters.removeAll() }
}
