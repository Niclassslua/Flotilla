import SwiftUI
import SessionKit
import GitKit
import DesignSystem

/// Design — **Stream**. The project workspace as one calm activity feed:
/// sessions and recent commits interleaved by recency down a timeline spine,
/// under a fixed masthead carrying the project name, a monospace instrument
/// row, and quiet links to the four deeper surfaces.
///
/// Continuous surfaces, hairline rules, a real type scale — no cards, no
/// gradients. The signature is the spine: each entry's node sits on a single
/// vertical hairline, git-log style, and working sessions stream their last
/// terminal line beneath the title so the feed reads as alive.
struct StreamProjectWorkspace: View {
    @Environment(\.workspaceNavigator) private var navigator
    let context: ProjectWorkspaceContext

    @State private var pulse: ProjectPulse = .empty
    @State private var worktrees: [GitWorktree] = []
    @State private var showAllWorktrees = false

    // Timeline geometry. The spine sits between the time gutter and the node
    // lane; everything downstream is measured from these constants.
    private let gutterWidth: CGFloat = 40
    private let laneWidth: CGFloat = 20
    private let columnGap: CGFloat = 14
    private let readingWidth: CGFloat = 820
    private let contextWidth: CGFloat = 344
    private let commitLimit = 6
    private let worktreePreview = 12

    private var project: Project { context.project }
    private var selectedTab: ProjectDetailView.ProjectTab { navigator.projectTab(for: project.id) }
    private var stats: HomeFleetStats { HomeFleetStats(sessions: context.sessions) }
    private var spineX: CGFloat { gutterWidth + columnGap + laneWidth / 2 }
    private var contentLeading: CGFloat { gutterWidth + columnGap + laneWidth + columnGap }

    var body: some View {
        Group {
            if selectedTab == .overview {
                HStack(spacing: 0) {
                    VStack(spacing: 0) {
                        masthead
                        feed
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle()
                        .fill(FlotillaColors.separatorStrong)
                        .frame(width: 1)

                    contextColumn
                        .frame(width: contextWidth, alignment: .top)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .background(FlotillaColors.sidebar)
                }
            } else {
                VStack(spacing: 0) {
                    SurfaceReturnBar(context: context, tab: selectedTab)
                    Divider()
                    ProjectSurfaceHost(tab: selectedTab, context: context)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .task(id: project.id) {
            pulse = await ProjectPulse.load(root: project.rootPath, git: context.store.gitService)
            worktrees = (try? await context.store.gitService.listWorktrees(at: project.rootPath)) ?? []
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
                ProjectMark(title: project.name, tint: ProjectMark.tint(for: project), size: 34)

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text(project.rootPath.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: FlotillaSpacing.medium)

                surfaceNav
            }

            instrumentRow
        }
        .padding(.horizontal, FlotillaSpacing.xLarge)
        .padding(.top, FlotillaSpacing.xLarge)
        .padding(.bottom, FlotillaSpacing.large)
        .frame(maxWidth: readingWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(FlotillaColors.surface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(FlotillaColors.separatorStrong).frame(height: 1)
        }
    }

    private var instrumentRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            instrumentSegment {
                HStack(spacing: 5) {
                    GitBranchIcon(size: 11)
                    Text(pulse.branch ?? "—")
                }
            } action: { openGit() }

            if pulse.unpushedCount > 0 {
                instrumentDot()
                instrumentSegment {
                    Text("↑\(pulse.unpushedCount)").foregroundStyle(FlotillaColors.statusReady)
                } action: { openGit() }
            }

            instrumentDot()
            instrumentSegment {
                if pulse.diffStat.isEmpty {
                    Text("clean").foregroundStyle(FlotillaColors.success)
                } else {
                    HStack(spacing: 6) {
                        Text("+\(pulse.diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                        Text("−\(pulse.diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                    }
                }
            } action: { openGit() }

            if !pulse.isClean {
                instrumentDot()
                instrumentSegment {
                    Text("\(pulse.changedFileCount) file\(pulse.changedFileCount == 1 ? "" : "s")")
                } action: { openGit() }
            }

            if commitsThisWeek > 0 {
                instrumentDot()
                instrumentSegment {
                    Text("\(commitsThisWeek) commit\(commitsThisWeek == 1 ? "" : "s")/wk")
                } action: {
                    navigator.setProjectGitSubTab(.commits, for: project.id)
                    openGit()
                }
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(FlotillaColors.textSecondary)
    }

    private var commitsThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return pulse.recentCommits.filter { $0.authorDate >= cutoff }.count
    }

    private func instrumentSegment<L: View>(@ViewBuilder label: () -> L, action: @escaping () -> Void) -> some View {
        Button(action: action) { label().contentShape(.rect) }
            .buttonStyle(.plain)
    }

    private func instrumentDot() -> some View {
        Text("·").foregroundStyle(FlotillaColors.separatorStrong)
    }

    private var surfaceNav: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            surfaceLink(.git, "Git", "arrow.triangle.branch")
            surfaceLink(.files, "Files", "folder")
            surfaceLink(.skills, "Skills", "sparkles")
            surfaceLink(.rules, "Rules", "doc.badge.gearshape")
        }
    }

    private func surfaceLink(_ tab: ProjectDetailView.ProjectTab, _ title: String, _ symbol: String) -> some View {
        Button {
            withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(tab, for: project.id) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .background(FlotillaColors.surfaceElevated, in: Capsule())
            .overlay {
                Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(projectSurfaceAXID(tab))
    }

    // MARK: - Feed

    private var feed: some View {
        Group {
            if timelineElements.isEmpty {
                emptyState
            } else {
                ScrollView {
                    timeline
                        .padding(.horizontal, FlotillaSpacing.xLarge)
                        .padding(.top, FlotillaSpacing.xLarge)
                        .padding(.bottom, FlotillaSpacing.xxLarge)
                        .frame(maxWidth: readingWidth, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(AXID.projectOverview.rawValue)
    }

    // MARK: - Context column

    private var contextColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                worktreesBlock
                Divider()
                workingTreeBlock
                Divider()
                thisWeekBlock
            }
        }
        .background(FlotillaColors.sidebar)
    }

    private var sortedWorktrees: [GitWorktree] {
        worktrees.sorted { lhs, rhs in
            if lhs.isMainWorktree != rhs.isMainWorktree { return lhs.isMainWorktree }
            let ls = sessionFor(lhs) != nil, rs = sessionFor(rhs) != nil
            if ls != rs { return ls }
            return lhs.branch < rhs.branch
        }
    }

    @ViewBuilder
    private var worktreesBlock: some View {
        let all = sortedWorktrees
        let shown = showAllWorktrees ? all : Array(all.prefix(worktreePreview))
        let attached = all.filter { sessionFor($0) != nil }.count

        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                sectionLabel("Worktrees")
                Text("\(all.count)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                if attached > 0 {
                    Text("\(attached) active")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(FlotillaColors.statusWorking)
                }
            }
            .padding(.bottom, 2)

            if all.isEmpty {
                Text("No worktrees").font(.system(size: 11)).foregroundStyle(FlotillaColors.textTertiary)
            } else {
                ForEach(shown, id: \.path) { worktreeCell($0) }
                if all.count > worktreePreview {
                    Button {
                        withAnimation(FlotillaMotion.fast.curve) { showAllWorktrees.toggle() }
                    } label: {
                        Text(showAllWorktrees ? "Show fewer" : "Show all \(all.count) →")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var workingTreeBlock: some View {
        Button {
            openGit()
        } label: {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                sectionLabel("Working tree")
                    .padding(.bottom, 2)

                HStack(spacing: FlotillaSpacing.small) {
                    if pulse.diffStat.isEmpty {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(FlotillaColors.success)
                        Text("Clean").font(.system(size: 13)).foregroundStyle(FlotillaColors.textSecondary)
                    } else {
                        Text("+\(pulse.diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                        Text("−\(pulse.diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                        Text("· \(pulse.changedFileCount) file\(pulse.changedFileCount == 1 ? "" : "s")")
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .font(.system(size: 13, design: .monospaced))

                HStack(spacing: FlotillaSpacing.small) {
                    Label(pulse.branch ?? "—", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                    if pulse.unpushedCount > 0 {
                        Text("↑\(pulse.unpushedCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(FlotillaColors.statusReady)
                    }
                }
            }
            .padding(FlotillaSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private var thisWeekBlock: some View {
        let week = weekStat
        return VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            sectionLabel("This week")
                .padding(.bottom, 2)
            weekRow("Commits", "\(commitsThisWeek)")
            weekRow("Sessions", "\(stats.total)")
            if !week.isEmpty {
                weekRow("Churn", "+\(week.additions) −\(week.deletions)")
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func weekRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 12)).foregroundStyle(FlotillaColors.textTertiary)
            Spacer()
            Text(value).font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(FlotillaColors.textSecondary)
        }
    }

    private var weekStat: GitDiffStat {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? .distantPast
        return pulse.recentCommits
            .filter { $0.authorDate >= cutoff }
            .reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.stat }
    }

    private func sessionFor(_ wt: GitWorktree) -> Session? {
        context.sessions.first {
            ($0.worktree?.worktreePath ?? $0.workingDirectory).standardizedFileURL == wt.path.standardizedFileURL
        }
    }

    private func worktreeCell(_ wt: GitWorktree) -> some View {
        let session = sessionFor(wt)
        return Button {
            navigator.setProjectGitScope(wt.path, for: project.id)
            withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(.git, for: project.id) }
        } label: {
            HStack(spacing: FlotillaSpacing.small) {
                Group {
                    if wt.isMainWorktree {
                        Image(systemName: "house.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(FlotillaColors.accent)
                    } else {
                        Circle()
                            .fill(session.map { StatusPresentation.color(for: $0.status) } ?? FlotillaColors.separatorStrong)
                            .frame(width: 6, height: 6)
                    }
                }
                .frame(width: 12)

                Text(wt.branch)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(session != nil || wt.isMainWorktree ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: FlotillaSpacing.small)

                if let session {
                    Text(session.agent.displayName)
                        .font(.system(size: 10))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            .padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(FlotillaTypography.Tracking.loose2)
            .textCase(.uppercase)
            .foregroundStyle(FlotillaColors.textTertiary)
    }

    // MARK: Timeline

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(timelineElements.enumerated()), id: \.element.id) { index, element in
                switch element {
                case .band(let label):
                    timelineBand(label, isFirst: index == 0)
                case .entry(let entry, let isLast):
                    timelineRow(entry, isLast: isLast)
                case .footer(let count):
                    timelineFooter(count)
                }
            }
        }
    }

    private func timelineBand(_ label: String, isFirst: Bool) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .tracking(FlotillaTypography.Tracking.loose2)
            .textCase(.uppercase)
            .foregroundStyle(label == "Needs you" ? FlotillaColors.statusWaitingForInput : FlotillaColors.textTertiary)
            .padding(.top, isFirst ? 0 : FlotillaSpacing.large)
            .padding(.bottom, FlotillaSpacing.small)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FlotillaColors.canvas)
    }

    private func timelineRow(_ entry: StreamEntry, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: columnGap) {
            Text(entry.timeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: gutterWidth, alignment: .trailing)
                .padding(.top, 3)

            node(for: entry, hero: entry.isHero)
                .frame(width: laneWidth)

            Group {
                switch entry.payload {
                case .session(let session): sessionContent(session, hero: entry.isHero)
                case .commit(let commit): commitContent(commit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, entry.isHero ? FlotillaSpacing.medium : 0)
            .padding(.vertical, entry.isHero ? FlotillaSpacing.small + 2 : 0)
            .background {
                if let accent = rowAccent(for: entry) {
                    RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                        .fill(accent.opacity(0.10))
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                .strokeBorder(accent.opacity(0.28), lineWidth: FlotillaBorderWidth.thin)
                        }
                }
            }
            .padding(.bottom, FlotillaSpacing.large)
        }
        .background(alignment: .topLeading) { spine(isLast: isLast) }
        .contentShape(.rect)
        .onTapGesture { activate(entry) }
    }

    /// The continuous hairline behind every row; abutting rows fuse it, the
    /// final row stops it at the node. Each node's canvas disc knocks the gap.
    private func spine(isLast: Bool) -> some View {
        Rectangle()
            .fill(FlotillaColors.separatorStrong)
            .frame(width: 1.5)
            .frame(maxHeight: isLast ? 16 : .infinity, alignment: .top)
            .padding(.leading, spineX - 0.75)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The status colour a hero session row is washed and outlined with;
    /// `nil` for commits and dormant sessions (which get no highlight).
    private func rowAccent(for entry: StreamEntry) -> Color? {
        guard case .session(let session) = entry.payload, entry.isHero else { return nil }
        return StatusPresentation.color(for: session.status)
    }

    private func node(for entry: StreamEntry, hero: Bool) -> some View {
        ZStack {
            Circle().fill(FlotillaColors.canvas).frame(width: 20, height: 20)
            switch entry.payload {
            case .session(let session):
                let color = entry.isAttention ? FlotillaColors.statusWaitingForInput : StatusPresentation.color(for: session.status)
                if hero {
                    Circle().strokeBorder(color.opacity(0.30), lineWidth: 3).frame(width: 17, height: 17)
                }
                Circle().fill(color).frame(width: hero ? 10 : 8, height: hero ? 10 : 8)
            case .commit:
                Circle()
                    .strokeBorder(FlotillaColors.textTertiary, lineWidth: 1.5)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.top, 1)
    }

    private func sessionContent(_ session: Session, hero: Bool) -> some View {
        let isLive = session.status == .working || session.status == .waitingForInput
        return VStack(alignment: .leading, spacing: hero ? 5 : 4) {
            HStack(spacing: FlotillaSpacing.small) {
                Text(session.title)
                    .font(.system(size: hero ? 16 : 14, weight: .semibold))
                    .foregroundStyle(hero ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let branch = session.worktree?.branchName {
                    Text(branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 200, alignment: .leading)
                }
                Spacer(minLength: FlotillaSpacing.small)
                SessionDiffStatView(session: session, diffStatStore: context.store.diffStatStore)
                StatusBadge(session.status, waitingReason: session.waitingReason, size: .micro)
                Text(session.agent.displayName)
                    .font(.system(size: 11))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }

            if isLive {
                HomeActivityLine(session: session, activityStore: context.activityStore, font: .system(size: 11))
            } else if !session.goal.isEmpty {
                Text(session.goal)
                    .font(.system(size: 12))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private func commitContent(_ commit: GitCommit) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(commit.subject)
                .font(.system(size: 13))
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: FlotillaSpacing.small)
            if !commit.stat.isEmpty {
                Text("+\(commit.stat.additions) −\(commit.stat.deletions)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary.opacity(0.7))
            }
            Text(commit.shortSHA)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
        }
        .padding(.top, 1)
    }

    private func timelineFooter(_ count: Int) -> some View {
        HStack(alignment: .top, spacing: columnGap) {
            Color.clear.frame(width: gutterWidth, height: 1)
            ZStack {
                Circle().fill(FlotillaColors.canvas).frame(width: 20, height: 20)
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .frame(width: laneWidth)
            .padding(.top, 1)

            Button {
                navigator.setProjectGitSubTab(.commits, for: project.id)
                openGit()
            } label: {
                Text("\(count) earlier commit\(count == 1 ? "" : "s") — open history")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.bottom, FlotillaSpacing.large)
            }
            .buttonStyle(.plain)
        }
        .background(alignment: .topLeading) {
            Rectangle()
                .fill(FlotillaColors.separatorStrong)
                .frame(width: 1.5)
                .frame(maxHeight: 16, alignment: .top)
                .padding(.leading, spineX - 0.75)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var emptyState: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(FlotillaColors.textTertiary)
            VStack(spacing: 4) {
                Text("No history yet")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FlotillaColors.textSecondary)
                Text("Sessions and commits for this project will appear here.")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(FlotillaSpacing.xxLarge)
    }

    // MARK: - Data

    private var attentionSessions: [Session] {
        context.sessions
            .filter { $0.status == .waitingForInput }
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
    }

    /// Non-attention sessions and recent commits, newest first, bucketed by day.
    private var dayGroups: [(label: String, items: [StreamEntry])] {
        let attentionIDs = Set(attentionSessions.map(\.id))
        let sessionEntries = context.sessions
            .filter { !attentionIDs.contains($0.id) }
            .map { StreamEntry(session: $0) }
        let commitEntries = pulse.recentCommits.prefix(commitLimit).map { StreamEntry(commit: $0) }

        let merged = (sessionEntries + commitEntries).sorted { $0.date > $1.date }
        guard !merged.isEmpty else { return [] }

        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [StreamEntry]] = [:]
        for entry in merged {
            let key = Self.dayLabel(for: entry.date, calendar: calendar)
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var earlierCommitCount: Int {
        max(0, pulse.recentCommits.count - commitLimit)
    }

    /// The flattened timeline: day/attention bands interleaved with entry rows,
    /// then an "earlier commits" footer. One list so the spine is continuous
    /// within a day and breaks cleanly at each band.
    private var timelineElements: [TimelineElement] {
        var out: [TimelineElement] = []

        if !attentionSessions.isEmpty {
            out.append(.band("Needs you"))
            for session in attentionSessions {
                out.append(.entry(StreamEntry(session: session), isLast: false))
            }
        }

        let groups = dayGroups
        for (groupIndex, group) in groups.enumerated() {
            out.append(.band(group.label))
            for (rowIndex, entry) in group.items.enumerated() {
                let lastOverall = groupIndex == groups.count - 1 && rowIndex == group.items.count - 1
                out.append(.entry(entry, isLast: lastOverall && earlierCommitCount == 0))
            }
        }

        if earlierCommitCount > 0 { out.append(.footer(earlierCommitCount)) }
        return out
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: Date())).day ?? 0
        if days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        return "Earlier"
    }

    // MARK: - Actions

    private func activate(_ entry: StreamEntry) {
        switch entry.payload {
        case .session(let session): context.openSession(session.id)
        case .commit(let commit): openCommit(commit)
        }
    }

    private func openGit() {
        navigator.setProjectGitScope(project.rootPath, for: project.id)
        withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(.git, for: project.id) }
    }

    private func openCommit(_ commit: GitCommit) {
        let root = project.rootPath.standardizedFileURL
        navigator.setProjectGitScope(root, for: project.id)
        navigator.setProjectGitSubTab(.commits, for: project.id)
        navigator.projectGraphViewModel(for: root, gitService: context.store.gitService).selectedSHA = commit.sha
        withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(.git, for: project.id) }
    }
}

// MARK: - Timeline model

private enum TimelineElement: Identifiable {
    case band(String)
    case entry(StreamEntry, isLast: Bool)
    case footer(Int)

    var id: String {
        switch self {
        case .band(let label): return "band-\(label)"
        case .entry(let entry, _): return entry.id
        case .footer: return "footer"
        }
    }
}

private struct StreamEntry: Identifiable {
    enum Payload {
        case session(Session)
        case commit(GitCommit)
    }

    let id: String
    let date: Date
    let payload: Payload
    var isAttention = false

    init(session: Session) {
        id = "s-\(session.id)"
        date = session.lastActiveAt
        payload = .session(session)
        isAttention = session.status == .waitingForInput
    }

    init(commit: GitCommit) {
        id = "c-\(commit.sha)"
        date = commit.authorDate
        payload = .commit(commit)
    }

    var timeLabel: String { HomeTimestamp.compact(date) }

    /// Sessions that are live, waiting, or awaiting review get the emphasised
    /// row treatment — bigger title, haloed node, more air.
    var isHero: Bool {
        guard case .session(let session) = payload else { return false }
        return session.status == .working
            || session.status == .waitingForInput
            || session.status == .readyForReview
    }
}
