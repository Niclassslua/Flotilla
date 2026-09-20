// The Ephemeral configuration compiles with `FLOTILLA_EPHEMERAL` but *not*
// `DEBUG` (its `SWIFT_ACTIVE_COMPILATION_CONDITIONS` inherits nothing), and
// the ephemeral binary is exactly the one this sweep runs — hence both.
#if DEBUG || FLOTILLA_EPHEMERAL
import AppKit
import SwiftUI

/// Writes a PNG of the app's own window and quits. Used to compare the
/// navigator design explorations (`FLOTILLA_SIDEBAR_DESIGN`) without a human
/// at the keyboard.
///
/// It captures through `cacheDisplay(in:to:)` on the window's own content
/// view rather than `screencapture` or `CGWindowListCreateImage`: a process
/// drawing its own view hierarchy needs no Screen Recording grant, and the
/// existing `VocabularyScreenshotUITests` pipeline has to be driven from
/// Xcode, which is the wrong shape for a four-variant sweep.
enum SidebarShotCapture {
    private static let destination = ProcessInfo.processInfo.environment["FLOTILLA_SIDEBAR_SHOT"]

    static var isRequested: Bool { destination != nil }

    /// Idempotent: the modifier below can fire more than once per launch.
    nonisolated(unsafe) private static var hasRun = false

    @MainActor
    static func runIfRequested() {
        guard let destination, !hasRun else { return }
        hasRun = true
        note("armed for \(destination)")

        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            // Long enough for the fixture fleet to land and the window to
            // settle before anything is measured.
            try? await Task.sleep(for: .seconds(3))
            capture(to: URL(fileURLWithPath: destination))
            NSApp.terminate(nil)
        }
    }

    /// The navigator's own view, 360pt wide and fully laid out even when the
    /// window presents it collapsed.
    ///
    /// An ephemeral window starts collapsed — restoration is disabled, so
    /// AppKit has no saved split position and parks the split view at a
    /// negative `minX`, putting the sidebar outside the window. `toggleSidebar:`
    /// does not move it (SwiftUI owns the split state through
    /// `navigator.columnVisibility`). It does not need to: the sidebar pane is
    /// a laid-out view either way, so the shot is taken on that view directly
    /// instead of on the window.
    @MainActor
    private static func sidebarView(in root: NSView) -> NSView? {
        guard let split = findSplitView(root) else { return nil }
        // Two item wrappers, one per column. The narrow one is the navigator;
        // the wide one is the detail column.
        let wrappers = split.subviews
            .filter { String(describing: type(of: $0)).contains("SplitViewItemViewWrapper") }
            .sorted { $0.frame.width < $1.frame.width }
        guard let sidebar = wrappers.first, sidebar.frame.width > 1 else { return nil }
        return sidebar
    }

    @MainActor
    private static func findSplitView(_ view: NSView) -> NSSplitView? {
        if let split = view as? NSSplitView { return split }
        for subview in view.subviews {
            if let found = findSplitView(subview) { return found }
        }
        return nil
    }

    @MainActor
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let content = window.contentView
        else {
            note("no capturable window")
            return
        }

        let view = sidebarView(in: content) ?? content
        note("capturing \(type(of: view)) \(view.bounds)")

        guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            note("no bitmap representation")
            return
        }
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let png = representation.representation(using: .png, properties: [:]) else {
            note("PNG encoding failed")
            return
        }
        write(png, to: url)
    }

    /// Diagnostic: which views the window actually has, and where.
    private static func dumpHierarchy(_ view: NSView, depth: Int = 0) {
        guard depth < 7 else { return }
        note(String(repeating: "  ", count: depth)
            + "\(type(of: view)) frame=\(view.frame) hidden=\(view.isHidden) layer=\(view.layer != nil)")
        for subview in view.subviews { dumpHierarchy(subview, depth: depth + 1) }
    }

    private static func write(_ png: Data, to url: URL) {
        do {
            try png.write(to: url)
            note("wrote \(url.path)")
        } catch {
            note("\(error)")
        }
    }

    /// A GUI app launched from a shell re-execs through its debug dylib, so
    /// stderr does not reliably reach the terminal. The log lands beside the
    /// screenshot instead.
    private static func note(_ message: String) {
        NSLog("[sidebar-shot] %@", message)
        guard let destination else { return }
        let log = URL(fileURLWithPath: destination).deletingPathExtension().appendingPathExtension("log")
        let line = Data((message + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: log)
        }
    }
}
#endif
