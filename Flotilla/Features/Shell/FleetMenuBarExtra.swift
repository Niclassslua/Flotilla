import SwiftUI
import AppKit
import SessionKit
import DesignSystem

/// The status item's icon: a sailboat, followed by the number of waiting
/// sessions when there are any, so the menu bar says "something needs you"
/// without opening anything.
struct FleetMenuBarLabel: View {
    let store: AppStore

    var body: some View {
        let waitingCount = FleetAttention(sessions: store.sessions, ciFailing: store.ciStatusStore.failingSessionIDs).waiting.count
        HStack(spacing: 3) {
            Image(systemName: waitingCount > 0 ? "sailboat.fill" : "sailboat")
            if waitingCount > 0 {
                Text("\(waitingCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityLabel(waitingCount > 0 ? "Flotilla, \(waitingCount) waiting" : "Flotilla")
    }
}

/// The status item's menu: every session that wants something, grouped by
/// what it wants, each one a jump straight to its terminal.
struct FleetMenuBarMenu: View {
    let store: AppStore
    let navigator: WorkspaceNavigator
    @Environment(\.openWindow) private var openWindow

    /// A working fleet can be large; the menu is for triage, not a full
    /// session list, so each group stops at this many rows.
    private static let rowLimit = 8

    var body: some View {
        let attention = FleetAttention(sessions: store.sessions, ciFailing: store.ciStatusStore.failingSessionIDs)

        if attention.waiting.isEmpty && attention.readyForReview.isEmpty && attention.crashed.isEmpty {
            Text(attention.working.isEmpty ? "No sessions need you" : "All clear · \(attention.working.count) working")
        }
        group("Needs You", attention.waiting, ciFailing: attention.ciFailing)
        group("Ready for Review", attention.readyForReview)
        group("Crashed", attention.crashed)
        if !attention.working.isEmpty,
           !(attention.waiting.isEmpty && attention.readyForReview.isEmpty && attention.crashed.isEmpty) {
            Text("\(attention.working.count) working")
        }

        Divider()
        Button("Open Flotilla") { showMainWindow() }
        Button("New Session…") {
            showMainWindow()
            navigator.presentedSheet = .createSession
        }
        Divider()
        SettingsLink { Text("Settings…") }
        Button("Quit Flotilla") { NSApp.terminate(nil) }
    }

    @ViewBuilder
    private func group(_ title: String, _ sessions: [Session], ciFailing: Set<UUID> = []) -> some View {
        if !sessions.isEmpty {
            Section(title) {
                ForEach(sessions.prefix(Self.rowLimit)) { session in
                    Button {
                        showMainWindow()
                        navigator.selection = .session(session.id)
                    } label: {
                        if ciFailing.contains(session.id), session.status != .waitingForInput {
                            Label(rowTitle(for: session, ciFailing: true), systemImage: "xmark.seal")
                        } else {
                            Label(rowTitle(for: session), systemImage: StatusPresentation.glyph(for: session.status, waitingReason: session.waitingReason))
                        }
                    }
                }
                if sessions.count > Self.rowLimit {
                    Text("\(sessions.count - Self.rowLimit) more…")
                }
            }
        }
    }

    private func rowTitle(for session: Session, ciFailing: Bool = false) -> String {
        var parts = [session.title]
        if let project = store.project(for: session) {
            parts.append(project.name)
        }
        if ciFailing {
            let check = store.ciStatusStore.status(for: session.id)?.failingChecks.first?.name
            parts.append(check.map { "CI failing: \($0)" } ?? "CI failing")
        } else if session.status == .waitingForInput {
            parts.append(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
        }
        return parts.joined(separator: " · ")
    }

    /// Brings the workspace window forward, reopening it if it was closed —
    /// the app keeps running without windows, and the menu must still land
    /// somewhere.
    private func showMainWindow() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(FlotillaApp.mainWindowSceneID) == true && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: FlotillaApp.mainWindowSceneID)
        }
    }
}
