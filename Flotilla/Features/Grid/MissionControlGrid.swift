import SwiftUI
import SessionKit
import DesignSystem

/// Design A — uniform tiles, terminal-dominant.
///
/// Every tile is the same size and carries exactly one bar of chrome. The
/// previous grid spent 56pt per tile on a 34pt header plus a 22pt footer; this
/// folds both into a single 28pt bar so the terminal keeps the rest, which is
/// what the grid exists to show.
struct MissionControlGrid: View {
    let sessions: [Session]
    let store: AppStore
    let terminalManager: TerminalManager
    let dimensions: GridDimensions
    let activeSessionID: UUID?
    /// "Dim unfocused sessions": every tile but the active one fades to
    /// `1 - dimIntensity` opacity while this is on.
    var dimEnabled: Bool = false
    var dimIntensity: Double = 0.4
    let actions: (Session) -> SessionTileActions

    var body: some View {
        GeometryReader { proxy in
            let layout = resolveGridLayout(
                containerSize: proxy.size,
                sessionCount: sessions.count,
                dimensions: dimensions
            )

            // Always a real vertical ScrollView: an empty axis set
            // (`ScrollView([])`) leaves the grid unable to place cells
            // beyond the first. When the content already fits, this simply
            // never scrolls.
            ScrollView(.vertical) {
                LazyVGrid(columns: layout.columns, spacing: GridLayoutMetrics.gutter) {
                    ForEach(sessions, id: \.id) { session in
                        let isActive = activeSessionID == session.id
                        MissionControlTile(
                            session: session,
                            store: store,
                            terminalManager: terminalManager,
                            isActive: isActive,
                            actions: actions(session)
                        )
                        .frame(height: layout.tileHeight)
                        .opacity(dimEnabled && !isActive ? 1 - dimIntensity : 1)
                        .animation(.easeOut(duration: 0.15), value: dimEnabled)
                        .animation(.easeOut(duration: 0.15), value: isActive)
                    }
                }
                .padding(GridLayoutMetrics.padding)
            }
        }
    }
}

private struct MissionControlTile: View {
    let session: Session
    let store: AppStore
    let terminalManager: TerminalManager
    let isActive: Bool
    let actions: SessionTileActions

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TileTerminalBody(
                session: session,
                store: store,
                terminalManager: terminalManager,
                isActive: isActive,
                onActivate: actions.onActivate,
                onRestart: actions.onRestart
            )
        }
        .sessionTileSurface(session: session, isActive: isActive, actions: actions)
    }

    /// The same `SessionBar` the focused session uses, in its `.tile`
    /// variant — so a session reads the same way in a tile as it does full
    /// screen, and the 28pt budget is unchanged. The bar handles its own
    /// truncation order; what it cannot fit is the worktree name, then the
    /// branch.
    ///
    /// Tap-to-activate stays on the bar itself, as it was on the header this
    /// replaces: SwiftUI gives the bar's own buttons and rename field the
    /// click first, and a tap target placed behind the bar would never see
    /// one at all, since the bar paints an opaque surface.
    private var header: some View {
        SessionBar(
            session: session,
            store: store,
            variant: .tile,
            actions: SessionBarActions(
                onRename: actions.onRename,
                onFocus: actions.onOpenSession,
                onRemoveFromGrid: actions.onRemoveFromGrid,
                // A tile has no inspector; the chip opens the session, whose
                // bar then leads to the Checks tab.
                onShowChecks: actions.onOpenSession
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.onActivate)
    }
}
