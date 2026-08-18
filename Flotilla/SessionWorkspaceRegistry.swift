import SwiftUI
import Observation
import SessionKit
import GitKit
import DesignSystem

@Observable
@MainActor
final class SessionWorkspaceRegistry {
    private let gitService: GitServiceProtocol
    private let store: AppStore

    private var diffViewModels: [UUID: DiffPanelViewModel] = [:]
    private var fileBrowserViewModels: [UUID: FileBrowserViewModel] = [:]
    private var rulesViewModels: [UUID: RulesPanelViewModel] = [:]

    init(store: AppStore, gitService: GitServiceProtocol) {
        self.store = store
        self.gitService = gitService
    }

    func diffViewModel(for session: Session) -> DiffPanelViewModel {
        if let existing = diffViewModels[session.id] {
            return existing
        }
        let vm = DiffPanelViewModel(session: session, gitService: gitService)
        diffViewModels[session.id] = vm
        return vm
    }

    func fileBrowserViewModel(for session: Session) -> FileBrowserViewModel {
        if let existing = fileBrowserViewModels[session.id] {
            return existing
        }
        let vm = FileBrowserViewModel(root: workspaceRoot(for: session), service: WorkspaceFileService())
        fileBrowserViewModels[session.id] = vm
        return vm
    }

    func rulesViewModel(for session: Session) -> RulesPanelViewModel {
        if let existing = rulesViewModels[session.id] {
            return existing
        }
        let vm = RulesPanelViewModel(root: workspaceRoot(for: session), service: WorkspaceFileService())
        rulesViewModels[session.id] = vm
        return vm
    }

    func releaseSession(_ sessionID: UUID) {
        diffViewModels[sessionID]?.cancelMonitoring()
        diffViewModels.removeValue(forKey: sessionID)
        fileBrowserViewModels.removeValue(forKey: sessionID)
        rulesViewModels.removeValue(forKey: sessionID)
    }

    private func workspaceRoot(for session: Session) -> URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }
}