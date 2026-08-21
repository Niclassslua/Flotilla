import SwiftUI
import DesignSystem

/// The shared host behind both the Skills and the Rules tab.
///
/// Owns everything cross-cutting — the header bar, search, the scope filter,
/// the design switcher, loading and empty states, and the detail plumbing — so
/// each of the four designs is purely a way of laying items out.
struct KnowledgeCatalogView<HeaderExtra: View>: View {
    @Bindable var viewModel: ProjectKnowledgeViewModel
    @ViewBuilder var headerExtra: () -> HeaderExtra

    @AppStorage(KnowledgeDesign.storageKey) private var storedDesign = KnowledgeDesign.atlas.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Set only by the designs that float their detail; the docked designs read
    /// `viewModel.selected` directly.
    @State private var modalItem: KnowledgeItem?

    private var design: Binding<KnowledgeDesign> {
        Binding(
            get: { KnowledgeDesign(rawValue: storedDesign) ?? .atlas },
            set: { storedDesign = $0.rawValue }
        )
    }

    private var items: [KnowledgeItem] { viewModel.filteredItems }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }

            if let modalItem {
                modalOverlay(for: modalItem)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .task(id: viewModel.projectRoot) {
            await viewModel.load()
        }
        // Leaving a floating design with something open shouldn't strand the
        // selection in a design that has nowhere to show it.
        .onChange(of: storedDesign) { _, _ in
            modalItem = nil
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            HStack(spacing: FlotillaSpacing.small) {
                Text(viewModel.kind.title)
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)

                Text("\(items.count)")
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: Capsule())
                    .accessibilityLabel("\(items.count) \(viewModel.kind.title)")
            }

            Spacer(minLength: FlotillaSpacing.small)

            // Split designs dock these above their own list column instead —
            // see `KnowledgeDesign.usesInlineListControls`.
            if !design.wrappedValue.usesInlineListControls {
                KnowledgeSearchField(
                    prompt: viewModel.kind.searchPrompt,
                    text: $viewModel.searchText
                )
                .frame(width: 220)

                KnowledgeScopePicker(filter: $viewModel.filter)
                    .frame(width: 190)

                KnowledgeSortMenu(sort: $viewModel.sort)
                    .controlSize(.small)
            }

            headerExtra()

            KnowledgeDesignPicker(selection: design)

            Button {
                Task { await viewModel.load() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.plain)
            .help("Refresh \(viewModel.kind.title.lowercased())")
            .accessibilityLabel("Refresh")
            .accessibilityIdentifier(AXID.knowledgeRefresh.rawValue)
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .background(FlotillaColors.surface)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("Scanning \(viewModel.kind.title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlotillaColors.canvas)
        } else if items.isEmpty && !design.wrappedValue.usesInlineListControls {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(FlotillaColors.canvas)
        } else {
            // Split designs render their own empty state inside the list
            // column: replacing the whole surface would take the search field
            // with it, leaving no way to undo a query that matched nothing.
            designBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        KnowledgeEmptyState(
            kind: viewModel.kind,
            filter: viewModel.filter,
            isSearching: !viewModel.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    @ViewBuilder
    private var designBody: some View {
        switch design.wrappedValue {
        case .atlas:
            AtlasDesign(items: items, actions: actions)
        case .ledger:
            LedgerDesign(items: items, viewModel: viewModel, actions: actions)
        case .shelf:
            ShelfDesign(items: items, viewModel: viewModel, actions: actions)
        case .constellation:
            ConstellationDesign(items: items, actions: actions)
        }
    }

    // MARK: - Detail

    private var actions: KnowledgeActions {
        .standard { item in
            Task {
                await viewModel.select(item)
                guard !design.wrappedValue.usesInlineDetail else { return }
                withAnimation(reduceMotion ? nil : FlotillaMotion.spring.curve) {
                    modalItem = item
                }
            }
        }
    }

    private func modalOverlay(for item: KnowledgeItem) -> some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .onTapGesture { closeModal() }
                .accessibilityHidden(true)

            KnowledgeDetailView(
                item: item,
                viewModel: viewModel,
                actions: actions,
                presentation: .modal,
                onClose: closeModal
            )
            .frame(
                minWidth: 580, idealWidth: 760, maxWidth: 880,
                minHeight: 480, idealHeight: 640, maxHeight: 800
            )
            .background(FlotillaColors.surface)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                    .strokeBorder(FlotillaColors.separator.opacity(0.8), lineWidth: FlotillaBorderWidth.thin)
            }
            .flotillaShadow(.level3)
            .padding(FlotillaSpacing.large)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
    }

    private func closeModal() {
        withAnimation(reduceMotion ? nil : FlotillaMotion.fast.curve) {
            modalItem = nil
        }
        viewModel.deselect()
    }
}

extension KnowledgeCatalogView where HeaderExtra == EmptyView {
    init(viewModel: ProjectKnowledgeViewModel) {
        self.init(viewModel: viewModel) { EmptyView() }
    }
}
