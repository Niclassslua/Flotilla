import SwiftUI
import SessionKit
import GitKit
import DesignSystem

extension CICheckState {
    var systemImage: String {
        switch self {
        case .passing: "checkmark.circle.fill"
        case .failing: "xmark.circle.fill"
        case .pending: "circle.dotted"
        case .skipped: "minus.circle"
        }
    }

    var tint: Color {
        switch self {
        case .passing: FlotillaColors.success
        case .failing: FlotillaColors.danger
        case .pending: FlotillaColors.warning
        case .skipped: FlotillaColors.textTertiary
        }
    }

    var label: String {
        switch self {
        case .passing: "Passing"
        case .failing: "Failing"
        case .pending: "Running"
        case .skipped: "Skipped"
        }
    }
}

/// CI reduced to one glyph for dense surfaces — sidebar rows and board cards.
/// `quiet` hides the states that ask nothing of the user (passing, skipped),
/// so a long navigator only lights up where something is red or still
/// running.
struct CIStatusGlyph: View {
    let state: CICheckState?
    var quiet = false

    var body: some View {
        if let state, !quiet || state == .failing || state == .pending {
            Image(systemName: state == .failing ? "xmark.seal.fill" : state.systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(state.tint)
                .help("CI \(state.label.lowercased())")
                .accessibilityLabel("CI \(state.label)")
        }
    }
}

extension CIVerdict {
    var title: String {
        switch self {
        case .merged: "Merged"
        case .closed: "Closed"
        case .failing: "Failing"
        case .mergeConflict: "Merge conflict"
        case .running: "Running"
        case .changesRequested: "Changes requested"
        case .draft: "Draft"
        case .waitingForReview: "Waiting for review"
        case .blocked: "Blocked by branch rules"
        case .readyToMerge: "Ready to merge"
        case .passing: "Checks passing"
        case .commitPassing: "Commit passing"
        case .skipped: "Checks skipped"
        case .notPushed: "Not pushed"
        case .noChecks: "No checks"
        }
    }

    var systemImage: String {
        switch self {
        case .merged: "arrow.triangle.merge"
        case .closed: "xmark.circle"
        case .failing, .mergeConflict: "xmark.circle.fill"
        case .running: "circle.dotted"
        case .changesRequested, .blocked: "exclamationmark.circle.fill"
        case .draft, .waitingForReview: "clock"
        case .readyToMerge, .passing, .commitPassing: "checkmark.circle.fill"
        case .skipped, .noChecks: "minus.circle"
        case .notPushed: "arrow.up.circle"
        }
    }

    var tint: Color {
        switch self {
        case .failing, .mergeConflict: FlotillaColors.danger
        case .running, .changesRequested, .blocked: FlotillaColors.warning
        case .readyToMerge, .passing, .commitPassing, .merged: FlotillaColors.success
        case .closed, .draft, .waitingForReview, .skipped, .notPushed, .noChecks: FlotillaColors.textTertiary
        }
    }

    /// Whether there is anything to say in a one-line chip.
    var isWorthAChip: Bool { self != .noChecks && self != .notPushed }
}

/// A progress ring for checks still running.
private struct CIProgressRing: View {
    let done: Int
    let total: Int

    var body: some View {
        ZStack {
            Circle().stroke(FlotillaColors.warning.opacity(0.25), lineWidth: 1.6)
            Circle()
                .trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1)))
                .stroke(FlotillaColors.warning, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 9, height: 9)
    }
}

/// CI on a session list row, in GitHub's circular check and X. Counts get a
/// tinted pill so red stands out down a long list; a pass stays a bare icon.
struct CISessionRowBadge: View {
    let badge: CIRowBadge
    var isForOlderCommit = false

    var body: some View {
        content
            .opacity(isForOlderCommit ? 0.6 : 1)
            .help(isForOlderCommit ? "\(label) (older commit)" : label)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private var content: some View {
        switch badge {
        case .failing(let count, let total):
            pill(FlotillaColors.danger) { circle("xmark.circle.fill", FlotillaColors.danger); Text("\(count)/\(total)") }
        case .running(let done, let total):
            pill(FlotillaColors.warning) { CIProgressRing(done: done, total: total); Text("\(done)/\(total)") }
        case .conflict:
            pill(FlotillaColors.danger) { circle("xmark.circle.fill", FlotillaColors.danger); Text("Conflict") }
        case .fixing:
            pill(FlotillaColors.accent) {
                Image(systemName: "wand.and.sparkles").font(.system(size: 9, weight: .bold)).foregroundStyle(FlotillaColors.accent)
                Text("Fixing")
            }
        case .passed:
            circle("checkmark.circle.fill", FlotillaColors.success)
        }
    }

    private func circle(_ systemName: String, _ color: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
    }

    private func pill<Content: View>(_ color: Color, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 3) { content() }
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.leading, 3)
            .padding(.trailing, 6)
            .frame(height: 15)
            .background(color.opacity(0.15), in: Capsule())
            .fixedSize()
    }

    private var label: String {
        switch badge {
        case .failing(let count, let total): "CI \(count) of \(total) failing"
        case .running(let done, let total): "CI \(done) of \(total) done"
        case .conflict: "Merge conflict"
        case .fixing: "Agent is fixing CI"
        case .passed: "CI passed"
        }
    }
}

/// The session bar's one-glance CI answer: where the work stands, progress
/// or failure count, and the PR number. Clicking it opens the Checks tab.
struct CIStatusChip: View {
    let snapshot: CISnapshot
    let agentName: String
    let action: () -> Void

    var body: some View {
        let verdict = snapshot.verdict
        if verdict.isWorthAChip {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: snapshot.fix == nil ? verdict.systemImage : "wand.and.sparkles")
                        .foregroundStyle(snapshot.fix == nil ? verdict.tint : FlotillaColors.accent)
                        .symbolEffect(.pulse, isActive: isRunning(verdict) || snapshot.fix != nil)
                    Text(summary(for: verdict))
                        .foregroundStyle(isFailing(verdict) ? FlotillaColors.danger : FlotillaColors.textSecondary)
                    if let pullRequest = snapshot.status?.pullRequest {
                        Text("#\(pullRequest.number)")
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(isFailing(verdict) ? FlotillaColors.danger.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
                .opacity(snapshot.isForOlderCommit ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .help(snapshot.isForOlderCommit ? "These results are for an older commit — show checks" : "\(verdict.title) — show checks")
            .accessibilityLabel("CI \(summary(for: verdict))")
            .accessibilityIdentifier("SessionBar.CIStatus")
        }
    }

    private func isFailing(_ verdict: CIVerdict) -> Bool {
        guard snapshot.fix == nil else { return false }
        if case .failing = verdict { return true }
        return verdict == .mergeConflict
    }

    private func isRunning(_ verdict: CIVerdict) -> Bool {
        if case .running = verdict { return true }
        return false
    }

    private func summary(for verdict: CIVerdict) -> String {
        if snapshot.fix != nil { return "\(agentName) is fixing" }
        switch verdict {
        case .failing(let count, let total): return "\(count)/\(total) failing"
        case .running(let done, let total): return "\(done)/\(total) done"
        default: return verdict.title
        }
    }
}

/// The Git sidebar's Checks tab, built around the next action: where this
/// work stands, the one thing to do about it, and why each failure failed.
/// A pull request adds review and merge states; a direct push gets the same
/// rows and the same actions.
struct SessionChecksView: View {
    let session: Session
    let store: AppStore
    let onReviewPrompt: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var isRefreshing = false
    @State private var isSending = false
    @State private var sendError: String?
    @State private var expandedChecks: Set<String> = []
    @State private var showsSettledChecks = false

    private var ci: CIStatusStore { store.ciStatusStore }

    var body: some View {
        let snapshot = ci.snapshot(for: session.id)
        Group {
            if store.ghService == nil {
                unavailable("GitHub CLI Not Found", "Install gh and run “gh auth login” to see CI checks.", systemImage: "terminal")
            } else if CIStatusStore.branch(of: session) == nil {
                unavailable("No Branch to Check", "Only sessions in their own worktree have a branch for CI to run on.", systemImage: "arrow.triangle.branch")
            } else if !snapshot.hasLoaded {
                ProgressView("Checking GitHub…")
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let status = snapshot.status, !status.checks.isEmpty || status.pullRequest != nil {
                list(status, snapshot: snapshot)
            } else {
                emptyState(snapshot)
            }
        }
        .task { await refresh() }
    }

    // MARK: - Empty states

    @ViewBuilder
    private func emptyState(_ snapshot: CISnapshot) -> some View {
        switch snapshot.problem {
        case .signedOut:
            unavailable("Sign In to GitHub", "Run “gh auth login” in a terminal, then check again.", systemImage: "person.crop.circle.badge.exclamationmark", retry: true)
        case .notGitHub:
            unavailable("Not a GitHub Repository", "Checks need a repository with a GitHub remote.", systemImage: "questionmark.folder")
        case .offline:
            unavailable("Can’t Reach GitHub", "Check your connection and try again.", systemImage: "wifi.slash", retry: true)
        case .other(let message):
            unavailable("Couldn’t Check CI", message, systemImage: "exclamationmark.triangle", retry: true)
        case nil:
            if snapshot.isWaitingForFirstCommit {
                unavailable("No Commits From This Session", "CI appears after the session’s first commit. You can show it sooner in Settings > Git & Worktrees.", systemImage: "circle.dashed", retry: true)
            } else if let tip = snapshot.tip, !tip.isPushed {
                unavailable("Not Pushed Yet", "\(tip.unpushedCount) local \(tip.unpushedCount == 1 ? "commit isn’t" : "commits aren’t") on GitHub, so CI hasn’t run.", systemImage: "arrow.up.circle", retry: true)
            } else if snapshot.isAwaitingCI {
                unavailable("Waiting for CI to Start", "This commit was just pushed. Checks appear as soon as GitHub starts them.", systemImage: "clock", retry: true)
            } else {
                unavailable("No CI on This Commit", "GitHub reports no checks for this commit. The repository’s workflows may not run on this branch.", systemImage: "checklist", retry: true)
            }
        }
    }

    private func unavailable(_ title: String, _ message: String, systemImage: String, retry: Bool = false) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if retry {
                Button("Check Again") { Task { await refresh() } }
                    .disabled(isRefreshing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List

    private func list(_ status: CIStatus, snapshot: CISnapshot) -> some View {
        let ordered = sorted(status.checks)
        let needingAttention = ordered.filter { $0.state == .failing || $0.state == .pending }
        let settled = ordered.filter { $0.state == .passing || $0.state == .skipped }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(status, snapshot: snapshot)
                notes(snapshot)
                actionRow(status, snapshot: snapshot)
                Divider()
                ForEach(needingAttention) { check in
                    checkRow(check)
                    Divider().padding(.leading, FlotillaSpacing.medium)
                }
                settledSection(settled, startsOpen: needingAttention.isEmpty)
            }
        }
        .accessibilityIdentifier("GitSidebar.Checks.List")
    }

    private func header(_ status: CIStatus, snapshot: CISnapshot) -> some View {
        let verdict = snapshot.verdict
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: verdict.systemImage)
                    .foregroundStyle(verdict.tint)
                    .symbolEffect(.pulse, isActive: status.hasPendingChecks)
                Text(status.checks.isEmpty && snapshot.isAwaitingCI ? "Waiting for CI" : verdict.title)
                    .font(FlotillaTypography.callout.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .accessibilityIdentifier("GitSidebar.Checks.Verdict")
                Spacer(minLength: 0)
                refreshButton
                if let link = status.pullRequest?.url ?? status.checks.first?.url {
                    iconButton("arrow.up.right.square", help: status.pullRequest == nil ? "Open on GitHub" : "Open Pull Request on GitHub") {
                        openURL(link)
                    }
                }
            }
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(subtitle(status, snapshot: snapshot))
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.top, FlotillaSpacing.medium)
        .padding(.bottom, FlotillaSpacing.small)
    }

    private func subtitle(_ status: CIStatus, snapshot: CISnapshot) -> String {
        var parts: [String] = []
        if let pullRequest = status.pullRequest { parts.append("PR #\(pullRequest.number)") }
        switch snapshot.verdict {
        case .failing(let count, let total): parts.append("\(count) of \(total) failing")
        case .running(let done, let total): parts.append("\(done) of \(total) done")
        case .readyToMerge(let optional) where optional > 0: parts.append("\(optional) optional failing")
        default: break
        }
        if let commit = status.commitSHA { parts.append("commit \(commit.prefix(7))") }
        if let updated = snapshot.lastUpdated { parts.append(age(of: updated)) }
        return parts.joined(separator: " · ")
    }

    private func age(of date: Date) -> String {
        Date().timeIntervalSince(date) < 60
            ? "just now"
            : date.formatted(.relative(presentation: .numeric, unitsStyle: .abbreviated))
    }

    @ViewBuilder
    private func notes(_ snapshot: CISnapshot) -> some View {
        if snapshot.isForOlderCommit, let commit = snapshot.status?.commitSHA, let tip = snapshot.tip {
            note(tip.isPushed
                 ? "Results are for \(commit.prefix(7)). \(tip.sha.prefix(7)) hasn’t reported yet."
                 : "Results are for \(commit.prefix(7)). Your latest commit isn’t pushed.")
        }
        if let problem = snapshot.problem {
            note("Couldn’t update: \(describe(problem)). Showing the last result.")
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "clock.arrow.circlepath")
            .font(FlotillaTypography.caption2)
            .foregroundStyle(FlotillaColors.warning)
            .padding(.horizontal, FlotillaSpacing.medium)
            .padding(.bottom, FlotillaSpacing.small)
    }

    private func describe(_ problem: CIPollProblem) -> String {
        switch problem {
        case .signedOut: "signed out of GitHub"
        case .notGitHub: "not a GitHub repository"
        case .offline: "GitHub can’t be reached"
        case .other(let message): message
        }
    }

    @ViewBuilder
    private func actionRow(_ status: CIStatus, snapshot: CISnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fix = snapshot.fix {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("\(session.agent.displayName) is fixing\(fix.commitSHA.map { " · \($0.prefix(7))" } ?? "")")
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
                .accessibilityIdentifier("GitSidebar.Checks.Fixing")
            } else if status.isActionable, !status.failuresToFix.isEmpty {
                HStack(spacing: 8) {
                    Menu {
                        Button("Review Prompt First…", action: onReviewPrompt)
                    } label: {
                        Label(isSending ? "Sending…" : fixTitle(status), systemImage: "wand.and.sparkles")
                    } primaryAction: {
                        Task { await send() }
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSending)
                    .accessibilityIdentifier("GitSidebar.Checks.Fix")

                    if !snapshot.isDismissed, !status.blockingFailures.isEmpty {
                        Button("Dismiss") { ci.dismissFailure(sessionID: session.id) }
                            .controlSize(.small)
                            .help("Stop counting this commit’s failure in Needs You")
                            .accessibilityIdentifier("GitSidebar.Checks.Dismiss")
                    }
                }
            }
            if let sendError {
                Label(sendError, systemImage: "exclamationmark.triangle.fill")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.danger)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.bottom, FlotillaSpacing.medium)
    }

    private func fixTitle(_ status: CIStatus) -> String {
        let count = status.failuresToFix.count
        return "Fix \(count) \(count == 1 ? "failure" : "failures") with \(session.agent.displayName)"
    }

    private func checkRow(_ check: CICheck) -> some View {
        let isExpanded = expandedChecks.contains(check.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    rowTapped(check)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: check.state.systemImage)
                            .foregroundStyle(check.state.tint)
                            .symbolEffect(.pulse, isActive: check.state == .pending)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(check.name)
                                .font(FlotillaTypography.caption.weight(.medium))
                                .foregroundStyle(FlotillaColors.textPrimary)
                                .lineLimit(1)
                            detailText(for: check)
                        }
                        Spacer(minLength: 0)
                        if check.state == .failing {
                            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(check.name)
                .accessibilityIdentifier("GitSidebar.Checks.Row")

                if let url = check.url {
                    iconButton("arrow.up.right", help: "Open this check on GitHub") { openURL(url) }
                }
            }
            if isExpanded {
                CIFailureExcerptView(check: check, sessionID: session.id, ci: ci)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
    }

    private func rowTapped(_ check: CICheck) {
        if check.state == .failing {
            if !expandedChecks.insert(check.id).inserted { expandedChecks.remove(check.id) }
        } else if let url = check.url {
            openURL(url)
        }
    }

    @ViewBuilder
    private func settledSection(_ checks: [CICheck], startsOpen: Bool) -> some View {
        if !checks.isEmpty {
            let isOpen = showsSettledChecks || startsOpen
            if !startsOpen {
                Button {
                    showsSettledChecks.toggle()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text(settledSummary(checks))
                            .font(FlotillaTypography.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, FlotillaSpacing.medium)
                    .padding(.vertical, FlotillaSpacing.small)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("GitSidebar.Checks.Settled")
            }
            if isOpen {
                ForEach(checks) { check in
                    checkRow(check)
                    Divider().padding(.leading, FlotillaSpacing.medium)
                }
            }
        }
    }

    private func settledSummary(_ checks: [CICheck]) -> String {
        let passed = checks.filter { $0.state == .passing }.count
        let skipped = checks.count - passed
        return [passed > 0 ? "\(passed) passed" : nil, skipped > 0 ? "\(skipped) skipped" : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private var refreshButton: some View {
        iconButton("arrow.clockwise", help: "Check again now") {
            Task { await refresh() }
        }
        .disabled(isRefreshing)
        .accessibilityIdentifier("GitSidebar.Checks.Refresh")
    }

    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textTertiary)
        .help(help)
        .accessibilityLabel(help)
    }

    /// Failures first — they are why anyone opened this tab — then what is
    /// still running, then the rest.
    private func sorted(_ checks: [CICheck]) -> [CICheck] {
        let rank: [CICheckState: Int] = [.failing: 0, .pending: 1, .passing: 2, .skipped: 3]
        return checks.enumerated()
            .sorted { (rank[$0.element.state] ?? 9, $0.offset) < (rank[$1.element.state] ?? 9, $1.offset) }
            .map(\.element)
    }

    @ViewBuilder
    private func detailText(for check: CICheck) -> some View {
        if check.state == .pending, check.startedAt != nil {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                detailLabel(detail(for: check, now: context.date))
            }
        } else {
            detailLabel(detail(for: check, now: Date()))
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text)
            .font(FlotillaTypography.caption3)
            .foregroundStyle(FlotillaColors.textTertiary)
            .lineLimit(1)
    }

    private func detail(for check: CICheck, now: Date) -> String {
        var parts: [String] = []
        if let workflow = check.workflowName, workflow != check.name { parts.append(workflow) }
        if let started = check.startedAt {
            let seconds = max(0, Int((check.completedAt ?? now).timeIntervalSince(started)))
            parts.append(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")
        }
        parts.append(check.state.label)
        if check.isRequired == false { parts.append("Optional") }
        return parts.joined(separator: " · ")
    }

    private func refresh() async {
        isRefreshing = true
        await ci.refresh(sessionID: session.id)
        isRefreshing = false
    }

    private func send() async {
        isSending = true
        sendError = nil
        defer { isSending = false }
        do {
            try await ci.sendFailuresToAgent(sessionID: session.id)
        } catch {
            sendError = error.localizedDescription
        }
    }
}

/// Why one check failed, inside its expanded row.
private struct CIFailureExcerptView: View {
    let check: CICheck
    let sessionID: UUID
    let ci: CIStatusStore
    @Environment(\.openURL) private var openURL
    @State private var excerpt: String?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let excerpt {
                if excerpt.isEmpty {
                    Text("This check doesn’t publish a log here. Open it on GitHub for details.")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                } else {
                    ScrollView {
                        Text(excerpt)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 220)
                    .accessibilityIdentifier("GitSidebar.Checks.Excerpt")
                }
            } else if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.danger)
            } else {
                ProgressView("Fetching the log…").controlSize(.small)
            }
            if check.jobID != nil {
                Button("Show Full Log") { Task { await showFullLog() } }
                    .buttonStyle(.link)
                    .font(FlotillaTypography.caption2)
            }
        }
        .task(id: check.id) { await load() }
    }

    private func load() async {
        do {
            excerpt = try await ci.excerpt(for: check, sessionID: sessionID)
        } catch {
            errorMessage = "Couldn’t fetch the log: \(error.localizedDescription)"
        }
    }

    private func showFullLog() async {
        do {
            if let file = try await ci.fullLogFile(for: check, sessionID: sessionID) { openURL(file) }
        } catch {
            errorMessage = "Couldn’t fetch the log: \(error.localizedDescription)"
        }
    }
}

/// Shows the prompt built from the failing checks, editable, before it goes
/// to the agent. Nothing reaches the session until the user presses Send.
struct CIFailureSendSheet: View {
    let session: Session
    let store: AppStore
    let onDismiss: () -> Void

    @State private var prompt = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send CI Failures to Agent")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(session.title)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            .padding(FlotillaSpacing.large)
            Divider()

            ZStack {
                TextEditor(text: $prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(FlotillaSpacing.small)
                    .opacity(isLoading ? 0 : 1)
                if isLoading {
                    ProgressView("Fetching the failing logs…")
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            HStack {
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.danger)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Send to \(session.agent.displayName)") {
                    Task { await send() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isLoading || isSending || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(FlotillaSpacing.large)
        }
        .frame(width: 640, height: 480)
        .task { await loadPrompt() }
    }

    private func loadPrompt() async {
        let result = await store.ciStatusStore.failurePrompt(sessionID: session.id)
        prompt = result.prompt
        errorMessage = result.warning
        isLoading = false
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            try await store.ciStatusStore.deliverFixPrompt(prompt, to: session.id)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
