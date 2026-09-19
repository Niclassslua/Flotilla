import SwiftUI
import AppKit
import SessionKit
import SettingsKit
import GitKit
import DesignSystem

/// A project on Home: large glass card that answers "does this one have loose
/// ends?" before you open it — branch, uncommitted work, unpushed commits,
/// open worktrees — with a one-line hint of its sessions. The sidebar already
/// lists the sessions themselves, so the card never does.
struct HomeProjectCard: View {
    let project: Project
    let sessions: [Session]
    /// `nil` while the repository is still being read.
    let repoState: HomeRepoState?
    /// This project's own commit attribution mode; `nil` follows the default.
    let commitAttribution: CommitAttributionMode?
    let defaultCommitAttribution: CommitAttributionMode
    let onSetCommitAttribution: (CommitAttributionMode?) -> Void
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovered = false
    @State private var isConfirmingRemoval = false

    private var tint: Color { ProjectMark.tint(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
            header
            repoStateRow
        }
        .padding(FlotillaSpacing.large + 2)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous)
                .strokeBorder(
                    isHovered ? tint.opacity(0.55) : FlotillaColors.textPrimary.opacity(0.08),
                    lineWidth: FlotillaBorderWidth.thin
                )
        }
        .flotillaShadow(isHovered ? .level3 : .level1)
        .scaleEffect(isHovered ? 1.012 : 1)
        .animation(.snappy(duration: 0.2), value: isHovered)
        .contentShape(RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contextMenu { menuItems }
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
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("ProjectRow-\(project.name)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
            ProjectMark(title: project.name, tint: tint, size: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                MarqueeText(
                    abbreviatedPath,
                    font: .system(size: 11, design: .monospaced),
                    color: FlotillaColors.textTertiary,
                    isHovered: isHovered,
                    truncationMode: .middle
                )
            }

            Spacer(minLength: FlotillaSpacing.small)

            sessionHint
            moreMenu
        }
    }

    private var abbreviatedPath: String {
        (project.rootPath.path as NSString).abbreviatingWithTildeInPath
    }

    /// "1 needs you · 2 working" — counts only, most urgent first. Nothing at
    /// all when no agent is running here.
    @ViewBuilder
    private var sessionHint: some View {
        let waiting = sessions.filter { $0.status == .waitingForInput }.count
        let working = sessions.filter { $0.status == .working }.count
        if waiting + working > 0 {
            HStack(spacing: FlotillaSpacing.small) {
                if waiting > 0 {
                    hintDot(FlotillaColors.statusWaitingForInput, "\(waiting) needs you")
                }
                if working > 0 {
                    hintDot(FlotillaColors.statusWorking, "\(working) working")
                }
            }
            .padding(.horizontal, FlotillaSpacing.small + 2)
            .padding(.vertical, 4)
            .background(FlotillaColors.textPrimary.opacity(0.06), in: Capsule())
            .padding(.top, 4)
        }
    }

    private func hintDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(FlotillaTypography.caption2.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .fixedSize()
        }
    }

    // MARK: - Repository State

    @ViewBuilder
    private var repoStateRow: some View {
        if let state = repoState {
            HStack(spacing: FlotillaSpacing.small) {
                if let branch = state.branch {
                    chip {
                        GitBranchIcon(size: 11)
                        Text(BranchNaming.displayName(for: branch))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: 170, alignment: .leading)
                }

                if state.isSettled {
                    chip(tint: FlotillaColors.success) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Clean")
                    }
                } else {
                    if state.hasUncommittedWork {
                        chip(tint: FlotillaColors.warning) {
                            Image(systemName: "pencil")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(state.changedFileCount) uncommitted")
                            if !state.diffStat.isEmpty {
                                Text("+\(state.diffStat.additions)").foregroundStyle(FlotillaColors.diffAdded)
                                Text("−\(state.diffStat.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                            }
                        }
                    }
                    if state.unpushedCount > 0 {
                        chip(tint: FlotillaColors.statusReady) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                            Text("\(state.unpushedCount) unpushed")
                        }
                    }
                }

                if state.worktreeCount > 0 {
                    chip {
                        Image(systemName: "square.stack.3d.down.right")
                            .font(.system(size: 9, weight: .semibold))
                        Text("\(state.worktreeCount) worktree\(state.worktreeCount == 1 ? "" : "s")")
                    }
                }
                Spacer(minLength: 0)
            }
            .font(FlotillaTypography.caption.monospacedDigit())
        } else {
            HStack(spacing: FlotillaSpacing.small) {
                ProgressView().controlSize(.mini)
                Text("Reading repository…")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .frame(height: 24)
        }
    }

    /// A capsule of repository state. Tinted chips are the loose ends; the
    /// untinted ones are context.
    private func chip<Content: View>(tint: Color? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 5) { content() }
            .foregroundStyle(tint ?? FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small + 1)
            .frame(height: 24)
            .background((tint ?? FlotillaColors.textPrimary).opacity(tint == nil ? 0.06 : 0.13), in: Capsule())
            .fixedSize(horizontal: tint != nil, vertical: false)
    }

    // MARK: - Menu

    private var moreMenu: some View {
        Menu {
            menuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: FlotillaIconSize.small, weight: .semibold))
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(isHovered ? 1 : 0.55)
        .help("More actions")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open Project") { onSelect() }
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
        if let branch = repoState?.branch {
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
    }

    // MARK: - Actions

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
