import SwiftUI
import SettingsKit
import DesignSystem

/// The customizable widget grid under Projects on Home. Places every widget
/// at an exact frame from `HomeWidgetGridGeometry` — cards never size
/// themselves — and runs the edit session: drag to move with live reflow,
/// corner handle to resize, gallery to add, Done/Cancel to finish.
struct HomeWidgetGrid: View {
    @Bindable var store: AppStore
    @Bindable var insights: HomeInsights
    let editor: HomeWidgetEditor
    let openSession: (UUID) -> Void

    @State private var width: CGFloat
    @State private var presentsGallery = false
    /// The widget the dragged card last swapped with — the reflow moves that
    /// widget out from under the pointer, and swapping back the instant it
    /// lands elsewhere would make the two oscillate.
    @State private var lastSwapTarget: UUID?
    @Environment(\.undoManager) private var undoManager

    /// `initialWidth` lets an offscreen render lay out at a known width;
    /// on screen the grid measures itself and updates immediately.
    init(store: AppStore, insights: HomeInsights, editor: HomeWidgetEditor, openSession: @escaping (UUID) -> Void, initialWidth: CGFloat = 0) {
        self.store = store
        self.insights = insights
        self.editor = editor
        self.openSession = openSession
        _width = State(initialValue: initialWidth)
    }

    private static let space = "HomeWidgetGrid"
    private static let reflow = Animation.spring(response: 0.32, dampingFraction: 0.86)

    private var geometry: HomeWidgetGridGeometry { HomeWidgetGridGeometry(width: width) }

    private var frames: [UUID: CGRect] {
        geometry.frames(for: editor.entries.map { ($0.id, editor.liveSize(of: $0), $0.resolvedKind) })
    }

    /// The union of every placed widget's data needs — what `HomeInsights`
    /// batch-loads, so adding a widget starts loading its data. Repo state
    /// is always included: the project cards above the grid show it.
    private var needs: Set<HomeDataNeed> {
        Set(editor.entries.compactMap(\.resolvedKind).flatMap(\.dataNeeds)).union([.repoState])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            header
            grid
        }
        .task(id: needs) {
            await insights.refresh(store: store, needs: needs)
        }
        .sheet(isPresented: $presentsGallery) {
            HomeWidgetGallerySheet(store: store, insights: insights, editor: editor)
        }
        .onAppear { editor.syncFromSettings() }
        .accessibilityIdentifier(AXID.homeWidgetGrid.rawValue)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            HomeSectionTitle("Your activity")
            Spacer(minLength: FlotillaSpacing.medium)
            if editor.isEditing {
                Button("Reset to Default") { editor.resetToDefault() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .accessibilityIdentifier(AXID.homeWidgetResetButton.rawValue)
                Button {
                    presentsGallery = true
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AXID.homeWidgetAddButton.rawValue)
                Button("Cancel") { withAnimation(Self.reflow) { editor.cancel() } }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Done") { withAnimation(Self.reflow) { editor.commit() } }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier(AXID.homeWidgetDoneButton.rawValue)
            } else {
                Button {
                    editor.beginEditing(undoManager: undoManager)
                } label: {
                    Label("Edit Widgets", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: .command)
                .help("Add, remove, resize and rearrange widgets (⌘E)")
                .accessibilityIdentifier(AXID.homeWidgetEditButton.rawValue)
            }
        }
        .controlSize(.regular)
    }

    // MARK: - Grid

    private var grid: some View {
        let geometry = geometry
        let frames = frames
        let contentHeight = geometry.height(of: frames)
        // An empty row below the widgets while editing: somewhere to drop a
        // widget at the end, and a visible hint of the grid's cells.
        let height = editor.isEditing ? contentHeight + (contentHeight > 0 ? HomeWidgetGridGeometry.gap : 0) + geometry.cell : contentHeight

        return ZStack(alignment: .topLeading) {
            if editor.isEditing {
                cellOutlines(geometry: geometry, height: height)
            }
            if let drag = editor.drag, let slot = frames[drag.id] {
                HomeWidgetCardMetrics.shape
                    .fill(FlotillaColors.accent.opacity(0.08))
                    .overlay(HomeWidgetCardMetrics.shape.strokeBorder(FlotillaColors.accent.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                    .frame(width: slot.width, height: slot.height)
                    .offset(x: slot.minX, y: slot.minY)
                    .animation(Self.reflow, value: slot)
            }
            ForEach(editor.entries) { entry in
                if let frame = frames[entry.id] {
                    card(entry, frame: frame, geometry: geometry, frames: frames)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .animation(Self.reflow, value: editor.isEditing)
    }

    private func card(_ entry: HomeWidgetEntry, frame: CGRect, geometry: HomeWidgetGridGeometry, frames: [UUID: CGRect]) -> some View {
        let drag = editor.drag?.id == entry.id ? editor.drag : nil
        let origin = drag?.origin ?? frame.origin
        let kind = entry.resolvedKind
        let resizable = (kind?.supportedSizes.count ?? 0) > 1
        return HomeWidgetView(
            entry: entry,
            size: editor.liveSize(of: entry),
            store: store,
            insights: insights,
            editor: editor,
            openSession: openSession,
            onResizeChanged: resizable ? { resizeChanged(entry, frame: frame, translation: $0, geometry: geometry) } : nil,
            onResizeEnded: resizable ? { resizeEnded(entry) } : nil
        )
        .frame(width: frame.width, height: frame.height)
        .scaleEffect(drag == nil ? 1 : 1.03)
        .shadow(color: .black.opacity(drag == nil ? 0 : 0.35), radius: drag == nil ? 0 : 18, y: drag == nil ? 0 : 10)
        .offset(x: origin.x, y: origin.y)
        .zIndex(drag == nil ? 0 : 1)
        .animation(drag == nil ? Self.reflow : nil, value: frame)
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .onChanged { moveChanged(entry, frame: frame, value: $0, frames: frames) }
                .onEnded { _ in moveEnded() },
            including: editor.isEditing ? .all : .subviews
        )
    }

    private func cellOutlines(geometry: HomeWidgetGridGeometry, height: CGFloat) -> some View {
        let rows = max(1, Int((height + HomeWidgetGridGeometry.gap) / (geometry.cell + HomeWidgetGridGeometry.gap)))
        return ForEach(0..<rows * geometry.columns, id: \.self) { index in
            let frame = geometry.frame(for: HomeWidgetRect(column: index % geometry.columns, row: index / geometry.columns, columnSpan: 1, rowSpan: 1))
            HomeWidgetCardMetrics.shape
                .strokeBorder(FlotillaColors.textPrimary.opacity(0.1), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .frame(width: frame.width, height: frame.height)
                .offset(x: frame.minX, y: frame.minY)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Move

    private func moveChanged(_ entry: HomeWidgetEntry, frame: CGRect, value: DragGesture.Value, frames: [UUID: CGRect]) {
        guard editor.isEditing else { return }
        if editor.drag == nil {
            editor.drag = .init(id: entry.id, startFrame: frame, translation: value.translation)
            lastSwapTarget = nil
        }
        editor.drag?.translation = value.translation

        let decision = HomeWidgetGridGeometry.moveTarget(
            pointer: value.location,
            dragged: entry.id,
            order: editor.entries.map(\.id),
            frames: frames,
            lastSwap: lastSwapTarget
        )
        lastSwapTarget = decision.lastSwap
        if let index = decision.index {
            withAnimation(Self.reflow) { editor.move(id: entry.id, to: index) }
        }
    }

    private func moveEnded() {
        lastSwapTarget = nil
        withAnimation(Self.reflow) { editor.drag = nil }
    }

    // MARK: - Resize

    private func resizeChanged(_ entry: HomeWidgetEntry, frame: CGRect, translation: CGSize, geometry: HomeWidgetGridGeometry) {
        guard editor.isEditing, let kind = entry.resolvedKind else { return }
        if editor.resize == nil {
            editor.resize = .init(id: entry.id, startSize: frame.size, proposedSize: editor.liveSize(of: entry))
        }
        guard let start = editor.resize?.startSize else { return }
        let target = CGSize(width: start.width + translation.width, height: start.height + translation.height)
        if let snapped = geometry.nearestSize(to: target, among: kind.supportedSizes, kind: kind), snapped != editor.resize?.proposedSize {
            withAnimation(Self.reflow) { editor.resize?.proposedSize = snapped }
        }
    }

    private func resizeEnded(_ entry: HomeWidgetEntry) {
        guard let resize = editor.resize, resize.id == entry.id else { return }
        withAnimation(Self.reflow) {
            editor.setSize(id: entry.id, to: resize.proposedSize)
            editor.resize = nil
        }
    }
}
