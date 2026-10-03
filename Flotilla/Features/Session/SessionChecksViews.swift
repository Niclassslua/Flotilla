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

/// The session bar's one-glance CI answer: a state glyph, how many checks
/// failed, and the PR number. Clicking it opens the Checks tab.
struct CIStatusChip: View {
    let status: CIStatus
    let action: () -> Void

    var body: some View {
        if let state = status.state {
            Button(action: action) {
                HStack(spacing: 4) {
                    Image(systemName: state.systemImage)
                        .foregroundStyle(state.tint)
                        .symbolEffect(.pulse, isActive: state == .pending)
                    Text(summary(for: state))
                        .foregroundStyle(state == .failing ? FlotillaColors.danger : FlotillaColors.textSecondary)
                    if let pullRequest = status.pullRequest {
                        Text("#\(pullRequest.number)")
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(state == .failing ? FlotillaColors.danger.opacity(0.12) : .clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("CI \(state.label.lowercased()) — show checks")
            .accessibilityLabel("CI \(state.label)")
            .accessibilityIdentifier("SessionBar.CIStatus")
        }
    }

    private func summary(for state: CICheckState) -> String {
        let counted = status.checks.filter { $0.state != .skipped }
        switch state {
        case .failing: return "\(status.failingChecks.count)/\(counted.count) failing"
        case .pending: return "CI running"
        case .passing: return "CI passing"
        case .skipped: return "CI skipped"
        }
    }
}

/// The Git sidebar's Checks tab: the session's pull request and every check
/// on its newest commit, with failures first and a way to hand one to the
/// agent.
struct SessionChecksView: View {
    let session: Session
    let store: AppStore
    let onSendFailure: (CICheck) -> Void
    @Environment(\.openURL) private var openURL
    @State private var isRefreshing = false

    private var status: CIStatus? { store.ciStatusStore.status(for: session.id) }

    var body: some View {
        Group {
            if store.ghService == nil {
                unavailable("GitHub CLI Not Found", "Install gh and sign in with `gh auth login` to see CI checks.", systemImage: "terminal")
            } else if CIStatusStore.branch(of: session) == nil {
                unavailable("No Branch to Check", "Only sessions in their own worktree have a branch for CI to run on.", systemImage: "arrow.triangle.branch")
            } else if let status, !status.checks.isEmpty || status.pullRequest != nil {
                list(status)
            } else {
                unavailable("No Checks Yet", "Checks appear once the branch is pushed and CI starts — usually when the agent opens a pull request.", systemImage: "checklist")
            }
        }
        .task { await refresh() }
    }

    private func list(_ status: CIStatus) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let pullRequest = status.pullRequest {
                    pullRequestHeader(pullRequest, state: status.state)
                    Divider()
                }
                ForEach(sorted(status.checks)) { check in
                    checkRow(check)
                    Divider().padding(.leading, FlotillaSpacing.medium)
                }
            }
        }
        .accessibilityIdentifier("GitSidebar.Checks.List")
    }

    private func pullRequestHeader(_ pullRequest: GhPullRequest, state: CICheckState?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: pullRequest.state == .merged ? "arrow.triangle.merge" : "arrow.triangle.pull")
                    .foregroundStyle(FlotillaColors.accent)
                Text("Pull Request #\(pullRequest.number)")
                    .font(FlotillaTypography.callout.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Spacer(minLength: 0)
                Button {
                    openURL(pullRequest.url)
                } label: {
                    Image(systemName: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.textSecondary)
                .help("Open on GitHub")
            }
            HStack(spacing: 8) {
                pill(pullRequest.isDraft ? "Draft" : pullRequest.state.rawValue.capitalized)
                if let review = reviewLabel(pullRequest.reviewDecision) {
                    pill(review)
                }
                if let state {
                    Label(state.label, systemImage: state.systemImage)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(state.tint)
                }
                Spacer(minLength: 0)
                refreshButton
            }
        }
        .padding(FlotillaSpacing.medium)
    }

    private func checkRow(_ check: CICheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: check.state.systemImage)
                    .foregroundStyle(check.state.tint)
                    .symbolEffect(.pulse, isActive: check.state == .pending)
                VStack(alignment: .leading, spacing: 1) {
                    Text(check.name)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Text(detail(for: check))
                        .font(FlotillaTypography.caption3)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let url = check.url {
                    Button {
                        openURL(url)
                    } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .help("Open this check on GitHub")
                }
            }
            if check.state == .failing, check.runID != nil {
                Button {
                    onSendFailure(check)
                } label: {
                    Label("Send Failure to Agent", systemImage: "paperplane")
                        .font(FlotillaTypography.caption)
                }
                .controlSize(.small)
                .padding(.leading, 24)
                .accessibilityIdentifier("GitSidebar.Checks.SendFailure")
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
    }

    private var refreshButton: some View {
        Button {
            Task { await refresh() }
        } label: {
            Image(systemName: "arrow.clockwise")
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textTertiary)
        .disabled(isRefreshing)
        .help("Check again now")
    }

    private func pill(_ text: String) -> some View {
        Text(text)
            .font(FlotillaTypography.caption3.weight(.medium))
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(FlotillaColors.textTertiary.opacity(0.15), in: Capsule())
    }

    private func unavailable(_ title: String, _ message: String, systemImage: String) -> some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Failures first — they are why anyone opened this tab — then what is
    /// still running, then the rest.
    private func sorted(_ checks: [CICheck]) -> [CICheck] {
        let rank: [CICheckState: Int] = [.failing: 0, .pending: 1, .passing: 2, .skipped: 3]
        return checks.enumerated()
            .sorted { (rank[$0.element.state] ?? 9, $0.offset) < (rank[$1.element.state] ?? 9, $1.offset) }
            .map(\.element)
    }

    private func detail(for check: CICheck) -> String {
        var parts: [String] = []
        if let workflow = check.workflowName, workflow != check.name { parts.append(workflow) }
        if let started = check.startedAt {
            let end = check.completedAt ?? Date()
            let seconds = Int(end.timeIntervalSince(started))
            parts.append(seconds >= 60 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds)s")
        }
        parts.append(check.state.label)
        return parts.joined(separator: " · ")
    }

    private func reviewLabel(_ decision: String?) -> String? {
        switch decision {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: nil
        }
    }

    private func refresh() async {
        isRefreshing = true
        await store.ciStatusStore.refresh(sessionID: session.id)
        isRefreshing = false
    }
}

/// Shows the prompt built from a failing check's log, editable, before it goes
/// to the agent. Nothing reaches the session until the user presses Send.
struct CIFailureSendSheet: View {
    let session: Session
    let check: CICheck
    let store: AppStore
    let onDismiss: () -> Void

    @State private var prompt = ""
    @State private var isLoading = true
    @State private var isSending = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Send CI Failure to Agent")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("\(check.name) on \(session.title)")
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
                    ProgressView("Fetching the failing log…")
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
        defer { isLoading = false }
        var log = ""
        if let ghService = store.ghService, let runID = check.runID, let repo = session.worktree?.worktreePath {
            do {
                log = GhJSON.logTail(try await ghService.failedLog(runID: runID, at: repo))
            } catch {
                errorMessage = "Couldn’t fetch the log: \(error.localizedDescription)"
            }
        }
        prompt = Self.prompt(check: check, branch: CIStatusStore.branch(of: session) ?? "this branch", log: log)
    }

    static func prompt(check: CICheck, branch: String, log: String) -> String {
        var text = "The CI check \"\(check.name)\" failed on \(branch)"
        if let url = check.url { text += " (\(url.absoluteString))" }
        text += ".\n\n"
        if !log.isEmpty {
            text += "End of the failing log:\n```\n\(log)\n```\n\n"
        }
        text += "Find the cause, fix it, and push the fix."
        return text
    }

    private func send() async {
        isSending = true
        defer { isSending = false }
        do {
            try await store.deliverMessage(prompt, to: session.id)
            onDismiss()
            await store.ciStatusStore.refresh(sessionID: session.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
