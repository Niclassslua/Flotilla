import SwiftUI
import SettingsKit

/// Owns the widget grid's layout and its edit session. Inside an edit
/// session changes collect in a draft that Done saves and Esc throws away;
/// outside one (a resize or setting changed from the context menu) every
/// change saves immediately.
@MainActor
@Observable
final class HomeWidgetEditor {
    /// A widget being dragged to a new position.
    struct Drag: Equatable {
        let id: UUID
        /// Where the card sat when the drag began, in grid coordinates.
        let startFrame: CGRect
        var translation: CGSize
        /// The card's top-left while dragging — the start frame moved by the
        /// pointer, independent of wherever the reflow has put its slot.
        var origin: CGPoint {
            CGPoint(x: startFrame.minX + translation.width, y: startFrame.minY + translation.height)
        }
    }

    /// A widget being resized from its corner handle.
    struct Resize: Equatable {
        let id: UUID
        let startSize: CGSize
        var proposedSize: HomeWidgetSize
    }

    private(set) var isEditing = false
    /// The live layout: what's saved outside edit mode, the draft within it.
    private(set) var entries: [HomeWidgetEntry]
    var drag: Drag?
    var resize: Resize?

    private let settings: SettingsBridge
    private var undoManager: UndoManager?
    private var committed: [HomeWidgetEntry]

    /// Narrow window onto `SettingsViewModel`, so tests can drive the
    /// editor without the whole settings stack.
    struct SettingsBridge {
        let get: () -> [HomeWidgetEntry]?
        let set: ([HomeWidgetEntry]?) -> Void
    }

    init(settings: SettingsBridge) {
        self.settings = settings
        let stored = settings.get() ?? HomeWidgetKind.defaultLayout
        entries = stored
        committed = stored
    }

    /// Re-reads the saved layout, e.g. after another window changed it.
    func syncFromSettings() {
        guard !isEditing else { return }
        let stored = settings.get() ?? HomeWidgetKind.defaultLayout
        entries = stored
        committed = stored
    }

    func beginEditing(undoManager: UndoManager?) {
        guard !isEditing else { return }
        isEditing = true
        self.undoManager = undoManager
        undoManager?.removeAllActions(withTarget: self)
    }

    /// Done: save the draft.
    func commit() {
        guard isEditing else { return }
        isEditing = false
        drag = nil
        resize = nil
        save()
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    /// Esc: discard the draft.
    func cancel() {
        guard isEditing else { return }
        isEditing = false
        drag = nil
        resize = nil
        entries = committed
        undoManager?.removeAllActions(withTarget: self)
        undoManager = nil
    }

    // MARK: - Mutations

    func add(kind: HomeWidgetKind, size: HomeWidgetSize? = nil) {
        let size = size.flatMap { kind.supportedSizes.contains($0) ? $0 : nil } ?? kind.defaultSize
        mutate(actionName: "Add Widget") { $0.append(HomeWidgetEntry(kind: kind.rawValue, size: size.rawValue)) }
    }

    func remove(id: UUID) {
        mutate(actionName: "Remove Widget") { $0.removeAll { $0.id == id } }
    }

    func move(id: UUID, to index: Int) {
        mutate(actionName: "Move Widget") { entries in
            guard let from = entries.firstIndex(where: { $0.id == id }) else { return }
            let entry = entries.remove(at: from)
            entries.insert(entry, at: min(max(index, 0), entries.count))
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

    func setSize(id: UUID, to size: HomeWidgetSize) {
        mutate(actionName: "Resize Widget") { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].size = size.rawValue
        }
    }

    func updateConfig(id: UUID, config: HomeWidgetConfig) {
        mutate(actionName: "Edit Widget") { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].config = config
        }
    }

    func resetToDefault() {
        mutate(actionName: "Reset to Default") { $0 = HomeWidgetKind.defaultLayout }
    }

    /// The size a widget lays out at right now: the handle's snapped
    /// proposal while it's being resized, else its saved size.
    func liveSize(of entry: HomeWidgetEntry) -> HomeWidgetSize {
        if let resize, resize.id == entry.id { return resize.proposedSize }
        return entry.resolvedSize ?? entry.resolvedKind?.defaultSize ?? .medium
    }

    // MARK: - Private

    private func save() {
        committed = entries
        settings.set(entries)
    }

    /// Every change goes through here: apply, register the inverse for ⌘Z
    /// inside an edit session, and save straight away outside one.
    private func mutate(actionName: String, _ change: (inout [HomeWidgetEntry]) -> Void) {
        let before = entries
        var after = entries
        change(&after)
        guard after != before else { return }
        entries = after
        guard isEditing else {
            save()
            return
        }
        undoManager?.setActionName(actionName)
        undoManager?.registerUndo(withTarget: self) { editor in
            editor.entries = before
            editor.undoManager?.setActionName(actionName)
            editor.undoManager?.registerUndo(withTarget: editor) { $0.entries = after }
        }
    }
}
