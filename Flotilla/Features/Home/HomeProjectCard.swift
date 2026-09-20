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
    var onUpdateIcon: ((ProjectIcon?) -> Void)? = nil

    @State private var isHovered = false
    @State private var isConfirmingRemoval = false
    @State private var isShowingIconPicker = false

    private var tint: Color { ProjectMark.tint(for: project) }

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
            header
            metaRow
            statusRow
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
        .sheet(isPresented: $isShowingIconPicker) {
            ProjectIconPickerSheet(
                project: project,
                onSave: { newIcon in
                    onUpdateIcon?(newIcon)
                },
                onDismiss: {
                    isShowingIconPicker = false
                }
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("ProjectRow-\(project.name)")
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.medium) {
            Button {
                if onUpdateIcon != nil {
                    isShowingIconPicker = true
                } else {
                    onSelect()
                }
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    ProjectMark(project: project, size: 38)
                    if onUpdateIcon != nil {
                        Circle()
                            .fill(FlotillaColors.surface)
                            .frame(width: 14, height: 14)
                            .overlay {
                                Image(systemName: "pencil")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(FlotillaColors.textSecondary)
                            }
                            .offset(x: 3, y: 3)
                            .opacity(isHovered ? 1.0 : 0.0)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(onUpdateIcon != nil ? "Change project icon" : "")

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
            moreMenu
        }
    }

    private var abbreviatedPath: String {
        (project.rootPath.path as NSString).abbreviatingWithTildeInPath
    }

    // MARK: - Meta Row

    /// Branch and worktrees on the left, sessions on the right. Only the
    /// branch name may shorten; everything else keeps its full width.
    private var metaRow: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            if let branch = repoState?.branch {
                HStack(spacing: 5) {
                    GitBranchIcon(size: 11)
                    Text(BranchNaming.displayName(for: branch))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(FlotillaColors.textSecondary)
                .layoutPriority(-1)
                .help(branch)
            }
            if let worktrees = repoState?.worktreeCount, worktrees > 0 {
                Label("\(worktrees) worktree\(worktrees == 1 ? "" : "s")", systemImage: "square.stack.3d.down.right")
                    .font(FlotillaTypography.caption.monospacedDigit())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .fixedSize()
            }
            Spacer(minLength: FlotillaSpacing.small)
            sessionHint
        }
        .frame(height: 18)
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
            .fixedSize()
        }
    }

    private func hintDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
        }
    }

    // MARK: - Status Row

    /// The loose ends, as left-aligned pills — or one "Clean" pill when there
    /// are none. Wraps rather than squeezing when the card is narrow.
    @ViewBuilder
    private var statusRow: some View {
        if let state = repoState {
            let pills = statusPills(state)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: FlotillaSpacing.small) { pills }
                VStack(alignment: .leading, spacing: FlotillaSpacing.small) { pills }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: FlotillaSpacing.small) {
                ProgressView().controlSize(.mini)
                Text("Reading repository…")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .frame(height: 26)
        }
    }

    @ViewBuilder
    private func statusPills(_ state: HomeRepoState) -> some View {
        if state.isSettled {
            pill("checkmark", "Clean", tint: FlotillaColors.success)
        }
        if state.hasUncommittedWork {
            pill("pencil", "\(state.changedFileCount) uncommitted", tint: FlotillaColors.warning) {
                // Line counts only when there are lines — an untracked folder
                // or binary file is uncommitted work with no "+0 −0" to show.
                if state.diffStat.additions > 0 {
                    Text("+\(state.diffStat.additions.formatted(.number.notation(.compactName)))")
                        .foregroundStyle(FlotillaColors.diffAdded)
                }
                if state.diffStat.deletions > 0 {
                    Text("−\(state.diffStat.deletions.formatted(.number.notation(.compactName)))")
                        .foregroundStyle(FlotillaColors.diffRemoved)
                }
            }
        }
        if state.unpushedCount > 0 {
            pill("arrow.up", "\(state.unpushedCount) unpushed", tint: FlotillaColors.statusReady)
        }
    }

    private func pill<Extra: View>(
        _ systemImage: String,
        _ title: String,
        tint: Color,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
            Text(title)
            extra()
        }
        .font(FlotillaTypography.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(tint)
        .padding(.horizontal, FlotillaSpacing.small + 2)
        .frame(height: 26)
        .background(tint.opacity(0.13), in: Capsule())
        .fixedSize()
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
        if onUpdateIcon != nil {
            Button("Change Icon…") {
                isShowingIconPicker = true
            }
            if project.icon != nil {
                Button("Remove Icon") {
                    onUpdateIcon?(nil)
                }
            }
            Divider()
        }
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
