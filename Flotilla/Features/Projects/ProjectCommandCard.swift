import SwiftUI
import AppKit
import SessionKit
import SettingsKit
import GitKit
import DesignSystem

/// High-density command card for a project in the Projects workspace.
/// Displays live Git branch, diff stats, running agent telemetry, and
/// 1-click action shortcuts (Quick Launch, Terminal, Editor, Finder).
struct ProjectCommandCard: View {
    let project: Project
    let sessions: [Session]
    let gitService: any GitServiceProtocol
    let diffStatStore: DiffStatStore
    /// This project's own commit attribution mode; `nil` follows the default.
    let commitAttribution: CommitAttributionMode?
    let defaultCommitAttribution: CommitAttributionMode
    let onSetCommitAttribution: (CommitAttributionMode?) -> Void
    let onSelect: () -> Void
    let onQuickLaunch: () -> Void
    let onRemove: () -> Void

    @State private var currentBranch: String?
    @State private var projectDiffStat: GitDiffStat?
    @State private var worktreeCount: Int = 0
    @State private var isHovered = false
    @State private var isConfirmingRemoval = false

    private var activeSessions: [Session] {
        sessions.filter { $0.status == .working || $0.status == .waitingForInput }
    }

    private var attentionSessions: [Session] {
        sessions.filter { $0.status == .waitingForInput || $0.status == .crashed }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            headerRow
            pathAndStatsRow
            sessionTelemetrySection
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card)
                .strokeBorder(
                    !attentionSessions.isEmpty
                        ? FlotillaColors.statusWaitingForInput.opacity(0.6)
                        : (isHovered ? FlotillaColors.accent.opacity(0.4) : FlotillaColors.separator),
                    lineWidth: FlotillaBorderWidth.thin
                )
        }
        .contentShape(.rect)
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .task(id: project.id) {
            await loadGitTelemetry()
        }
        .accessibilityIdentifier("ProjectRow-\(project.name)")
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.small) {
            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project))

            Text(project.name)
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: FlotillaSpacing.small)

            if let branch = currentBranch {
                HStack(spacing: 4) {
                    GitBranchIcon(size: FlotillaIconSize.small)
                    Text(BranchNaming.displayName(for: branch))
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, FlotillaSpacing.small)
                .padding(.vertical, FlotillaSpacing.xSmall)
                .background(FlotillaColors.surfaceElevated, in: Capsule())
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(maxWidth: 150, alignment: .trailing)
            }

            if let stat = projectDiffStat, !stat.isEmpty {
                DiffStatBadge(stat: stat)
            }

            moreMenu
        }
    }

    // MARK: - Path & Stats

    private var pathAndStatsRow: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            MarqueeText(
                project.rootPath.path,
                font: .system(size: 11, design: .monospaced),
                color: FlotillaColors.textTertiary,
                isHovered: isHovered,
                truncationMode: .middle
            )

            Spacer(minLength: FlotillaSpacing.small)

            HStack(spacing: FlotillaSpacing.small) {
                Label("\(sessions.count)", systemImage: "terminal")
                    .help("\(sessions.count) total sessions")
                    .fixedSize(horizontal: true, vertical: false)

                if worktreeCount > 0 {
                    GitBranchLabel("\(worktreeCount)", size: 11)
                        .help("\(worktreeCount) active worktrees")
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .font(FlotillaTypography.caption)
            .foregroundStyle(FlotillaColors.textSecondary)
        }
    }

    // MARK: - Session Telemetry

    @ViewBuilder
    private var sessionTelemetrySection: some View {
        if sessions.isEmpty {
            Text("No agent sessions active")
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.vertical, FlotillaSpacing.xSmall)
        } else if !activeSessions.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(activeSessions.prefix(2)) { session in
                    HStack(spacing: FlotillaSpacing.small) {
                        StatusBadge(session.status, waitingReason: session.waitingReason, size: .micro, showLabel: false)

                        Text(session.agent.displayName)
                            .font(FlotillaTypography.caption.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .fixedSize(horizontal: true, vertical: false)

                        Text(session.title)
                            .font(FlotillaTypography.caption)
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if session.status == .waitingForInput {
                            Text("Needs Input")
                                .font(FlotillaTypography.caption2.weight(.bold))
                                .foregroundStyle(FlotillaColors.statusWaitingForInput)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(FlotillaColors.statusWaitingForInput.opacity(0.16), in: Capsule())
                                .fixedSize()
                        }
                    }
                }
            }
        } else {
            HStack(spacing: FlotillaSpacing.small) {
                Circle()
                    .fill(FlotillaColors.textTertiary)
                    .frame(width: 6, height: 6)
                Text("\(sessions.count) idle or completed session\(sessions.count == 1 ? "" : "s")")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, FlotillaSpacing.xSmall)
        }
    }


    // MARK: - More Menu

    private var moreMenu: some View {
        Menu {
            Button("Open Project View") { onSelect() }
            Button("New Agent Session…") { onQuickLaunch() }
            Divider()
            Button("Open in Terminal") { openTerminal() }
            Button("Open in VS Code") { openInVSCode() }
            Button("Open in Cursor") { openInCursor() }
            Button("Reveal in Finder") { revealInFinder() }
            Divider()
            Button("Copy Project Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(project.rootPath.path, forType: .string)
            }
            if let branch = currentBranch {
                Button("Copy Branch Name") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(branch, forType: .string)
                }
            }
            Divider()
            Picker("Commit Attribution", selection: Binding(
                get: { commitAttribution },
                set: { onSetCommitAttribution($0) }
            )) {
                Text("Use Default (\(defaultCommitAttribution.displayName))")
                    .tag(CommitAttributionMode?.none)
                ForEach(CommitAttributionMode.allCases) { mode in
                    Text(mode.displayName).tag(CommitAttributionMode?.some(mode))
                }
            }
            .pickerStyle(.menu)
            Divider()
            Button("Remove Project from Library", role: .destructive) {
                isConfirmingRemoval = true
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: FlotillaIconSize.small))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: 24, height: 24)
                .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .confirmationDialog(
            "Remove \"\(project.name)\" from Flotilla?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Project", role: .destructive, action: onRemove)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only removes it from Flotilla's library — the folder, its Git history, and any worktrees are untouched. Its sessions stay in Flotilla as standalone sessions.")
        }
    }

    // MARK: - Actions

    private func loadGitTelemetry() async {
        if let branch = try? await gitService.currentBranch(at: project.rootPath) {
            currentBranch = branch
        }
        if let stat = try? await gitService.diffStat(at: project.rootPath) {
            projectDiffStat = stat
        }
        if let worktrees = try? await gitService.listWorktrees(at: project.rootPath) {
            worktreeCount = worktrees.filter { !$0.isMainWorktree }.count
        }
    }

    private func openTerminal() {
        let path = project.rootPath.path
        let script = "tell application \"Terminal\" to do script \"cd \(path.replacingOccurrences(of: "\"", with: "\\\""))\""
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
            if let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                NSWorkspace.shared.openApplication(at: terminalURL, configuration: NSWorkspace.OpenConfiguration())
            }
        }
    }

    private func openInEditor() {
        if let vscodeURL = URL(string: "vscode://file\(project.rootPath.path)") {
            if NSWorkspace.shared.open(vscodeURL) { return }
        }
        if let cursorURL = URL(string: "cursor://file\(project.rootPath.path)") {
            if NSWorkspace.shared.open(cursorURL) { return }
        }
        NSWorkspace.shared.open(project.rootPath)
    }

    private func openInVSCode() {
        if let url = URL(string: "vscode://file\(project.rootPath.path)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openInCursor() {
        if let url = URL(string: "cursor://file\(project.rootPath.path)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([project.rootPath])
    }
}
