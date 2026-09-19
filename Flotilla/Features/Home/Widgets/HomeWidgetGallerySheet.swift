import SwiftUI
import SettingsKit
import DesignSystem

extension HomeWidgetKind {
    /// One line explaining what the widget shows, for the gallery.
    var subtitle: String {
        switch self {
        case .needsYou: "Sessions waiting on you, oldest first"
        case .reviewQueue: "Sessions ready for review, with their diff size"
        case .looseEnds: "Uncommitted work, unpushed commits and worktrees"
        case .agentScreenshots: "The newest screenshots your agents sent"
        case .streak: "Consecutive days with a commit"
        case .today: "Commits, lines and sessions started today"
        case .busiestHours: "When your fleet commits most"
        case .hotFiles: "The files changed most recently"
        case .topPermissions: "What agents ask permission for most"
        case .contributions: "A year of commits, one square per day"
        case .weeklyRhythm: "Lines added and removed by day"
        case .agentShare: "Which agents wrote your commits"
        case .codebaseGrowth: "Net lines added over time"
        }
    }
}

/// The **+** gallery, laid out like the macOS widget gallery: every widget
/// on the left, the selected one rendered live — your data, the chosen
/// size — on the right. Widgets can be added any number of times.
struct HomeWidgetGallerySheet: View {
    @Bindable var store: AppStore
    @Bindable var insights: HomeInsights
    let editor: HomeWidgetEditor
    @Environment(\.dismiss) private var dismiss

    @State private var selection: HomeWidgetKind
    @State private var size: HomeWidgetSize

    init(store: AppStore, insights: HomeInsights, editor: HomeWidgetEditor, initialSelection: HomeWidgetKind = .needsYou) {
        self.store = store
        self.insights = insights
        self.editor = editor
        _selection = State(initialValue: initialSelection)
        _size = State(initialValue: initialSelection.defaultSize)
    }

    /// Previews render at a real grid cell size, then scale to fit the pane,
    /// so what you see is exactly what lands on Home.
    private static let previewCell: CGFloat = 170

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 280)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 900, height: 600)
        .task {
            // Every kind's preview needs its data, not just what's placed.
            let all = Set(HomeWidgetKind.allCases.flatMap(\.dataNeeds))
            await insights.refresh(store: store, needs: all)
        }
        .accessibilityIdentifier(AXID.homeWidgetGallery.rawValue)
    }

    private var list: some View {
        List(HomeWidgetKind.allCases, selection: Binding(
            get: { selection },
            set: { newValue in
                guard let newValue else { return }
                selection = newValue
                size = newValue.defaultSize
            }
        )) { kind in
            HStack(spacing: FlotillaSpacing.small + 2) {
                Image(systemName: kind.glyph)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FlotillaColors.accent)
                    .frame(width: 26, height: 26)
                    .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(kind.title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(kind.subtitle)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 3)
            .tag(kind)
        }
        .listStyle(.sidebar)
    }

    private var detail: some View {
        VStack(spacing: FlotillaSpacing.large) {
            VStack(spacing: 4) {
                Text(selection.title)
                    .font(FlotillaTypography.title)
                Text(selection.subtitle)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            .padding(.top, FlotillaSpacing.xLarge)

            GeometryReader { proxy in
                let natural = previewSize(for: size)
                let scale = min(1, proxy.size.width / natural.width, proxy.size.height / natural.height)
                HomeWidgetView(
                    entry: HomeWidgetEntry(kind: selection.rawValue, size: size.rawValue),
                    size: size,
                    store: store,
                    insights: insights,
                    isPreview: true
                )
                .frame(width: natural.width, height: natural.height)
                .scaleEffect(scale)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .id("\(selection.rawValue)-\(size.rawValue)")
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)

            if selection.supportedSizes.count > 1 {
                Picker("Size", selection: $size) {
                    ForEach(selection.supportedSizes, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            } else {
                Text("\(size.label) only")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        editor.add(kind: selection, size: size)
                    }
                    dismiss()
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AXID.homeWidgetGalleryAddButton.rawValue + selection.rawValue)
            }
            .padding(FlotillaSpacing.large)
        }
    }

    private func previewSize(for size: HomeWidgetSize) -> CGSize {
        let cell = Self.previewCell
        let gap = HomeWidgetGridGeometry.gap
        switch size {
        case .small: return CGSize(width: cell, height: cell)
        case .medium: return CGSize(width: cell * 2 + gap, height: cell)
        case .large:
            let cols = selection.columnSpan(for: size)
            let rows = selection.rowSpan(for: size)
            let width = cell * CGFloat(cols) + gap * CGFloat(cols - 1)
            let height = cell * CGFloat(rows) + gap * CGFloat(rows - 1)
            return CGSize(width: width, height: height)
        case .wide:
            let rows = selection.rowSpan(for: size)
            let height = rows > 1 ? cell * CGFloat(rows) + gap * CGFloat(rows - 1) : cell
            return CGSize(width: cell * 4 + gap * 3, height: height)
        }
    }
}
