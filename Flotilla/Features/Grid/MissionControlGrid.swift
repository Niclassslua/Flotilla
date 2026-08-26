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

    private var header: some View {
        HStack(spacing: 8) {
            TileTitleLockup(session: session, showsProviderName: false)

            Spacer(minLength: 8)

            // Meta collapses before the title does: at narrow widths the
            // branch name is the first thing worth losing.
            TileMetaRow(session: session, store: store, showsElapsed: false)
                .layoutPriority(-1)
                .frame(maxWidth: 160)

            TileFocusButton(session: session, action: actions.onOpenSession)
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(FlotillaColors.surface)
        .contentShape(Rectangle())
        .onTapGesture(perform: actions.onActivate)
    }
}
