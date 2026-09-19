import SwiftUI
import SettingsKit

/// Owns the widget grid's edit session: a draft copy of the layout that only
/// commits to `WorkspacePreferences` on Done, so Esc can discard cleanly and
/// `NSUndoManager` has a stable place to register each change against.
@MainActor
@Observable
final class HomeWidgetEditor {
    private(set) var isEditing = false
    /// The live layout: the committed one outside edit mode, the draft while
    /// editing. The grid always renders this, never the settings value
    /// directly, so a discard never flashes the half-built draft on screen.
    private(set) var entries: [HomeWidgetEntry]

    /// Drag state for the widget currently being moved; `nil` at rest.
    var dragging: (id: UUID, translation: CGSize)?
    /// Resize state for the widget currently being resized; `nil` at rest.
    var resizing: (id: UUID, proposedSize: HomeWidgetSize)?

    private let settingsViewModel: SettingsViewModelBridge
    private var undoManager: UndoManager?
    private var committed: [HomeWidgetEntry]

    /// Narrow surface over `SettingsViewModel` so this type doesn't need to
    /// import the concrete settings view model or the app's `AppStore`.
    struct SettingsViewModelBridge {
        let get: () -> [HomeWidgetEntry]?
        let set: ([HomeWidgetEntry]?) -> Void
    }

    init(settingsViewModel: SettingsViewModelBridge) {
        self.settingsViewModel = settingsViewModel
        let stored = settingsViewModel.get() ?? HomeWidgetKind.defaultLayout
        self.entries = stored
        self.committed = stored
    }

    /// Re-reads the committed layout from settings, e.g. after Reset to
    /// Default is applied elsewhere or another window changed it.
    func syncFromSettings() {
        guard !isEditing else { return }
        let stored = settingsViewModel.get() ?? HomeWidgetKind.defaultLayout
        entries = stored
        committed = stored
    }

    func beginEditing(undoManager: UndoManager?) {
        guard !isEditing else { return }
        isEditing = true
        self.undoManager = undoManager
        undoManager?.removeAllActions(withTarget: self)
    }

    func commit() {
        guard isEditing else { return }
        isEditing = false
        dragging = nil
        resizing = nil
        committed = entries
        settingsViewModel.set(entries)
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    /// Esc: discard the draft, matching macOS widget editing.
    func cancel() {
        guard isEditing else { return }
        isEditing = false
        dragging = nil
        resizing = nil
        entries = committed
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    // MARK: - Mutations

    func add(kind: HomeWidgetKind) {
        mutate(actionName: "Add Widget") { $0.append(HomeWidgetEntry(kind: kind.rawValue, size: kind.defaultSize.rawValue)) }
    }

    func remove(id: UUID) {
        mutate(actionName: "Remove Widget") { $0.removeAll { $0.id == id } }
    }

    func move(id: UUID, to index: Int) {
        mutate(actionName: "Move Widget") { entries in
            guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
            let entry = entries.remove(at: from)
            let clamped = min(max(index, 0), entries.count)
            entries.insert(entry, at: clamped)
        }
    }

    func moveEarlier(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index > 0 else { return }
        move(id: id, to: index - 1)
    }

    func moveLater(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }), index < entries.count - 1 else { return }
        move(id: id, to: index + 1)
    }

    func resize(id: UUID, to size: HomeWidgetSize) {
        mutate(actionName: "Resize Widget") { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].size = size.rawValue
        }
    }

    /// A widget's settings can be opened and changed outside edit mode
    /// (right-click → Edit Widget…), so this both updates the live layout
    /// and — when there's no edit session open to fold it into — commits
    /// immediately, exactly as if Done had been pressed.
    func updateConfig(id: UUID, config: HomeWidgetConfig) {
        mutate(actionName: "Edit Widget") { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].config = config
        }
        guard !isEditing else { return }
        committed = entries
        settingsViewModel.set(entries)
    }

    func resetToDefault() {
        mutate(actionName: "Reset to Default") { $0 = HomeWidgetKind.defaultLayout }
    }

    /// Every mutation goes through here so undo is automatic: capture the
    /// pre-mutation snapshot, apply, then register the inverse.
    private func mutate(actionName: String, _ change: (inout [HomeWidgetEntry]) -> Void) {
        let before = entries
        var after = entries
        change(&after)
        guard after != before else { return }
        entries = after
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.entries = before
            editor.undoManager?.setActionName(actionName)
            editor.undoManager?.registerUndo(withTarget: editor) { redoTarget in
                redoTarget.entries = after
            }
        }
    }
}
