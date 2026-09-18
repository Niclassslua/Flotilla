import SwiftUI
import AppKit
import SessionKit
import DesignSystem
import SettingsKit

/// Renders every `LauncherStyle` to PNG and quits, for side-by-side review.
///
/// Launch a Debug build with `UI_TESTING=1 FLOTILLA_LAUNCHER_SNAPSHOTS=<dir>`
/// (fixture projects, no real agents). Offscreen rendering can't sample a
/// backdrop, so the glass surface is drawn opaque in these images.
#if DEBUG
@MainActor
enum LauncherSnapshotRenderer {
    static func renderIfRequested(store: AppStore) {
        guard let path = ProcessInfo.processInfo.environment["FLOTILLA_LAUNCHER_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for variant in LauncherStyle.allCases {
                await render(variant, store: store, to: directory)
            }
            exit(0)
        }
    }

    private static func render(_ variant: LauncherStyle, store: AppStore, to directory: URL) async {
        let draft = SessionDraft(
            store: store,
            initialProject: store.projects.first { $0.name == "Flotilla" } ?? store.projects.first,
            initialGoal: "Fix the flaky login redirect test and add coverage for expired sessions",
            createWorktreeByDefault: true,
            fetchBeforeCreatingWorktree: false,
            defaultAgent: .claudeCode,
            openCodeSubscription: .none
        )
        let actions = SessionLauncherActions(launch: { _ in }, cancel: {})
        let root = LauncherStyleBody(style: variant, draft: draft, store: store, actions: actions)
            .frame(width: variant.launcherWidth)
            .padding(48)
            .background(FlotillaColors.canvas)
            .environment(\.launcherSnapshot, true)
            .environment(\.colorScheme, .dark)

        let hosting = NSHostingView(rootView: root)
        hosting.appearance = NSAppearance(named: .darkAqua)
        let size = hosting.fittingSize
        hosting.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: CGRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(500))
        // Set after the view is live so `onChange` fires, e.g. `@` to capture
        // the project search open.
        if let goal = ProcessInfo.processInfo.environment["FLOTILLA_LAUNCHER_SNAPSHOT_GOAL"] {
            draft.goal = goal
            try? await Task.sleep(for: .milliseconds(300))
            let fitted = hosting.fittingSize
            hosting.frame = CGRect(origin: .zero, size: fitted)
            window.setContentSize(fitted)
        }
        try? await Task.sleep(for: .milliseconds(300))
        hosting.layoutSubtreeIfNeeded()

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let index = LauncherStyle.allCases.firstIndex(of: variant) ?? 0
        let name = "\(index)-\(variant.rawValue).png"
        try? rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent(name))
        window.orderOut(nil)
    }
}
#endif
