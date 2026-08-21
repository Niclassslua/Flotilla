import SwiftUI
import SessionKit

/// Skills tab for a project workspace.
///
/// A thin host: everything visual lives in `KnowledgeCatalogView` and the four
/// designs behind it, which the Rules tab shares. Skills add no header controls
/// of their own — there is no "create a skill" flow, since a skill is a folder
/// with a bundle in it rather than a single file we could template.
struct ProjectSkillsView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectKnowledgeViewModel

    init(
        project: Project,
        store: AppStore,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.project = project
        self.store = store
        self._viewModel = State(initialValue: ProjectKnowledgeViewModel(
            kind: .skills,
            projectRoot: project.rootPath,
            service: service
        ))
    }

    var body: some View {
        KnowledgeCatalogView(viewModel: viewModel)
            .accessibilityIdentifier(AXID.projectSkills.rawValue)
    }
}
