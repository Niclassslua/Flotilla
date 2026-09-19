import SwiftUI
import SettingsKit
import DesignSystem

/// Reorders on drop: entering another widget's drop target live-moves the
/// dragged widget to that position, so the grid reflows as you drag rather
/// than only settling on release.
private struct HomeWidgetDropDelegate: DropDelegate {
    let targetID: UUID
    let editor: HomeWidgetEditor

    func dropEntered(info: DropInfo) {
        guard let draggingID = editor.dragging?.id, draggingID != targetID,
              let targetIndex = editor.entries.firstIndex(where: { $0.id == targetID }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            editor.move(id: draggingID, to: targetIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        editor.dragging = nil
        return true
    }
}

/// Only active in edit mode, so a stray click-drag on a widget's normal
/// content (the heatmap, the growth chart's project chips) never starts a
/// reorder outside edit mode.
private struct HomeWidgetDragReorderModifier: ViewModifier {
    let entryID: UUID
    let editor: HomeWidgetEditor

    func body(content: Content) -> some View {
        if editor.isEditing {
            content
                .onDrag {
                    editor.dragging = (entryID, .zero)
                    return NSItemProvider(object: entryID.uuidString as NSString)
                }
                .onDrop(of: [.text], delegate: HomeWidgetDropDelegate(targetID: entryID, editor: editor))
        } else {
            content
        }
    }
}

/// The customizable widget grid that replaced the fixed "Your activity"
/// section. Owns the `HomeWidgetEditor` edit session and the shared
/// `HomeInsights` refresh, driven by the union of every placed widget's
/// data needs.
struct HomeWidgetGrid: View {
    @Bindable var store: AppStore
    @Bindable var settingsViewModel: SettingsViewModel
    @Bindable var insights: HomeInsights
    let openSession: (UUID) -> Void

    @State private var editor: HomeWidgetEditor
    @State private var presentsGallery = false
    @Environment(\.undoManager) private var undoManager

    init(store: AppStore, settingsViewModel: SettingsViewModel, insights: HomeInsights, openSession: @escaping (UUID) -> Void) {
        self.store = store
        self.settingsViewModel = settingsViewModel
        self.insights = insights
        self.openSession = openSession
        _editor = State(initialValue: HomeWidgetEditor(settingsViewModel: HomeWidgetEditor.SettingsViewModelBridge(
            get: { settingsViewModel.settings.workspace.homeWidgets },
            set: { settingsViewModel.settings.workspace.homeWidgets = $0 }
        )))
    }

    /// The union of every placed widget's data needs — what `HomeInsights`
    /// batch-loads. Recomputed whenever the layout changes, so adding Hot
    /// files starts loading file churn without a separate trigger.
    private var needs: Set<HomeDataNeed> {
        Set(editor.entries.compactMap(\.resolvedKind).flatMap(\.dataNeeds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            header
            HomeWidgetGridLayout {
                ForEach(editor.entries) { entry in
                    HomeWidgetView(entry: entry, store: store, insights: insights, editor: editor, openSession: openSession)
                        .modifier(HomeWidgetDragReorderModifier(entryID: entry.id, editor: editor))
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.86), value: editor.entries)
        }
        .task(id: needs) {
            await insights.refresh(store: store, needs: needs)
        }
        .sheet(isPresented: $presentsGallery) {
            HomeWidgetGallerySheet(editor: editor)
        }
        .onAppear { editor.syncFromSettings() }
        .onKeyPress(.escape) {
            guard editor.isEditing else { return .ignored }
            editor.cancel()
            return .handled
        }
        .accessibilityIdentifier(AXID.homeWidgetGrid.rawValue)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: FlotillaSpacing.small) {
            HomeSectionTitle("Your activity")
            Spacer(minLength: FlotillaSpacing.medium)
            if editor.isEditing {
                Button("Reset to Default", role: .destructive) { editor.resetToDefault() }
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .accessibilityIdentifier(AXID.homeWidgetResetButton.rawValue)
                Button {
                    presentsGallery = true
                } label: {
                    Label("Add Widget", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(AXID.homeWidgetAddButton.rawValue)
                Button("Done") { editor.commit() }
                    .buttonStyle(.borderedProminent)
                    .tint(FlotillaColors.accent)
                    .accessibilityIdentifier(AXID.homeWidgetDoneButton.rawValue)
            } else {
                Button {
                    editor.beginEditing(undoManager: undoManager)
                } label: {
                    Label("Edit Widgets", systemImage: "square.grid.2x2")
                }
                .buttonStyle(.bordered)
                .keyboardShortcut("e", modifiers: .command)
                .accessibilityIdentifier(AXID.homeWidgetEditButton.rawValue)
            }
        }
        .controlSize(.regular)
        .contextMenu {
            if editor.isEditing {
                Button("Done") { editor.commit() }
            } else {
                Button("Edit Widgets…") { editor.beginEditing(undoManager: undoManager) }
            }
        }
    }
}
