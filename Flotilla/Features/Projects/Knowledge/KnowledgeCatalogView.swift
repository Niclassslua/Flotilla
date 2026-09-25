import SwiftUI
import DesignSystem

/// The shared host behind both the Skills and the Rules tab.
///
/// Owns everything cross-cutting — the header bar, loading states,
/// and hosting the Ledger design with docked inspector.
struct KnowledgeCatalogView<HeaderExtra: View>: View {
    @Bindable var viewModel: ProjectKnowledgeViewModel
    @ViewBuilder var headerExtra: () -> HeaderExtra

    private var items: [KnowledgeItem] { viewModel.filteredItems }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .task(id: viewModel.projectRoot) {
            await viewModel.load()
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

            headerExtra()

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
        .flotillaLiquidSurface(FlotillaColors.surface, glassTintOpacity: FlotillaGlassTint.elevated)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView("Scanning \(viewModel.kind.title.lowercased())…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LedgerDesign(items: items, viewModel: viewModel, actions: actions)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Actions

    private var actions: KnowledgeActions {
        .standard { item in
            Task {
                await viewModel.select(item)
            }
        }
    }
}

extension KnowledgeCatalogView where HeaderExtra == EmptyView {
    init(viewModel: ProjectKnowledgeViewModel) {
        self.init(viewModel: viewModel) { EmptyView() }
    }
}

