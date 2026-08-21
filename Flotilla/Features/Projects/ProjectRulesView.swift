import SwiftUI
import SessionKit
import DesignSystem

/// Rules tab for a project workspace.
///
/// A thin host over the shared `KnowledgeCatalogView`, plus the one control
/// Skills has no equivalent of: an "Add Template" menu that seeds a starter
/// AGENTS.md / CLAUDE.md / etc. into the project root, since an empty project
/// otherwise gives the user nothing to click.
struct ProjectRulesView: View {
    let project: Project
    @Bindable var store: AppStore

    @State private var viewModel: ProjectKnowledgeViewModel
    @State private var createdFileName: String?

    init(
        project: Project,
        store: AppStore,
        service: any WorkspaceFileServicing = WorkspaceFileService()
    ) {
        self.project = project
        self.store = store
        self._viewModel = State(initialValue: ProjectKnowledgeViewModel(
            kind: .rules,
            projectRoot: project.rootPath,
            service: service
        ))
    }

    var body: some View {
        KnowledgeCatalogView(viewModel: viewModel) {
            templateMenu
        }
        .accessibilityIdentifier(AXID.projectRules.rawValue)
        .overlay(alignment: .bottomTrailing) {
            if let createdFileName {
                createdToast(createdFileName)
            }
        }
    }

    private var templateMenu: some View {
        Menu {
            ForEach(KnowledgeTemplate.allCases) { template in
                Button(template.menuTitle) {
                    create(template)
                }
            }
        } label: {
            Label("Add Template", systemImage: "plus.bubble")
                .font(FlotillaTypography.caption)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier(AXID.knowledgeAddTemplate.rawValue)
    }

    /// Writes the template, then opens it. An existing file is opened rather
    /// than overwritten, and only a genuinely new file raises the toast.
    private func create(_ template: KnowledgeTemplate) {
        Task {
            let didCreate = await viewModel.createTemplate(
                named: template.fileName,
                content: template.content(projectName: project.name)
            )
            guard didCreate else { return }

            withAnimation(FlotillaMotion.snappy.curve) {
                createdFileName = template.fileName
            }
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation(FlotillaMotion.snappy.curve) {
                createdFileName = nil
            }
        }
    }

    private func createdToast(_ fileName: String) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(FlotillaColors.success)
            Text("Created \(fileName)")
                .font(FlotillaTypography.caption.weight(.medium))
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.success.opacity(0.4), lineWidth: FlotillaBorderWidth.thin)
        }
        .padding(FlotillaSpacing.large)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
