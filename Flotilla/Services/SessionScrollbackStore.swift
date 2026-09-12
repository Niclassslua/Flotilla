import Foundation
import SessionKit

/// Deliberately not observable: PTY output must not invalidate session views.
@MainActor
final class SessionScrollbackStore {
    private var buffers: [UUID: Data] = [:]
    private var saveTasks: [UUID: Task<Void, Never>] = [:]
    private var versions: [UUID: Int] = [:]
    private let maximumBytes = 256 * 1_024
    private let trimSlack = 64 * 1_024

    deinit { for task in saveTasks.values { task.cancel() } }

    func seed(_ sessions: [Session]) {
        for session in sessions where buffers[session.id] == nil {
            buffers[session.id] = session.terminalScrollback
        }
    }

    func buffer(for id: UUID) -> Data? { buffers[id] }

    func merging(_ session: Session) -> Session {
        guard let buffer = buffers[session.id] else { return session }
        var snapshot = session
        snapshot.terminalScrollback = buffer
        return snapshot
    }

    func append(_ data: Data, to id: UUID, save: @escaping @MainActor () async -> Void) {
        // Append in place; trim with slack to avoid copying the buffer per chunk.
        buffers[id, default: Data()].append(data)
        if let buffer = buffers[id], buffer.count > maximumBytes + trimSlack {
            buffers[id] = Data(buffer.suffix(maximumBytes))
        }
        versions[id, default: 0] += 1
        let currentVersion = versions[id]!
        saveTasks[id]?.cancel()
        saveTasks[id] = Task {
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled, self.versions[id] == currentVersion else { return }
            await save()
        }
    }

    func remove(_ id: UUID) {
        saveTasks.removeValue(forKey: id)?.cancel()
        buffers[id] = nil
        versions[id] = nil
    }

    func cancelPendingSaves() {
        for task in saveTasks.values { task.cancel() }
        saveTasks.removeAll()
    }
}
