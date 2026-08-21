import SwiftUI
import DesignSystem

/// **Ledger** — a dense table with a docked inspector.
///
/// Hairline dividers, compact rows, columns of machine facts,
/// arrow-key navigation, and a detail pane that stays put while you move
/// through the list. Optimised for keyboard-first navigation and high information density.
struct LedgerDesign: View {
    let items: [KnowledgeItem]
    @Bindable var viewModel: ProjectKnowledgeViewModel
    let actions: KnowledgeActions

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                // Search, scope and sort belong to the list they act on, not to
                // a header spanning the inspector as well.
                KnowledgeListControls(viewModel: viewModel)
                table
            }
            .frame(minWidth: 360, idealWidth: 520, maxHeight: .infinity)

            detail
                .frame(minWidth: FlotillaLayoutWidth.inspectorMin, idealWidth: 620, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
    }

    // MARK: - Table

    /// Grouped by scope so global and project instructions never get confused
    /// for one another — that distinction changes what editing a file affects.
    private var groups: [(scope: KnowledgeScope, items: [KnowledgeItem])] {
        [KnowledgeScope.project, .global].compactMap { scope in
            let matching = items.filter { $0.scope == scope }
            return matching.isEmpty ? nil : (scope, matching)
        }
    }

    @ViewBuilder
    private var table: some View {
        if items.isEmpty {
            KnowledgeEmptyState(
                kind: viewModel.kind,
                filter: viewModel.filter,
                isSearching: !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FlotillaColors.canvas)
        } else {
            rows
        }
    }

    private var rows: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups, id: \.scope) { group in
                    Section {
                        ForEach(group.items) { item in
                            LedgerRow(
                                item: item,
                                isSelected: viewModel.selected?.id == item.id,
                                actions: actions
                            )
                            Divider().opacity(0.35)
                        }
                    } header: {
                        KnowledgeSectionHeader(title: group.scope.label, count: group.items.count)
                            .padding(.horizontal, FlotillaSpacing.medium)
                            .padding(.vertical, FlotillaSpacing.small)
                            .background(FlotillaColors.surface)
                            .overlay(alignment: .bottom) {
                                Divider()
                            }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("Knowledge.Ledger.Table")
        // Arrow keys move the selection without leaving the keyboard; the
        // inspector follows because selection lives on the view model.
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up: moveSelection(by: -1)
            case .down: moveSelection(by: 1)
            default: break
            }
        }
    }

    private func moveSelection(by offset: Int) {
        guard !items.isEmpty else { return }
        guard let current = viewModel.selected,
              let index = items.firstIndex(where: { $0.id == current.id })
        else {
            actions.open(items[0])
            return
        }
        let next = (index + offset).clamped(to: 0...(items.count - 1))
        guard next != index else { return }
        actions.open(items[next])
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
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

// MARK: - Row

private struct LedgerRow: View {
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
                KnowledgeIconTile(item: item, size: 22, isHighlighted: isHovered || isSelected)

                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(item.kind == .rules
                              ? .system(size: 12, weight: .medium, design: .monospaced)
                              : FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(item.subtitle)
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if let name = item.frameworkName {
                    Text(name)
                        .font(FlotillaTypography.caption3.weight(.medium))
                        .foregroundStyle(tint)
                        .frame(width: 56, alignment: .leading)
                        .lineLimit(1)
                }

                // Size gets its own column rather than sharing one with
                // whatever metric happened to come first — an empty file is
                // exactly what a table is good at making obvious.
                Text(formatByteSize(item.byteSize))
                    .font(FlotillaTypography.caption3.monospaced())
                    .foregroundStyle(item.byteSize == 0 ? FlotillaColors.warning : FlotillaColors.textTertiary)
                    .frame(width: 64, alignment: .trailing)

                Text(item.lastModified.map(formatRelativeDate) ?? "—")
                    .font(FlotillaTypography.caption3.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .frame(width: 62, alignment: .trailing)
            }
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.vertical, 6)
            .frame(height: 38)
            .background(rowBackground)
            .overlay(alignment: .leading) {
                // Selection is never colour alone: a fill, a leading bar, and
                // the `.isSelected` trait all say the same thing.
                Rectangle()
                    .fill(isSelected ? tint : .clear)
                    .frame(width: 2)
            }
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

    private var rowBackground: Color {
        if isSelected { return FlotillaColors.accent.opacity(FlotillaStateOpacity.selected) }
        if isHovered { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
