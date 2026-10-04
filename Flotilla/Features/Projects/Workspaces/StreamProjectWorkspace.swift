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

    @State private var viewModel: ProjectOverviewViewModel

    init(context: ProjectWorkspaceContext) {
        self.context = context
        _viewModel = State(initialValue: ProjectOverviewViewModel(gitService: context.store.gitService))
    }

    private var pulse: ProjectPulse { viewModel.pulse }
    private var worktrees: [GitWorktree] { viewModel.worktrees }
    private var snapshots: [URL: WorktreeSnapshot] { viewModel.snapshots }
    private var timelineElements: [TimelineElement] { viewModel.timelineElements }
    @State private var showAllWorktrees = false
    @State private var worktreePendingDeletion: GitWorktree?
    @State private var selectedWeekDay: Int?
    @State private var isShowingIconPicker = false

    // Timeline geometry. The spine sits between the time gutter and the node
    // lane; everything downstream is measured from these constants.
    private let gutterWidth: CGFloat = 40
    private let laneWidth: CGFloat = 20
    private let columnGap: CGFloat = 14
    private let readingWidth: CGFloat = 820
    private let contextWidth: CGFloat = FlotillaLayoutWidth.projectContextWidth
    private let worktreePreview = 12

    private var project: Project {
        context.store.projects.first(where: { $0.id == context.project.id }) ?? context.project
    }
    private var selectedTab: ProjectDetailView.ProjectTab { navigator.projectTab(for: project.id) }
    private var sessionsThisWeek: Int {
        ProjectOverviewViewModel.sessionsUsedThisWeek(in: context.sessions)
    }
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
                        .flotillaInspectorSurface()
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
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .onChange(of: context.sessions, initial: true) { _, sessions in
            viewModel.sessions = sessions
        }
        .task(id: project.id) {
            await viewModel.load(root: project.rootPath)
        }
        .sheet(isPresented: $isShowingIconPicker) {
            ProjectIconPickerSheet(
                project: project,
                onSave: { newIcon, newAccent in
                    context.store.updateProjectIdentity(id: project.id, icon: newIcon, accentColor: newAccent)
                },
                onDismiss: {
                    isShowingIconPicker = false
                }
            )
        }
    }

    // MARK: - Masthead

    private var masthead: some View {
        VStack(spacing: FlotillaSpacing.large) {
            HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
                Button {
                    isShowingIconPicker = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        ProjectMark(project: project, size: 34)
                        Circle()
                            .fill(FlotillaColors.surface)
                            .frame(width: 14, height: 14)
                            .overlay {
                                Image(systemName: "pencil")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(FlotillaColors.textSecondary)
                            }
                            .offset(x: 3, y: 3)
                    }
                }
                .buttonStyle(.plain)
                .help("Change project icon & color")
                .contextMenu {
                    Button("Change Icon & Color…") {
                        isShowingIconPicker = true
                    }
                    Menu("Accent Color") {
                        Button("Auto / Default") {
                            context.store.updateProjectAccentColor(id: project.id, accentColor: nil)
                        }
                        Divider()
                        ForEach(ProjectIconPickerSheet.presetAccentColors) { preset in
                            Button {
                                context.store.updateProjectAccentColor(id: project.id, accentColor: preset.hex)
                            } label: {
                                HStack {
                                    Text(preset.name)
                                    if isCurrentAccent(preset.hex) {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    }
                    if project.icon != nil {
                        Button("Remove Icon") {
                            context.store.updateProjectIcon(id: project.id, icon: nil)
                        }
                    }
                    Divider()
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath.path)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(project.name)
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
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
            Divider().background(FlotillaColors.separator)
        }
    }

    private func isCurrentAccent(_ hex: String) -> Bool {
        guard let current = project.accentColor else { return false }
        let c1 = current.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        let c2 = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        return c1 == c2
    }

    private var instrumentRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            instrumentSegment {
                HStack(spacing: 5) {
                    GitBranchIcon(size: 11)
                    Text(pulse.branch.map(BranchNaming.displayName) ?? "—")
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
            surfaceLink(.issues, "Issues", "number")
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
                // Git gets the real Git mark, the way the command palette,
                // settings, and the session sidebar draw it — the SF Symbol
                // branch glyph belongs next to a branch name, not on the
                // link that opens the Git surface.
                if tab == .git {
                    GitIcon(size: 11)
                } else {
                    Image(systemName: symbol).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(FlotillaColors.textPrimary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .flotillaChromeCapsule(
                fallback: FlotillaColors.surfaceElevated
            )
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

    /// The right rail: the main checkout's working-copy state up top, every
    /// worktree under it as a live, right-clickable row, and the week's commit
    /// rhythm at the bottom.
    private var contextColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                workingTreeBlock
                Divider()
                worktreesBlock
                Divider()
                thisWeekBlock
            }
        }
        .accessibilityIdentifier(AXID.projectWorktreesSection.rawValue)
        .confirmationDialog(
            worktreePendingDeletion.map { "Delete the worktree on “\(BranchNaming.displayName(for: $0.branch))”?" } ?? "",
            isPresented: Binding(
                get: { worktreePendingDeletion != nil },
                set: { if !$0 { worktreePendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: worktreePendingDeletion
        ) { worktree in
            Button("Delete Worktree & Branch", role: .destructive) {
                delete(worktree, deleteBranch: true)
            }
            .accessibilityIdentifier("Project.WorktreeDelete.WithBranch")
            Button("Delete Worktree, Keep Branch") {
                delete(worktree, deleteBranch: false)
            }
            .accessibilityIdentifier("Project.WorktreeDelete.KeepBranch")
            Button("Cancel", role: .cancel) { worktreePendingDeletion = nil }
        } message: { worktree in
            Text(deletionWarning(for: worktree))
        }
    }

    /// Everything the dialog has to say that the title can't: the directory
    /// that is about to leave the disk, the uncommitted work inside it, and
    /// the session that would go with it.
    private func deletionWarning(for worktree: GitWorktree) -> String {
        var lines = [worktree.path.path]
        if let snapshot = snapshots[worktree.path.standardizedFileURL], !snapshot.isClean {
            lines.append(
                "\(snapshot.changedFileCount) uncommitted file\(snapshot.changedFileCount == 1 ? "" : "s") "
                + "(+\(snapshot.diffStat.additions) −\(snapshot.diffStat.deletions)) will be lost."
            )
        }
        if let session = sessionFor(worktree) {
            lines.append("The session “\(session.title)” lives here and will be deleted too.")
        }
        return lines.joined(separator: "\n")
    }

    private func delete(_ worktree: GitWorktree, deleteBranch: Bool) {
        worktreePendingDeletion = nil
        Task {
            await context.store.deleteWorktree(
                at: worktree.path,
                in: project.rootPath,
                branch: worktree.branch,
                deleteBranch: deleteBranch
            )
            await viewModel.refreshWorktrees()
        }
    }

    // MARK: Working tree

    /// The main checkout at a glance. The diff bar carries the shape of the
    /// change — how much of it is additions — which the two numbers alone
    /// never showed.
    private var workingTreeBlock: some View {
        Button(action: openGit) {
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.small) {
                    sectionLabel("Working tree")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }

                HStack(spacing: 6) {
                    GitBranchIcon(size: 11)
                    Text(pulse.branch.map(BranchNaming.displayName) ?? "—")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: FlotillaSpacing.small)
                    if pulse.unpushedCount > 0 {
                        countChip("↑\(pulse.unpushedCount)", tint: FlotillaColors.statusReady)
                    }
                }

                if pulse.diffStat.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.success)
                        Text("Working tree clean")
                            .font(.system(size: 12))
                            .foregroundStyle(FlotillaColors.textSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 7) {
                        DiffBar(stat: pulse.diffStat, height: 8)
                        HStack(spacing: 8) {
                            Text("+\(pulse.diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                            Text("−\(pulse.diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                            Spacer()
                            Text("\(pulse.changedFileCount) file\(pulse.changedFileCount == 1 ? "" : "s")")
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .monospacedDigit()
                    }
                }
            }
            .padding(FlotillaSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func countChip(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }

    // MARK: Worktrees

    private var sortedWorktrees: [GitWorktree] {
        worktrees.sorted { lhs, rhs in
            if lhs.isMainWorktree != rhs.isMainWorktree { return lhs.isMainWorktree }
            let ls = sessionFor(lhs) != nil, rs = sessionFor(rhs) != nil
            if ls != rs { return ls }
            let ld = snapshots[lhs.path.standardizedFileURL]?.isClean == false
            let rd = snapshots[rhs.path.standardizedFileURL]?.isClean == false
            if ld != rd { return ld }
            return lhs.branch < rhs.branch
        }
    }

    @ViewBuilder
    private var worktreesBlock: some View {
        let all = sortedWorktrees
        let shown = showAllWorktrees ? all : Array(all.prefix(worktreePreview))
        let attached = all.filter { sessionFor($0) != nil }.count

        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: FlotillaSpacing.small) {
                sectionLabel("Worktrees")
                if viewModel.isLoadingWorktrees {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 14, height: 14)
                } else {
                    Text("\(all.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                Spacer()
                if attached > 0 {
                    countChip("\(attached) active", tint: FlotillaColors.statusWorking)
                }
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.bottom, 4)

            if viewModel.isLoadingWorktrees {
                worktreesSkeleton
                    .transition(.opacity)
            } else if all.isEmpty {
                Text("No worktrees")
                    .font(.system(size: 11))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, FlotillaSpacing.small)
                    .transition(.opacity)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(shown, id: \.path) { worktree in
                        WorktreeContextRow(
                            worktree: worktree,
                            session: sessionFor(worktree),
                            snapshot: snapshots[worktree.path.standardizedFileURL],
                            onOpen: { openWorktreeInGit(worktree) },
                            onOpenSession: { context.openSession($0) },
                            onRequestDelete: { worktreePendingDeletion = worktree }
                        )
                    }
                }
                .transition(.opacity)

                if all.count > worktreePreview {
                    Button {
                        withAnimation(FlotillaMotion.fast.curve) { showAllWorktrees.toggle() }
                    } label: {
                        Text(showAllWorktrees ? "Show fewer" : "Show all \(all.count) →")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .padding(.top, 6)
                            .padding(.horizontal, FlotillaSpacing.small)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .animation(FlotillaMotion.fast.curve, value: viewModel.isLoadingWorktrees)
        .animation(FlotillaMotion.fast.curve, value: shown.map(\.path))
        .padding(FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var worktreesSkeleton: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                WorktreeRowSkeleton(index: index)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading worktrees")
    }

    private func openWorktreeInGit(_ worktree: GitWorktree) {
        navigator.setProjectGitScope(worktree.path, for: project.id)
        withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(.git, for: project.id) }
    }

    // MARK: This week

    /// The week's commit rhythm, and the numbers behind whichever slice of it
    /// is in focus: the whole week by default, or one day once a bar is
    /// picked.
    private var thisWeekBlock: some View {
        let days = weekDays
        let focused = selectedWeekDay.flatMap { id in days.first { $0.id == id } }
        let stat = focused?.stat ?? weekStat

        return VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                sectionLabel("This week")
                Spacer()
                if let focused {
                    Text(focused.longLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textSecondary)
                    Button {
                        withAnimation(FlotillaMotion.fast.curve) { selectedWeekDay = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Show the whole week")
                }
            }
            .padding(.bottom, 2)

            CommitWeekChart(days: days, selection: $selectedWeekDay) { day in
                openHistory(around: day.date)
            }

            weekRow("Commits", "\(focused?.count ?? commitsThisWeek)")
            if focused == nil {
                weekRow("Sessions", "\(sessionsThisWeek)")
            }
            if !stat.isEmpty {
                churnRow(stat)
            }

            if let focused, focused.count > 0 {
                Button {
                    openHistory(around: focused.date)
                } label: {
                    Text("Open in history →")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .padding(.top, 2)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Opens the Git surface's commit history with that day's newest commit
    /// selected, so picking a bar lands on the work it counts.
    private func openHistory(around day: Date) {
        let calendar = Calendar.current
        let root = project.rootPath.standardizedFileURL
        navigator.setProjectGitScope(root, for: project.id)
        navigator.setProjectGitSubTab(.commits, for: project.id)
        if let commit = pulse.recentCommits.first(where: { calendar.isDate($0.authorDate, inSameDayAs: day) }) {
            navigator.projectGraphViewModel(for: root, gitService: context.store.gitService).selectedSHA = commit.sha
        }
        withAnimation(FlotillaMotion.fast.curve) { navigator.setProjectTab(.git, for: project.id) }
    }

    private var weekDays: [CommitWeekChart.Day] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let initial = DateFormatter()
        initial.dateFormat = "EEEEE"
        let long = DateFormatter()
        long.dateFormat = "EEE d MMM"

        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let commits = pulse.recentCommits.filter { calendar.isDate($0.authorDate, inSameDayAs: day) }
            return CommitWeekChart.Day(
                id: offset,
                initial: initial.string(from: day),
                longLabel: offset == 0 ? "Today" : long.string(from: day),
                date: day,
                count: commits.count,
                stat: commits.reduce(GitDiffStat(additions: 0, deletions: 0)) { $0 + $1.stat },
                isToday: offset == 0
            )
        }
    }

    /// Churn is a diff like any other, so it reads like one: green additions,
    /// red deletions, and the same proportional bar the working tree uses —
    /// the balance of the week's work at a glance instead of two grey numbers.
    private func churnRow(_ stat: GitDiffStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Churn")
                    .font(.system(size: 12))
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                HStack(spacing: 6) {
                    Text("+\(stat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                    Text("−\(stat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                }
                .font(.system(size: 12, weight: .medium, design: .monospaced))
            }
            DiffBar(stat: stat, height: 5)
        }
        .padding(.top, 1)
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
            // No liquid strip here — a zero-radius glass band under section
            // labels reads as a broken square bar across the feed.
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
                    Text(BranchNaming.displayName(for: branch))
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
                    .foregroundStyle(FlotillaColors.textSecondary)
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
                HStack(spacing: 4) {
                    Text("+\(commit.stat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                    Text("−\(commit.stat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                }
                .font(.system(size: 10, design: .monospaced))
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

// MARK: - Worktree row

/// One worktree in the context rail: what branch it is on, who is working in
/// it, and how far its working copy has drifted — plus the right-click menu
/// that opens, reveals, or deletes it.
private struct WorktreeContextRow: View {
    let worktree: GitWorktree
    let session: Session?
    let snapshot: WorktreeSnapshot?
    let onOpen: () -> Void
    let onOpenSession: (UUID) -> Void
    let onRequestDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: FlotillaSpacing.small) {
                indicator
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(BranchNaming.displayName(for: worktree.branch))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(isProminent ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 4)
                        metrics
                    }

                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                .animation(FlotillaMotion.fast.curve, value: snapshot)
            }
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 6)
            .background {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .fill(isHovering ? FlotillaColors.surfaceElevated : .clear)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityIdentifier(AXID.worktreeRow(worktree.branch))
        .contextMenu {
            Button("Open in Git", action: onOpen)
            if let session {
                Button("Open Session") { onOpenSession(session.id) }
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.path.path, forType: .string)
            }
            Button("Copy Branch") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(worktree.branch, forType: .string)
            }
            if !worktree.isMainWorktree {
                Divider()
                Button("Delete Worktree…", role: .destructive, action: onRequestDelete)
                    .accessibilityIdentifier("Project.WorktreeRow-\(worktree.branch)-DeleteMenuItem")
            }
        }
    }

    private var isProminent: Bool { session != nil || worktree.isMainWorktree }

    @ViewBuilder
    private var indicator: some View {
        if worktree.isMainWorktree {
            Image(systemName: "house.fill")
                .font(.system(size: 9))
                .foregroundStyle(FlotillaColors.accent)
        } else if let session {
            Circle()
                .fill(StatusPresentation.color(for: session.status))
                .frame(width: 6, height: 6)
        } else {
            Circle()
                .strokeBorder(FlotillaColors.separatorStrong, lineWidth: 1)
                .frame(width: 6, height: 6)
        }
    }

    /// The loudest thing true about this checkout: uncommitted work first,
    /// then unpushed commits, then nothing at all.
    @ViewBuilder
    private var metrics: some View {
        if let snapshot, !snapshot.isClean {
            HStack(spacing: 4) {
                Text("+\(snapshot.diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                Text("−\(snapshot.diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
            }
            .font(.system(size: 10, design: .monospaced))
            .monospacedDigit()
            .transition(.opacity)
        } else if let snapshot, snapshot.unpushedCount > 0 {
            Text("↑\(snapshot.unpushedCount)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.statusReady)
                .transition(.opacity)
        }
    }

    private var subtitle: String? {
        if let session {
            return "\(session.title) · \(session.agent.displayName)"
        }
        if worktree.isMainWorktree { return "Main checkout" }
        if let snapshot, snapshot.changedFileCount > 0 {
            return "\(snapshot.changedFileCount) uncommitted file\(snapshot.changedFileCount == 1 ? "" : "s")"
        }
        return nil
    }
}

// MARK: - Worktree skeleton

private struct WorktreeRowSkeleton: View {
    let index: Int
    @State private var isPulsing = false

    private var lineWidth: CGFloat {
        switch index % 4 {
        case 0: return 120
        case 1: return 85
        case 2: return 145
        default: return 100
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.small) {
            Circle()
                .fill(FlotillaColors.separatorStrong.opacity(0.6))
                .frame(width: 6, height: 6)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(FlotillaColors.surfaceElevated)
                    .frame(width: lineWidth, height: 10)

                if index == 0 {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(FlotillaColors.surfaceElevated.opacity(0.6))
                        .frame(width: 65, height: 8)
                }
            }

            Spacer()

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(FlotillaColors.surfaceElevated.opacity(0.5))
                .frame(width: 32, height: 10)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 6)
        .opacity(isPulsing ? 0.35 : 0.8)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

// MARK: - Diff bar

/// Additions and deletions as one proportional green/red bar on a faint
/// track. Each present side is floored at a visible width, so a one-line
/// change reads as a sliver rather than rounding away to nothing.
private struct DiffBar: View {
    let stat: GitDiffStat
    var height: CGFloat = 6
    var spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let widths = segmentWidths(in: geo.size.width)
            HStack(spacing: spacing) {
                if stat.additions > 0 {
                    Capsule().fill(FlotillaColors.diffAdded).frame(width: widths.additions)
                }
                if stat.deletions > 0 {
                    Capsule().fill(FlotillaColors.diffRemoved).frame(width: widths.deletions)
                }
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height)
        .background { Capsule().fill(FlotillaColors.separator) }
        .accessibilityLabel("\(stat.additions) additions, \(stat.deletions) deletions")
    }

    private func segmentWidths(in width: CGFloat) -> (additions: CGFloat, deletions: CGFloat) {
        let total = CGFloat(stat.additions + stat.deletions)
        guard total > 0 else { return (0, 0) }

        let hasBoth = stat.additions > 0 && stat.deletions > 0
        let usable = max(0, width - (hasBoth ? spacing : 0))
        var additions = usable * CGFloat(stat.additions) / total
        var deletions = usable - additions

        if hasBoth {
            let floorWidth = min(height, usable / 2)
            if additions < floorWidth {
                additions = floorWidth
                deletions = usable - additions
            } else if deletions < floorWidth {
                deletions = floorWidth
                additions = usable - deletions
            }
        } else if stat.additions == 0 {
            additions = 0
            deletions = usable
        } else {
            additions = usable
            deletions = 0
        }
        return (additions, deletions)
    }
}

// MARK: - Commit week chart

/// Seven days of commits as hoverable, selectable bars. Hovering reveals that
/// day's count above its bar; clicking pins the day so the numbers under the
/// chart describe it, and clicking the pinned day again opens its commits in
/// the history surface.
private struct CommitWeekChart: View {
    struct Day: Identifiable, Equatable {
        let id: Int
        let initial: String
        let longLabel: String
        let date: Date
        let count: Int
        let stat: GitDiffStat
        let isToday: Bool
    }

    let days: [Day]
    @Binding var selection: Int?
    let onActivate: (Day) -> Void

    @State private var hovered: Int?

    private let barsHeight: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(days) { day in
                column(day)
            }
        }
        .animation(FlotillaMotion.fast.curve, value: hovered)
        .animation(FlotillaMotion.fast.curve, value: selection)
    }

    private func column(_ day: Day) -> some View {
        let isFocused = hovered == day.id || selection == day.id
        let peak = max(1, days.map(\.count).max() ?? 1)

        return Button {
            if selection == day.id {
                onActivate(day)
            } else {
                selection = day.id
            }
        } label: {
            VStack(spacing: 3) {
                // Always laid out, so revealing a count never shifts the bars.
                Text(isFocused ? "\(day.count)" : " ")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .frame(height: 11)

                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(isFocused ? FlotillaColors.accent.opacity(0.10) : .clear)
                        .frame(height: barsHeight)

                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(fill(for: day, isFocused: isFocused))
                        .frame(height: max(2, barsHeight * CGFloat(day.count) / CGFloat(peak)))
                }
                .frame(height: barsHeight)

                Text(day.initial)
                    .font(.system(size: 9, weight: day.isToday || isFocused ? .bold : .regular))
                    .foregroundStyle(
                        day.isToday || isFocused ? FlotillaColors.textSecondary : FlotillaColors.textTertiary
                    )

                // Selection ticks the day it pins.
                Capsule()
                    .fill(selection == day.id ? FlotillaColors.accent : .clear)
                    .frame(width: 10, height: 2)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? day.id : (hovered == day.id ? nil : hovered) }
        .help("\(day.longLabel) — \(day.count) commit\(day.count == 1 ? "" : "s")")
        .accessibilityIdentifier(AXID.commitWeekChartDay(day.id))
    }

    private func fill(for day: Day, isFocused: Bool) -> Color {
        guard day.count > 0 else { return FlotillaColors.separatorStrong }
        if isFocused { return FlotillaColors.accent }
        return FlotillaColors.accent.opacity(day.isToday ? 0.85 : 0.5)
    }
}
