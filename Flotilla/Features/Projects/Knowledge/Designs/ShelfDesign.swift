import SwiftUI
import DesignSystem

/// **Shelf** — a source-list rail beside a permanent reading pane.
///
/// Built on the premise that these files are read far more often than they are
/// browsed. The rail is a narrow index grouped by scope and then by the agent
/// that owns them; the pane is the document, given the full remaining width and
/// a capped measure so prose stays readable.
///
/// Strengths: no navigation to reach content — the first item opens on arrival,
/// and the reading experience is the best of the four. Weakness: the rail shows
/// only names, so discovering an unfamiliar skill by description means clicking.
struct ShelfDesign: View {
    let items: [KnowledgeItem]
    @Bindable var viewModel: ProjectKnowledgeViewModel
    let actions: KnowledgeActions

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                KnowledgeListControls(viewModel: viewModel, isNarrow: true)
                rail
            }
            .frame(
                minWidth: FlotillaLayoutWidth.sidebarMin,
                idealWidth: FlotillaLayoutWidth.sidebarIdeal,
                maxWidth: FlotillaLayoutWidth.sidebarMax,
                maxHeight: .infinity
            )

            reader
                .frame(minWidth: 420, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        // A reading surface with nothing to read is a dead end — open the first
        // item on arrival, and again whenever filtering strands the selection.
        .task(id: items.map(\.id)) {
            guard let first = items.first else { return }
            if viewModel.selected == nil || !items.contains(where: { $0.id == viewModel.selected?.id }) {
                actions.open(first)
            }
        }
    }

    // MARK: - Rail

    /// Scope first (it changes what an edit affects), then the owning agent
    /// within it. Rules have no framework, so they fall into one group per
    /// scope and the second level collapses away on its own.
    private var groups: [ShelfGroup] {
        var result: [ShelfGroup] = []
        for scope in [KnowledgeScope.project, .global] {
            let scoped = items.filter { $0.scope == scope }
            guard !scoped.isEmpty else { continue }

            let bucketNames = scoped
                .map { $0.source ?? $0.frameworkName ?? scope.label.capitalized }
                .reduced()

            for name in bucketNames {
                let bucket = scoped.filter { ($0.source ?? $0.frameworkName ?? scope.label.capitalized) == name }
                result.append(ShelfGroup(scope: scope, title: name, items: bucket))
            }
        }
        return result
    }

    @ViewBuilder
    private var rail: some View {
        if items.isEmpty {
            KnowledgeEmptyState(
                kind: viewModel.kind,
                filter: viewModel.filter,
                isSearching: !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.sidebar)
        } else {
            railList
        }
    }

    private var railList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.items) { item in
                            ShelfRailRow(
                                item: item,
                                isSelected: viewModel.selected?.id == item.id,
                                actions: actions
                            )
                        }
                    } header: {
                        KnowledgeSectionHeader(title: group.title, count: group.items.count)
                            .padding(.horizontal, FlotillaSpacing.medium)
                            .padding(.top, FlotillaSpacing.medium)
                            .padding(.bottom, FlotillaSpacing.small)
                            .background(FlotillaColors.sidebar)
                    }
                }
            }
            .padding(.bottom, FlotillaSpacing.medium)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.sidebar)
        .accessibilityIdentifier("Knowledge.Shelf.Rail")
    }

    // MARK: - Reader

    @ViewBuilder
    private var reader: some View {
        if let selected = viewModel.selected {
            KnowledgeDetailView(
                item: selected,
                viewModel: viewModel,
                actions: actions,
                presentation: .docked,
                onClose: { viewModel.deselect() }
            )
        } else {
            KnowledgeNoSelectionView(kind: viewModel.kind)
        }
    }
}

private struct ShelfGroup: Identifiable {
    let scope: KnowledgeScope
    let title: String
    let items: [KnowledgeItem]

    var id: String { "\(scope.rawValue)-\(title)" }
}

// MARK: - Rail row

private struct ShelfRailRow: View {
    let item: KnowledgeItem
    let isSelected: Bool
    let actions: KnowledgeActions

    @State private var isHovered = false

    private var tint: Color {
        if let framework = item.framework {
            return AgentBrand.accentColor(for: framework)
        }
        return FlotillaColors.accent
    }

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                KnowledgeIconTile(item: item, size: 20, isHighlighted: isHovered || isSelected)

                Text(item.title)
                    .font(item.kind == .rules
                          ? .system(size: 11.5, design: .monospaced)
                          : FlotillaTypography.caption)
                    .foregroundStyle(isSelected ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(background)
                    .overlay {
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .strokeBorder(
                                isSelected ? tint.opacity(0.45) : .clear,
                                lineWidth: FlotillaBorderWidth.thin
                            )
                    }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .withFlotillaMotion(.fast, value: isSelected)
        .help(item.subtitle)
        .accessibilityLabel("\(item.title), \(item.scopeLabel)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier(AXID.knowledgeItem.rawValue + item.title)
        .contextMenu {
            Button("Open in Default App") { actions.openExternally(item.url) }
            if let invocation = item.invocation {
                Button("Copy Invocation") { actions.copy(invocation) }
            }
        }
    }

    private var background: Color {
        if isSelected { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovered { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }
}

private extension Array where Element == String {
    /// Distinct values in first-seen order — keeps rail groups in the order the
    /// scanner found them rather than reshuffling alphabetically.
    func reduced() -> [String] {
        var seen: Set<String> = []
        return filter { seen.insert($0).inserted }
    }
}
