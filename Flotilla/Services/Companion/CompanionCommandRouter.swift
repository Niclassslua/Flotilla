import Foundation
import SessionKit
import GitKit
import CompanionKit

/// Carries out a phone's request with the same `AppStore` and `GitService`
/// calls the Mac's own UI makes.
@MainActor
final class CompanionCommandRouter {
    private let store: AppStore
    private let gitService: any GitServiceProtocol
    private let bridge: ClaudePermissionBridge
    private let adapters: CompanionAdapterRegistry?

    nonisolated static let maximumFileSize = 1_000_000

    init(store: AppStore, gitService: any GitServiceProtocol, bridge: ClaudePermissionBridge, adapters: CompanionAdapterRegistry? = nil) {
        self.store = store
        self.gitService = gitService
        self.bridge = bridge
        self.adapters = adapters
    }

    func handle(_ request: CompanionRequest) async -> CompanionResponse {
        switch request {
        case .sendPrompt(let sessionID, let text):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            guard !bridge.hasPending(sessionID) else {
                return .failure(message: "Answer the open dialog first.")
            }
            do {
                if let adapter = adapters?.adapter(for: session) { try await adapter.sendPrompt(text) }
                else { try await store.deliverMessage(text, to: sessionID) }
                return .ok
            } catch {
                return .failure(message: "The prompt couldn't be delivered: \(error.localizedDescription)")
            }

        case .stop(let sessionID):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            if let adapter = adapters?.adapter(for: session) {
                do { try await adapter.stop(); return .ok }
                catch { return .failure(message: error.localizedDescription) }
            }
            if bridge.denyAndStop(sessionID: sessionID) { return .ok }
            guard let process = store.process(for: sessionID) else {
                return .failure(message: "The agent isn't running.")
            }
            // Escape interrupts the current turn in every supported agent
            // (docs/companion.md, A10).
            process.send(input: Data([0x1B]))
            return .ok

        case .answer(let sessionID, let interactionID, let answer):
            if let session = session(sessionID), let adapter = adapters?.adapter(for: session) {
                do { return .answer(try await adapter.answer(interactionID, with: answer)) }
                catch { return .failure(message: error.localizedDescription) }
            }
            return .answer(bridge.answer(sessionID: sessionID, interactionID: interactionID, with: answer))

        case .createSession(let request):
            let project = request.projectID.flatMap { id in store.projects.first { $0.id == id } }
            if request.projectID != nil, project == nil {
                return .failure(message: "That project no longer exists on the Mac.")
            }
            let choice: ProjectChoice = project.map { .known($0) } ?? .general
            let goal = request.goal.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = await store.createSession(
                title: SessionLaunchPreview.derivedTitle(goal: goal, projectChoice: choice),
                goal: goal,
                agent: request.agent,
                model: request.model.isEmpty ? nil : request.model,
                effort: request.agent.supportsEffortSelection ? request.effort : nil,
                initialMode: request.initialMode,
                projectFolder: project?.rootPath,
                checkoutMode: request.createWorktree && project != nil ? .newWorktree : .mainCheckout,
                deliverGoal: !goal.isEmpty,
                fetchBeforeCreatingWorktree: request.fetchFirst,
                selectAfterCreating: false
            )
            if let created { return .created(sessionID: created) }
            return .failure(message: store.lastCreationError ?? "The session couldn't be created.")

        case .handoff(let sessionID, let handoff):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            guard store.handoffTargets(for: session).contains(handoff.agent) else {
                return .failure(message: "\(session.agent.displayName) can't hand off to \(handoff.agent.displayName).")
            }
            bridge.retractAll(sessionID: sessionID)
            adapters?.remove(sessionID)
            await store.handoffSession(sessionID: sessionID, to: handoff.agent)
            return store.lastOperationError.map { .failure(message: $0) } ?? .ok

        case .restart(let sessionID):
            guard session(sessionID) != nil else { return .failure(message: Self.missingSession) }
            bridge.retractAll(sessionID: sessionID)
            adapters?.remove(sessionID)
            store.restartSession(sessionID: sessionID)
            return store.lastOperationError.map { .failure(message: $0) } ?? .ok

        case .delete(let sessionID, let removeWorktree):
            guard session(sessionID) != nil else { return .ok }
            bridge.retractAll(sessionID: sessionID)
            adapters?.remove(sessionID)
            await store.deleteSession(sessionID: sessionID, deleteWorktree: removeWorktree)
            guard session(sessionID) == nil else {
                return .failure(message: store.lastOperationError ?? "The session couldn't be deleted.")
            }
            return .ok

        case .diff(let sessionID, let commitHash):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            do {
                if let commitHash {
                    let detail = try await gitService.commitDetail(sha: commitHash, at: session.workingDirectory)
                    return .diff(CompanionSnapshotBuilder.fileDiffs(detail.files))
                }
                let changes = try await gitService.uncommittedChanges(at: session.workingDirectory)
                return .diff(CompanionSnapshotBuilder.fileDiffs(changes))
            } catch {
                return .failure(message: "Changes aren't available: \(error.localizedDescription)")
            }

        case .commits(let sessionID):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            do {
                let log = try await gitService.log(at: session.workingDirectory, ref: nil, skip: 0, maxCount: 50)
                let unpushed = (try? await gitService.unpushedSHAs(at: session.workingDirectory, ref: nil)) ?? []
                return .commits(CompanionSnapshotBuilder.commits(log, unpushed: unpushed))
            } catch {
                return .failure(message: "Commits aren't available: \(error.localizedDescription)")
            }

        case .file(let sessionID, let path):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            let directory = session.workingDirectory
            let contents = await Task.detached(priority: .utility) {
                Self.readFile(path, in: directory)
            }.value
            return .file(contents: contents)

        case .filePage(let sessionID, let path, let offset, let maxBytes):
            guard let session = session(sessionID) else { return .failure(message: Self.missingSession) }
            guard offset >= 0, maxBytes > 0, maxBytes <= 256 * 1024 else {
                return .failure(message: "Invalid file page.")
            }
            let directory = session.workingDirectory
            let page = await Task.detached(priority: .utility) {
                Self.readFilePage(path, in: directory, offset: offset, maxBytes: maxBytes)
            }.value
            guard let page else { return .failure(message: "The file couldn't be read.") }
            return .filePage(contents: page.contents, nextOffset: page.nextOffset, isComplete: page.isComplete)
        }
    }

    private func session(_ id: UUID) -> Session? {
        store.sessions.first { $0.id == id }
    }

    static let missingSession = "That session no longer exists on the Mac."

    /// Reads a text file inside the session's directory. Anything resolving
    /// outside it — `..`, an absolute path, a symlink out — is refused.
    nonisolated static func readFile(_ path: String, in directory: URL) -> String? {
        guard let page = readFilePage(path, in: directory, offset: 0, maxBytes: maximumFileSize), page.isComplete else { return nil }
        return page.contents
    }

    nonisolated static func readFilePage(_ path: String, in directory: URL, offset: Int, maxBytes: Int) -> (contents: String, nextOffset: Int?, isComplete: Bool)? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : root.appendingPathComponent(path))
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= maximumFileSize, offset <= size,
              let handle = try? FileHandle(forReadingFrom: candidate) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        var data = try? handle.read(upToCount: min(maxBytes, size - offset))
        while let candidate = data, !candidate.isEmpty, String(data: candidate, encoding: .utf8) == nil {
            data?.removeLast()
        }
        guard let data, let text = String(data: data, encoding: .utf8), !data.isEmpty || offset == size else { return nil }
        let next = offset + data.count
        return (text, next < size ? next : nil, next >= size)
    }
}
