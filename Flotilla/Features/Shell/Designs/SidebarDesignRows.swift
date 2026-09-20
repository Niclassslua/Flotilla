import SwiftUI
import SessionKit
import DesignSystem
import GitKit

// MARK: - Shared pieces

/// "now / 12m / 3h / 2d" — the navigator has no room for a date, and an
/// age is the only thing anyone reads off a session list anyway.
enum SidebarRelativeTime {
    static func short(for date: Date, relativeTo now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "now"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3_600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// The status, as a dot rather than a word.
///
/// Three of the four designs drop the status *word* — at `.fixedSize()` it
/// reserves the width of "Needs Permission" on every row, in a column that
/// starts at 260pt. The dot still has to carry the status as its
/// accessibility label under the `SessionRow-<title>-Status` identifier: that
/// is a contract, not decoration (`HooksUITests` reads the waiting reason off
/// it, and colour alone would not say it at all).
struct SidebarStatusDot: View {
    let session: Session
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(StatusPresentation.color(for: session.status))
            .frame(width: size, height: size)
            .animation(.easeInOut(duration: 0.18), value: session.status)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
            .accessibilityIdentifier("SessionRow-\(session.title)-Status")
    }
}

/// A vertical bar of the same colour, for the designs that put status on the
/// row's leading edge instead of in its content.
struct SidebarStatusBar: View {
    let session: Session
    var width: CGFloat = 3

    var body: some View {
        RoundedRectangle(cornerRadius: width / 2, style: .continuous)
            .fill(StatusPresentation.color(for: session.status))
            .frame(width: width)
            .animation(.easeInOut(duration: 0.18), value: session.status)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
            .accessibilityIdentifier("SessionRow-\(session.title)-Status")
    }
}

// MARK: - Project header

/// The project's line in the navigator, per design.
///
/// Every variant makes the project outweigh its sessions — mark ≥ 22pt,
/// title ≥ 15pt. Today's header is a 16pt mark and a 12pt title over 13pt
/// session titles and 28pt provider tiles, so the group reads as smaller than
/// the things inside it.
struct SidebarProjectHeader: View {
    @Environment(\.sidebarDesign) private var design
    let project: Project
    let sessions: [Session]
    let isCollapsed: Bool
    let onToggleCollapse: () -> Void

    private var tint: Color { ProjectMark.tint(for: project) }

    var body: some View {
        switch design {
        case .elevatedHeader: elevatedHeader
        case .accentRail: accentRail
        case .projectCard: projectCard
        case .statusForward: statusForward
        }
    }

    // 1 — restrained: the current row, grown up.
    private var elevatedHeader: some View {
        HStack(spacing: 8) {
            chevron
            ProjectMark(project: project, size: 22)
            Text(project.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if !sessions.isEmpty {
                Text("\(sessions.count)")
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: Capsule())
            }
        }
        .padding(.vertical, 4)
    }

    // 2 — the accent starts here and runs down the block.
    private var accentRail: some View {
        HStack(spacing: 8) {
            chevron
            ProjectMark(project: project, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !sessions.isEmpty {
                    Text("\(sessions.count) session\(sessions.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FlotillaColors.separator)
                .frame(height: 0.5)
        }
    }

    // 3 — the lid of the card its sessions sit in.
    private var projectCard: some View {
        HStack(spacing: 8) {
            chevron
            ProjectMark(project: project, size: 26)
            Text(project.name)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            statusDots
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: FlotillaRadius.card,
                bottomLeadingRadius: isCollapsed ? FlotillaRadius.card : 0,
                bottomTrailingRadius: isCollapsed ? FlotillaRadius.card : 0,
                topTrailingRadius: FlotillaRadius.card,
                style: .continuous
            )
            .fill(tint.opacity(0.10))
        }
    }

    // 4 — a masthead, with the repo location under it.
    private var statusForward: some View {
        HStack(spacing: 10) {
            chevron
            ProjectMark(project: project, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(homeRelativePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(tint.opacity(0.45))
                .frame(height: 1)
        }
    }

    /// One dot per status present under this project, most actionable first —
    /// the fleet composition of a single project, in the space a number used
    /// to take.
    private var statusDots: some View {
        HStack(spacing: 3) {
            ForEach(StatusPresentation.attentionOrder, id: \.self) { status in
                let count = sessions.filter { $0.status == status }.count
                if count > 0 {
                    Circle()
                        .fill(StatusPresentation.color(for: status))
                        .frame(width: 6, height: 6)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var homeRelativePath: String {
        project.rootPath.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    private var chevron: some View {
        Button(action: onToggleCollapse) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 10)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isCollapsed ? "Expand \(project.name)" : "Collapse \(project.name)")
        .accessibilityIdentifier(AXID.sidebarProjectCollapseToggle(project.name))
    }
}

// MARK: - Session row content

/// What a session row *says*, per design. The chrome around it — selection,
/// swipe-to-delete, the context menu, the selection tag, the row identifier —
/// stays in `SessionSidebarRow` and never varies, because that is what the UI
/// suite and `List`'s native multi-select depend on.
struct SidebarSessionContent: View {
    @Environment(\.sidebarDesign) private var design
    let session: Session
    let diffStatStore: DiffStatStore?
    /// The owning project's accent, for the designs that carry it into the
    /// rows. `nil` for unassigned sessions in the General section.
    let projectTint: Color?

    var body: some View {
        switch design {
        case .elevatedHeader: elevatedHeader
        case .accentRail: accentRail
        case .projectCard: projectCard
        case .statusForward: statusForward
        }
    }

    // 1 — today's row, kept as-is so nothing regresses if this one wins.
    // Lifted out of `SessionCard.rowView` rather than reused from it: that
    // variant carries its own `.contextMenu`, which would stack on top of the
    // one `SessionSidebarRow` already attaches.
    private var elevatedHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            providerTile
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SidebarRelativeTime.short(for: session.lastActiveAt))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 5) {
                    statusWord
                    if let diffStatStore {
                        Spacer(minLength: 2)
                        SessionDiffStatView(session: session, diffStatStore: diffStatStore)
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .padding(.top, 1)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    /// The 28pt agent tile with the status dot knocked into its corner.
    private var providerTile: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(FlotillaColors.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(FlotillaColors.separator.opacity(0.6), lineWidth: 0.5)
                }
                .overlay {
                    ProviderLogo(agent: session.agent)
                        .padding(5)
                }
            Circle()
                .fill(StatusPresentation.color(for: session.status))
                .frame(width: 8, height: 8)
                .overlay(Circle().strokeBorder(FlotillaColors.sidebar, lineWidth: 1.5))
                .frame(width: 16, height: 16)
                .offset(x: 4, y: 4)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    /// Width-stable: the hidden stack reserves the longest label so the row
    /// does not reflow every time a status changes.
    private var statusWord: some View {
        ZStack(alignment: .leading) {
            ForEach(StatusPresentation.attentionOrder, id: \.self) { status in
                Text(StatusPresentation.label(for: status)).hidden()
            }
            Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                .foregroundStyle(StatusPresentation.color(for: session.status))
        }
        .font(.caption2.weight(.semibold))
        .fixedSize()
        .animation(.easeInOut(duration: 0.18), value: session.status)
        .animation(.easeInOut(duration: 0.18), value: session.waitingReason)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
        .accessibilityIdentifier("SessionRow-\(session.title)-Status")
    }

    // 2 — one line. Provider shrinks to a 12pt logo beside the title, status
    // becomes the dot on the rail, and the title gets the rest.
    private var accentRail: some View {
        HStack(spacing: 7) {
            SidebarStatusDot(session: session, size: 7)
            Text(session.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            ProviderLogo(agent: session.agent)
                .frame(width: 12, height: 12)
                .opacity(0.7)
                .accessibilityHidden(true)
            Spacer(minLength: 4)
            if let diffStatStore {
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
            }
            Text(SidebarRelativeTime.short(for: session.lastActiveAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    // 3 — a line in a card: dot, title, age. Everything else is on the
    // tooltip and the context menu.
    private var projectCard: some View {
        HStack(spacing: 8) {
            SidebarStatusDot(session: session, size: 6)
            Text(session.title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let diffStatStore {
                SessionDiffStatView(session: session, diffStatStore: diffStatStore)
            }
            Text(SidebarRelativeTime.short(for: session.lastActiveAt))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }

    // 4 — two lines, and the branch is back. It was cut because the status
    // word and the 28pt tile left it no width; with status on the edge bar
    // there is room for the one piece of metadata that actually varies
    // between two sessions on the same project.
    private var statusForward: some View {
        HStack(spacing: 8) {
            ProviderLogo(agent: session.agent)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(SidebarRelativeTime.short(for: session.lastActiveAt))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                HStack(spacing: 5) {
                    if let branch = session.worktree?.branchName {
                        GitBranchIcon(size: 9)
                            .foregroundStyle(FlotillaColors.textTertiary)
                        Text(BranchNaming.displayName(for: branch))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(StatusPresentation.label(for: session.status, waitingReason: session.waitingReason))
                            .font(.system(size: 10))
                            .foregroundStyle(StatusPresentation.color(for: session.status))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if let diffStatStore {
                        SessionDiffStatView(session: session, diffStatStore: diffStatStore)
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Session row chrome

/// The row's *shape*: its fill, its edges, and whatever the design draws at
/// its leading edge. Kept apart from the content above because the two vary
/// independently — design 2 and 4 both drop the provider tile, but only 4
/// draws a status bar; 3 alone needs to know where the row sits in its group.
struct SidebarRowChrome: ViewModifier {
    @Environment(\.sidebarDesign) private var design
    let session: Session
    let fill: Color
    let projectTint: Color?
    let position: SidebarRowPosition

    private var tint: Color { projectTint ?? FlotillaColors.separatorStrong }

    func body(content: Content) -> some View {
        switch design {
        case .elevatedHeader: elevated(content)
        case .accentRail: railed(content)
        case .projectCard: carded(content)
        case .statusForward: barred(content)
        }
    }

    private func elevated(_ content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(FlotillaColors.sidebar)
                    .overlay {
                        RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                            .fill(fill)
                    }
            }
            .padding(.vertical, 4)
    }

    /// No gap between rows, so consecutive rails join into one continuous
    /// line down the project's block.
    private func railed(_ content: Content) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(0.55))
                .frame(width: 2)
                .accessibilityHidden(true)
            content
                .padding(.leading, 9)
                .padding(.trailing, 8)
        }
        .padding(.leading, 11)
        .background {
            FlotillaColors.sidebar.overlay(fill)
        }
    }

    private func carded(_ content: Content) -> some View {
        content
            .background {
                UnevenRoundedRectangle(
                    topLeadingRadius: 0,
                    bottomLeadingRadius: position.isLast ? FlotillaRadius.card : 0,
                    bottomTrailingRadius: position.isLast ? FlotillaRadius.card : 0,
                    topTrailingRadius: 0,
                    style: .continuous
                )
                .fill(FlotillaColors.surface)
                .overlay {
                    UnevenRoundedRectangle(
                        topLeadingRadius: 0,
                        bottomLeadingRadius: position.isLast ? FlotillaRadius.card : 0,
                        bottomTrailingRadius: position.isLast ? FlotillaRadius.card : 0,
                        topTrailingRadius: 0,
                        style: .continuous
                    )
                    .fill(fill)
                }
            }
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(FlotillaColors.separator)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
            }
            .padding(.bottom, position.isLast ? 8 : 0)
    }

    private func barred(_ content: Content) -> some View {
        HStack(spacing: 0) {
            SidebarStatusBar(session: session, width: 3)
                .padding(.vertical, 3)
            content
                .padding(.leading, 9)
                .padding(.trailing, 8)
        }
        .background {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .fill(FlotillaColors.sidebar)
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .fill(fill)
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}
