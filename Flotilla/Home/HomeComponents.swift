import SwiftUI
import SessionKit
import SettingsKit
import DesignSystem

// MARK: - Shared Context

/// Everything the home screen's sections need, bundled so each keeps a
/// one-line signature. `AppStore` and `SessionActivityStore` are `@Observable`,
/// so reads inside a `body` still register for change tracking even though they
/// arrive wrapped in a plain struct.
struct HomeContext {
    let store: AppStore
    let settings: AppSettings
    let activityStore: SessionActivityStore?
    let openCodeSubscription: OpenCodeSubscription
    let defaultAgent: AgentKind
    let openProject: (UUID) -> Void
    let openSession: (UUID) -> Void
}

// MARK: - Fleet Statistics

/// Session counts by status, computed once per render rather than by filtering
/// `store.sessions` repeatedly at each call site the way `DetailColumn` does.
struct HomeFleetStats {
    let total: Int
    private let counts: [SessionStatus: Int]

    init(sessions: [Session]) {
        total = sessions.count
        counts = sessions.reduce(into: [:]) { $0[$1.status, default: 0] += 1 }
    }

    func count(_ status: SessionStatus) -> Int {
        counts[status] ?? 0
    }

    /// Statuses that actually occur, in `StatusPresentation.attentionOrder` so
    /// the most actionable state always reads first.
    var presentStatuses: [SessionStatus] {
        StatusPresentation.attentionOrder.filter { count($0) > 0 }
    }

    var needsAttention: Int { count(.waitingForInput) }
    var working: Int { count(.working) }
    var crashed: Int { count(.crashed) }

    /// One-line summary for the window subtitle and compact strips.
    var summary: String {
        guard total > 0 else { return "No sessions yet" }
        let parts = presentStatuses.map { "\(count($0)) \(StatusPresentation.compactLabel(for: $0))" }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Live Data Budget

/// `DiffStatStore` spends three git subprocesses per watched session every 8s
/// and `SessionActivityStore` polls tmux every 2s, so the home screen only ever
/// wires live telemetry to a bounded set: whatever needs attention first, then
/// the most recently active. Everything else renders statically.
enum HomeLiveData {
    static let budget = 6

    static func eligibleSessionIDs(in sessions: [Session]) -> Set<UUID> {
        let prioritized = sessions.sorted { lhs, rhs in
            let lhsUrgent = lhs.status == .waitingForInput
            let rhsUrgent = rhs.status == .waitingForInput
            if lhsUrgent != rhsUrgent { return lhsUrgent }
            return lhs.lastActiveAt > rhs.lastActiveAt
        }
        return Set(prioritized.prefix(budget).map(\.id))
    }
}

// MARK: - Session Ordering

@MainActor
extension HomeContext {
    var fleetStats: HomeFleetStats {
        HomeFleetStats(sessions: store.sessions)
    }

    /// Sessions blocked on a human, most urgent first. Crashed sessions form a
    /// secondary tier — they need a decision too, just not an answer.
    var attentionSessions: [Session] {
        let waiting = store.sessions
            .filter { $0.status == .waitingForInput }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        let crashed = store.sessions
            .filter { $0.status == .crashed }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
        return waiting + crashed
    }

    /// Most-recent sessions, excluding anything already surfaced in the
    /// attention queue. Beyond avoiding a duplicated row, this keeps
    /// `SessionActivityStore` correct: its `watch` is not refcounted, so the
    /// same session appearing twice would let one row's `onDisappear` cancel
    /// the other row's polling.
    func recentSessions(limit: Int) -> [Session] {
        let attentionIDs = Set(attentionSessions.map(\.id))
        return store.sessions
            .filter { !attentionIDs.contains($0.id) }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .prefix(limit)
            .map { $0 }
    }

    /// Projects ordered by their most recently active session, so the list
    /// reorders as work moves. `Project` carries no timestamp of its own.
    func recentProjects(limit: Int) -> [Project] {
        store.projects
            .sorted { lhs, rhs in
                let lhsDate = store.sessions(for: lhs).map(\.lastActiveAt).max() ?? .distantPast
                let rhsDate = store.sessions(for: rhs).map(\.lastActiveAt).max() ?? .distantPast
                if lhsDate == rhsDate { return lhs.name < rhs.name }
                return lhsDate > rhsDate
            }
            .prefix(limit)
            .map { $0 }
    }
}

// MARK: - Timestamp Formatting

enum HomeTimestamp {
    /// "now" / "5m" / "3h" / "2d" — matches the register `SessionCard` uses.
    static func compact(_ date: Date) -> String {
        let elapsed = Date().timeIntervalSince(date)
        switch elapsed {
        case ..<60: return "now"
        case ..<3600: return "\(Int(elapsed / 60))m"
        case ..<86_400: return "\(Int(elapsed / 3600))h"
        default: return "\(Int(elapsed / 86_400))d"
        }
    }
}

// MARK: - Activity Line

/// The agent's most recent terminal line. Only rendered for sessions that are
/// actually producing output — a finished session's last line is stale noise.
struct HomeActivityLine: View {
    let session: Session
    let activityStore: SessionActivityStore?
    var font: Font = FlotillaTypography.caption2

    private var isLive: Bool {
        session.status == .working || session.status == .waitingForInput
    }

    var body: some View {
        Group {
            if isLive, let line = activityStore?.lastOutputLine(for: session.id) {
                Text(line)
                    .font(font.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .onAppear {
            if isLive { activityStore?.watch(session.id) }
        }
        .onDisappear {
            activityStore?.unwatch(session.id)
        }
    }
}

// MARK: - Attention Queue

/// Sessions that cannot make progress without a human. Renders nothing when
/// the fleet is healthy — an "all clear" card would be permanent clutter on
/// the common path.
struct HomeAttentionQueue: View {
    let context: HomeContext
    var style: Style = .panel

    enum Style {
        /// Flat, hairline-ruled rows for the dense layouts.
        case flat
        /// Tinted card with a heading, for the airier layouts.
        case panel
    }

    private var sessions: [Session] { context.attentionSessions }

    var body: some View {
        if !sessions.isEmpty {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                header
                VStack(spacing: 0) {
                    ForEach(Array(sessions.prefix(5).enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        HomeAttentionRow(session: session, context: context)
                    }
                }
                .background(rowBackground)
            }
            .padding(style == .panel ? FlotillaSpacing.large : 0)
            .background(panelBackground)
            .accessibilityIdentifier(AXID.homeAttentionQueue.rawValue)
        }
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: FlotillaIconSize.small, weight: .semibold))
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
            Text("Needs you")
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("\(sessions.count)")
                .font(FlotillaTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(FlotillaColors.statusWaitingForInput)
                .padding(.horizontal, FlotillaSpacing.small)
                .padding(.vertical, 1)
                .background(FlotillaColors.statusWaitingForInput.opacity(0.16), in: Capsule())
            Spacer()
        }
    }

    @ViewBuilder
    private var rowBackground: some View {
        if style == .flat {
            Color.clear
        } else {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .fill(FlotillaColors.surface)
        }
    }

    @ViewBuilder
    private var panelBackground: some View {
        if style == .panel {
            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                .fill(FlotillaColors.statusWaitingForInput.opacity(0.07))
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                        .strokeBorder(FlotillaColors.statusWaitingForInput.opacity(0.28), lineWidth: FlotillaBorderWidth.thin)
                }
        }
    }
}

private struct HomeAttentionRow: View {
    let session: Session
    let context: HomeContext
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            StatusBadge(session.status, size: .micro, showLabel: false, showGlyph: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(FlotillaTypography.body.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                HomeActivityLine(session: session, activityStore: context.activityStore)
            }

            Spacer(minLength: FlotillaSpacing.small)

            if session.status == .crashed {
                Button("Restart") {
                    context.store.restartSession(sessionID: session.id)
                }
                .buttonStyle(.borderless)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.accent)
            }

            Text(HomeTimestamp.compact(session.lastActiveAt))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)

            Image(systemName: "chevron.right")
                .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .background(isHovering ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear)
        .contentShape(.rect)
        .onTapGesture { context.openSession(session.id) }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Attention-\(session.title)")
    }
}

// MARK: - Recent Sessions

struct HomeRecentSessionsList: View {
    let context: HomeContext
    var limit: Int = 6
    var showsHeader: Bool = true

    private var sessions: [Session] { context.recentSessions(limit: limit) }
    private var liveIDs: Set<UUID> { HomeLiveData.eligibleSessionIDs(in: context.store.sessions) }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            if showsHeader {
                HomeSectionHeader(title: "Recent sessions", count: context.store.sessions.count)
            }
            if sessions.isEmpty {
                HomeEmptyHint(text: "Sessions you start will collect here.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().opacity(0.5) }
                        HomeSessionRow(
                            session: session,
                            context: context,
                            showsLiveData: liveIDs.contains(session.id)
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier(AXID.homeRecentSessions.rawValue)
    }
}

private struct HomeSessionRow: View {
    let session: Session
    let context: HomeContext
    let showsLiveData: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ZStack {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(FlotillaColors.surfaceElevated)
                ProviderLogo(agent: session.agent)
                    .frame(width: 13, height: 13)
            }
            .frame(width: 24, height: 24)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(StatusPresentation.color(for: session.status))
                    .frame(width: 7, height: 7)
                    .overlay { Circle().strokeBorder(FlotillaColors.canvas, lineWidth: 1.5) }
                    .offset(x: 2, y: 2)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(FlotillaTypography.body)
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                if showsLiveData {
                    HomeActivityLine(session: session, activityStore: context.activityStore)
                }
            }

            Spacer(minLength: FlotillaSpacing.small)

            if showsLiveData {
                SessionDiffStatView(session: session, diffStatStore: context.store.diffStatStore)
            }

            if let branch = session.worktree?.branchName {
                Label(branch, systemImage: "arrow.triangle.branch")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .labelStyle(.titleAndIcon)
                    .lineLimit(1)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            Text(HomeTimestamp.compact(session.lastActiveAt))
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(minWidth: 26, alignment: .trailing)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, FlotillaSpacing.small)
        .background(isHovering ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .contentShape(.rect)
        .onTapGesture { context.openSession(session.id) }
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("Home.Session-\(session.title)")
    }
}

// MARK: - Recent Projects

struct HomeRecentProjectsGrid: View {
    let context: HomeContext
    var limit: Int = 4
    var minimumTileWidth: CGFloat = 200

    private var projects: [Project] { context.recentProjects(limit: limit) }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HomeSectionHeader(title: "Projects", count: context.store.projects.count)
            if projects.isEmpty {
                HomeEmptyHint(text: "Projects appear here once you launch a project-scoped session.")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minimumTileWidth), spacing: FlotillaSpacing.medium)],
                    spacing: FlotillaSpacing.medium
                ) {
                    ForEach(projects) { project in
                        HomeProjectTile(project: project, context: context)
                    }
                }
            }
        }
        .accessibilityIdentifier(AXID.homeRecentProjects.rawValue)
    }
}

struct HomeProjectTile: View {
    let project: Project
    let context: HomeContext
    @State private var isHovering = false

    private var sessions: [Session] { context.store.sessions(for: project) }
    private var tint: Color { ProjectMark.tint(for: project) }
    private var activeCount: Int {
        sessions.filter { $0.status == .working || $0.status == .waitingForInput }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                ProjectMark(title: project.name, tint: tint)
                Text(project.name)
                    .font(FlotillaTypography.body.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            Text(project.rootPath.path)
                .font(FlotillaTypography.caption3.monospaced())
                .foregroundStyle(FlotillaColors.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: FlotillaSpacing.xSmall)

            HStack(spacing: FlotillaSpacing.small) {
                Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer(minLength: 0)
                if activeCount > 0 {
                    HStack(spacing: FlotillaSpacing.xSmall) {
                        Circle()
                            .fill(FlotillaColors.statusWorking)
                            .frame(width: 5, height: 5)
                        Text("\(activeCount) active")
                            .font(FlotillaTypography.caption2.weight(.medium))
                            .foregroundStyle(FlotillaColors.statusWorking)
                    }
                }
            }
        }
        .padding(FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(isHovering ? tint.opacity(0.55) : FlotillaColors.separator, lineWidth: FlotillaBorderWidth.thin)
        }
        .contentShape(.rect)
        .onTapGesture { context.openProject(project.id) }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Open Project") { context.openProject(project.id) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.rootPath.path, forType: .string)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.projectCompactCard.rawValue + project.name)
    }
}

// MARK: - Small Shared Pieces

struct HomeSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(title)
                .font(FlotillaTypography.caption.weight(.semibold))
                .tracking(FlotillaTypography.Tracking.loose2)
                .textCase(.uppercase)
                .foregroundStyle(FlotillaColors.textTertiary)
            if let count, count > 0 {
                Text("\(count)")
                    .font(FlotillaTypography.caption2.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct HomeEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(FlotillaTypography.callout)
            .foregroundStyle(FlotillaColors.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, FlotillaSpacing.small)
    }
}

/// Horizontal status histogram — one segment per occurring status, widths
/// proportional to session counts. Shared by the layouts that show a fleet bar.
struct HomeFleetBar: View {
    let stats: HomeFleetStats
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 2) {
                ForEach(stats.presentStatuses, id: \.self) { status in
                    let fraction = CGFloat(stats.count(status)) / CGFloat(max(stats.total, 1))
                    Capsule()
                        .fill(StatusPresentation.color(for: status))
                        .frame(width: max(proxy.size.width * fraction - 2, 3))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.summary)
    }
}

/// Status legend as count + label pairs.
struct HomeFleetLegend: View {
    let stats: HomeFleetStats
    var axis: Axis = .horizontal

    var body: some View {
        let items = stats.presentStatuses
        Group {
            if axis == .horizontal {
                HStack(spacing: FlotillaSpacing.large) {
                    ForEach(items, id: \.self) { entry($0) }
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                    ForEach(items, id: \.self) { entry($0) }
                }
            }
        }
    }

    private func entry(_ status: SessionStatus) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Circle()
                .fill(StatusPresentation.color(for: status))
                .frame(width: 6, height: 6)
            Text("\(stats.count(status))")
                .font(FlotillaTypography.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(FlotillaColors.textPrimary)
            Text(StatusPresentation.compactLabel(for: status))
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(stats.count(status)) \(StatusPresentation.label(for: status))")
    }
}
