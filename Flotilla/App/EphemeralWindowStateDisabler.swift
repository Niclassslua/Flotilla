#if FLOTILLA_EPHEMERAL
import AppKit
import SwiftUI

/// Prevents AppKit's automatic geometry persistence from defeating the clean
/// launch semantics of the Ephemeral build.
///
/// SwiftUI gives its `WindowGroup` and `NavigationSplitView` native autosave
/// names. Scene restoration controls do not disable the latter, so this small
/// bridge clears both names after the AppKit hierarchy exists and applies the
/// requested sidebar width once. The user can still resize the sidebar for
/// the remainder of the launch; that adjustment is deliberately not saved.
struct EphemeralWindowStateDisabler: NSViewRepresentable {
    let initialSidebarWidth: CGFloat
    let shouldShowSidebar: Bool

    func makeNSView(context: Context) -> NSView {
        EphemeralStateView(
            initialSidebarWidth: initialSidebarWidth,
            shouldShowSidebar: shouldShowSidebar
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let stateView = nsView as? EphemeralStateView else { return }
        stateView.initialSidebarWidth = initialSidebarWidth
        stateView.shouldShowSidebar = shouldShowSidebar
        stateView.scheduleConfiguration()
    }
}

@MainActor
private final class EphemeralStateView: NSView {
    var initialSidebarWidth: CGFloat
    var shouldShowSidebar: Bool

    private weak var navigationSplitView: NSSplitView?
    private var hasAppliedInitialSidebarWidth = false
    private var configurationTask: Task<Void, Never>?

    init(initialSidebarWidth: CGFloat, shouldShowSidebar: Bool) {
        self.initialSidebarWidth = initialSidebarWidth
        self.shouldShowSidebar = shouldShowSidebar
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        configurationTask?.cancel()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleConfiguration()
    }

    func scheduleConfiguration() {
        configurationTask?.cancel()
        configurationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // SwiftUI creates and expands the native sidebar over multiple
            // layout turns. Retry briefly so the divider is set only after
            // its leading subview has become visible.
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
                configureIfPossible()
            }
        }
    }

    private func configureIfPossible() {
        guard let window else { return }
        disablePersistence(for: window)

        if navigationSplitView == nil, let contentView = window.contentView {
            navigationSplitView = findNavigationSplitView(in: contentView)
        }
        guard let navigationSplitView else { return }

        disablePersistence(for: navigationSplitView)
        applyInitialSidebarWidthIfPossible(to: navigationSplitView)
    }

    private func disablePersistence(for window: NSWindow) {
        window.isRestorable = false
        window.disableSnapshotRestoration()

        let autosaveName = window.frameAutosaveName
        guard !autosaveName.isEmpty else { return }
        window.setFrameAutosaveName("")
        NSWindow.removeFrame(usingName: autosaveName)
    }

    private func disablePersistence(for splitView: NSSplitView) {
        guard let autosaveName = splitView.autosaveName, !autosaveName.isEmpty else { return }
        splitView.autosaveName = nil
        UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames \(autosaveName)")
    }

    private func applyInitialSidebarWidthIfPossible(to splitView: NSSplitView) {
        guard shouldShowSidebar,
              !hasAppliedInitialSidebarWidth,
              splitView.subviews.count >= 2,
              !splitView.isSubviewCollapsed(splitView.subviews[0]) else { return }

        splitView.layoutSubtreeIfNeeded()
        let minimum = splitView.minPossiblePositionOfDivider(at: 0)
        let maximum = splitView.maxPossiblePositionOfDivider(at: 0)
        let target = min(max(initialSidebarWidth, minimum), maximum)
        splitView.setPosition(target, ofDividerAt: 0)
        hasAppliedInitialSidebarWidth = true
    }

    private func findNavigationSplitView(in view: NSView) -> NSSplitView? {
        if let splitView = view as? NSSplitView,
           splitView.autosaveName?.contains("SidebarNavigationSplitView") == true {
            return splitView
        }

        for subview in view.subviews {
            if let match = findNavigationSplitView(in: subview) {
                return match
            }
        }
        return nil
    }
}
#endif
