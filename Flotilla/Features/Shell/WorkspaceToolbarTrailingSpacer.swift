import AppKit
import SwiftUI

/// Installs the flexible AppKit toolbar space that SwiftUI currently drops
/// between its navigation and automatic placement sections on macOS.
///
/// `ToolbarItemPlacement.primaryAction` is leading on macOS, while the
/// explicitly trailing SwiftUI placements are unavailable there. Keeping the
/// buttons themselves in SwiftUI and inserting only AppKit's standard flexible
/// space gives the global action group a stable trailing position.
struct WorkspaceToolbarTrailingSpacer: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WorkspaceToolbarSpacerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? WorkspaceToolbarSpacerView)?.scheduleInstallation()
    }
}

@MainActor
private final class WorkspaceToolbarSpacerView: NSView {
    private var installationTask: Task<Void, Never>?

    deinit {
        installationTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleInstallation()
    }

    func scheduleInstallation() {
        installationTask?.cancel()
        installationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // SwiftUI assembles the window toolbar over several layout turns.
            // Retry briefly so the action items exist before locating them.
            for delay in [
                Duration.zero,
                .milliseconds(50),
                .milliseconds(150),
                .milliseconds(500),
                .seconds(1)
            ] {
                if delay > .zero {
                    try? await Task.sleep(for: delay)
                } else {
                    await Task.yield()
                }
                guard !Task.isCancelled else { return }
                installIfPossible()
            }
        }
    }

    private func installIfPossible() {
        guard let toolbar = window?.toolbar,
              !toolbar.items.contains(where: { $0.itemIdentifier == .flexibleSpace }),
              let actionIndex = firstGlobalActionIndex(in: toolbar) else { return }

        toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: actionIndex)
    }

    private func firstGlobalActionIndex(in toolbar: NSToolbar) -> Int? {
        if let identifiedIndex = toolbar.items.firstIndex(where: isGridAction) {
            return identifiedIndex
        }

        // SwiftUI currently emits each button in the four-button group as its
        // own native toolbar item. This fallback keeps the bridge resilient if
        // the private item identifiers stop carrying accessibility metadata.
        guard toolbar.items.count >= 4 else { return nil }
        return toolbar.items.count - 4
    }

    private func isGridAction(_ item: NSToolbarItem) -> Bool {
        let identifier = AXID.toolbarShowGrid.rawValue
        if item.itemIdentifier.rawValue.contains(identifier) ||
            item.label == "Session grid" ||
            item.toolTip == "Session grid" {
            return true
        }

        guard let view = item.view else { return false }
        return containsAccessibilityIdentifier(identifier, in: view)
    }

    private func containsAccessibilityIdentifier(_ identifier: String, in view: NSView) -> Bool {
        if view.accessibilityIdentifier() == identifier {
            return true
        }
        return view.subviews.contains { containsAccessibilityIdentifier(identifier, in: $0) }
    }
}
