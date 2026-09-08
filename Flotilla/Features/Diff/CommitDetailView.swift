import SwiftUI
import AppKit
import GitKit
import SessionKit
import DesignSystem

/// The right-hand pane of the history view: everything about one commit —
/// identity, decoration, what it touched, and the patch itself.
struct CommitDetailView: View {
    @Bindable var viewModel: ProjectGraphViewModel
    @Environment(\.workspaceNavigator) private var navigator

    @State private var isMessageExpanded = false
    @State private var isGoalExpanded = false
    @State private var isReleaseNoteCopied = false

    private var commit: GitCommit? {
        guard let sha = viewModel.selectedSHA else { return nil }
        if let detail = viewModel.detail, detail.commit.sha == sha { return detail.commit }
        return viewModel.commits.first { $0.sha == sha }
    }

    var body: some View {
        Group {
            if let commit {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        header(commit)
                        Divider()
                        identity(commit)
                        Divider()
                        agentActionsSection(commit)
                        Divider()
                        statSummary(commit)
                        Divider()
                        fileSection(commit)
                    }
                }
                .scrollContentBackground(.hidden)
            } else if viewModel.isLoadingDetail {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Commit Selected",
                    systemImage: "circle.dashed",
                    description: Text("Pick a commit from the timeline to inspect it.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(FlotillaColors.canvas)
        .accessibilityIdentifier("ProjectHistory.Detail")
        .onChange(of: commit?.sha) { _, _ in
            isMessageExpanded = false
            isGoalExpanded = false
        }
    }

    // MARK: - Header

    private var hasLongBody: Bool {
        guard let commit else { return false }
        let lines = commit.body.components(separatedBy: .newlines)
        return lines.count > 3 || commit.body.count > 200
    }

    private var hasLongSubject: Bool {
        guard let commit else { return false }
        return commit.subject.count > 120
    }

    private func header(_ commit: GitCommit) -> some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            Text(commit.subject)
                .font(FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(hasLongSubject && !isMessageExpanded ? 2 : nil)
                .fixedSize(horizontal: false, vertical: true)

            if !commit.body.isEmpty {
                Text(commit.body)
                    .font(FlotillaTypography.callout)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(hasLongBody && !isMessageExpanded ? 3 : nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if hasLongBody || hasLongSubject {
                Button {
                    withAnimation(FlotillaMotion.fast.curve) {
                        isMessageExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isMessageExpanded ? "Show less" : "Show more")
                            .font(FlotillaTypography.caption2.weight(.medium))
                        Image(systemName: isMessageExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(FlotillaColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CommitDetail.ToggleMessageButton")
            }

            HStack(spacing: FlotillaSpacing.small) {
                Text(commit.shortSHA)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                    .textSelection(.enabled)

                Button {
                    copy(commit.sha)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: FlotillaIconSize.small))
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.textTertiary)
                .help("Copy the full SHA")
                .accessibilityIdentifier("ProjectHistory.CopySHAButton")

                if let url = viewModel.webURL(for: commit) {
                    Link(destination: url) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: FlotillaIconSize.small))
                            Text("Open on the Web")
                                .font(FlotillaTypography.caption2)
                        }
                    }
                    .accessibilityIdentifier("ProjectHistory.WebLink")
                }

                Spacer()

                if viewModel.isUnpushed(commit) {
                    CommitRefChip(text: "not pushed", systemImage: "arrow.up.circle", tint: FlotillaColors.accent)
                }
            }
        }
        .padding(FlotillaSpacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Identity

    private func identity(_ commit: GitCommit) -> some View {
        let attribution = viewModel.attribution(for: commit)
        return VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                ProjectMark(
                    title: commit.authorName,
                    tint: ProjectMark.tint(forKey: commit.authorEmail),
                    size: 28
                )
                VStack(alignment: .leading, spacing: 1) {
                    Text(commit.authorName)
                        .font(FlotillaTypography.callout.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text(commit.authorEmail)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .textSelection(.enabled)
                    Text("authored \(commit.authorDate.formatted(date: .abbreviated, time: .shortened))")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textSecondary)
                    if let attribution = viewModel.attribution(for: commit) {
                        HStack(spacing: 4) {
                            ProviderLogo(agent: attribution.agent)
                                .frame(width: 12, height: 12)
                            Text(attribution.sessionTitle.map { "\(attribution.agent.displayName) · \($0)" }
                                 ?? attribution.agent.displayName)
                                .font(FlotillaTypography.caption2)
                                .foregroundStyle(FlotillaColors.accent)
                                .lineLimit(1)
                            Text(attribution.source.explanation)
                                .font(FlotillaTypography.caption2)
                                .foregroundStyle(FlotillaColors.textTertiary)
                        }
                        .padding(.top, 1)
                        .accessibilityIdentifier("ProjectHistory.Attribution")
                    }
                    if commit.hasDistinctCommitter {
                        Text("committed by \(commit.committerName) · \(commit.committerDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(FlotillaTypography.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                }
                Spacer()
            }

            if let attribution = viewModel.attribution(for: commit),
               let goal = attribution.sessionGoal,
               !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                agentGoalView(goal: goal, agent: attribution.agent)
            }

            if !commit.refs.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: FlotillaSpacing.xSmall) {
                        ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in
                            CommitRefChip(ref: ref)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !commit.parents.isEmpty {
                HStack(spacing: FlotillaSpacing.xSmall) {
                    Text(commit.parents.count > 1 ? "parents" : "parent")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                    ForEach(commit.parents, id: \.self) { parent in
                        parentButton(parent)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Agent Actions

    private func agentActionsSection(_ commit: GitCommit) -> some View {
        Grid(horizontalSpacing: FlotillaSpacing.small) {
            GridRow {
                explainButton(commit)
                changelogButton(commit)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small + 2)
        .frame(maxWidth: .infinity)
    }

    private func explainButton(_ commit: GitCommit) -> some View {
        Button {
            explainWithAgent(commit)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(FlotillaColors.accent)

                Text("Explain with Agent")
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)

                Spacer(minLength: 4)

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(FlotillaColors.accent)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(FlotillaColors.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.control)
                    .strokeBorder(FlotillaColors.accent.opacity(0.22), lineWidth: 0.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .help("Open a new agent session to explain this commit")
        .accessibilityIdentifier("ProjectHistory.ExplainButton")
    }

    private func changelogButton(_ commit: GitCommit) -> some View {
        Menu {
            Button {
                copyReleaseNote(commit)
            } label: {
                Label("Copy Markdown Snippet", systemImage: "doc.on.doc")
            }
            Button {
                generateChangelogWithAgent(commit)
            } label: {
                Label("Draft Notes with Agent…", systemImage: "sparkles")
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isReleaseNoteCopied ? "checkmark" : "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isReleaseNoteCopied ? FlotillaColors.statusWorking : FlotillaColors.statusReady)

                Text(isReleaseNoteCopied ? "Copied to Clipboard!" : "Generate Changelog")
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(isReleaseNoteCopied ? FlotillaColors.statusWorking : FlotillaColors.textPrimary)

                Spacer(minLength: 4)

                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle((isReleaseNoteCopied ? FlotillaColors.statusWorking : FlotillaColors.statusReady).opacity(0.8))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(
                (isReleaseNoteCopied ? FlotillaColors.statusWorking : FlotillaColors.statusReady).opacity(0.08),
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.control)
                    .strokeBorder(
                        (isReleaseNoteCopied ? FlotillaColors.statusWorking : FlotillaColors.statusReady).opacity(0.22),
                        lineWidth: 0.5
                    )
            )
            .contentShape(.rect)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)
        .help("Copy markdown release notes or draft changelog with an agent")
        .accessibilityIdentifier("ProjectHistory.ReleaseNoteButton")
    }

    private func parentButton(_ parent: String) -> some View {
        let isLoaded = viewModel.commits.contains { $0.sha == parent }
        return Button {
            if isLoaded { viewModel.selectedSHA = parent }
        } label: {
            Text(String(parent.prefix(7)))
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(FlotillaColors.surfaceElevated, in: Capsule())
                .foregroundStyle(isLoaded ? FlotillaColors.textSecondary : FlotillaColors.textTertiary)
        }
        .buttonStyle(.plain)
        .disabled(!isLoaded)
        .help(isLoaded ? "Jump to this parent" : "This parent isn't in the loaded history yet")
    }

    // MARK: - Stat summary

    private func statSummary(_ commit: GitCommit) -> some View {
        let stat = viewModel.detail?.stat ?? commit.stat
        let fileCount = viewModel.detail?.files.count ?? commit.changedFileCount
        return VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
            HStack(spacing: FlotillaSpacing.small) {
                Text("\(fileCount) file\(fileCount == 1 ? "" : "s") changed")
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                Spacer()
                if !stat.isEmpty {
                    DiffStatBadge(stat: stat)
                }
            }
            if !stat.isEmpty {
                proportionBar(stat)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
    }

    private func proportionBar(_ stat: GitDiffStat) -> some View {
        GeometryReader { geometry in
            let total = max(1, stat.additions + stat.deletions)
            let addedWidth = geometry.size.width * CGFloat(stat.additions) / CGFloat(total)
            HStack(spacing: 1) {
                Capsule().fill(FlotillaColors.diffAdded).frame(width: max(0, addedWidth - 1))
                Capsule().fill(FlotillaColors.diffRemoved)
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }

    // MARK: - Files

    @ViewBuilder
    private func fileSection(_ commit: GitCommit) -> some View {
        if viewModel.isLoadingDetail {
            HStack(spacing: FlotillaSpacing.small) {
                ProgressView().controlSize(.small)
                Text("Loading changes…")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .padding(FlotillaSpacing.large)
        } else if let detail = viewModel.detail, !detail.files.isEmpty {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(detail.files) { file in
                    CommitFileRow(file: file, repoPath: viewModel.repoPath)
                    Divider().opacity(0.5)
                }
            }
        } else if commit.isMerge {
            hint("This is a merge commit. Its changes belong to the commits it brings in.")
        } else {
            hint("This commit touched no files.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(FlotillaTypography.callout)
            .foregroundStyle(FlotillaColors.textTertiary)
            .padding(FlotillaSpacing.large)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hasLongGoal(_ goal: String) -> Bool {
        let lines = goal.components(separatedBy: .newlines)
        return lines.count > 3 || goal.count > 200
    }

    private func agentGoalView(goal: String, agent: AgentKind) -> some View {
        let isLong = hasLongGoal(goal)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "quote.opening")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(FlotillaColors.accent)
                Text("Initial Goal / Prompt")
                    .font(FlotillaTypography.caption2.weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
            }

            Text(goal)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textPrimary)
                .textSelection(.enabled)
                .lineLimit(isLong && !isGoalExpanded ? 3 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, FlotillaSpacing.small)
                .padding(.vertical, 6)
                .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control))
                .overlay(
                    RoundedRectangle(cornerRadius: FlotillaRadius.control)
                        .strokeBorder(FlotillaColors.separator, lineWidth: 0.5)
                )

            if isLong {
                Button {
                    withAnimation(FlotillaMotion.fast.curve) {
                        isGoalExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isGoalExpanded ? "Show less" : "Show more")
                            .font(FlotillaTypography.caption2.weight(.medium))
                        Image(systemName: isGoalExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(FlotillaColors.accent)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("CommitDetail.ToggleGoalButton")
            }
        }
        .padding(.top, 2)
        .accessibilityIdentifier("ProjectHistory.AgentGoal")
    }

    private func explainWithAgent(_ commit: GitCommit) {
        let stat = viewModel.detail?.stat ?? commit.stat
        var prompt = "Please explain commit \(commit.shortSHA) (\"\(commit.subject)\") in repository \(viewModel.repoPath.lastPathComponent)."
        if !commit.body.isEmpty {
            prompt += "\n\nCommit message:\n\(commit.body)"
        }
        if !stat.isEmpty {
            prompt += "\n\nChanges: +\(stat.additions) -\(stat.deletions)"
        }
        prompt += "\n\nBreak down why these changes were made, highlight key logic modifications, and point out any potential edge cases or side effects."

        let projectID = viewModel.sessions.first?.projectID
        navigator.presentedSheet = .createSession(initialGoal: prompt, projectID: projectID)
    }

    private func generateChangelogWithAgent(_ commit: GitCommit) {
        let stat = viewModel.detail?.stat ?? commit.stat
        var prompt = "Please draft a concise, user-facing changelog entry / release note for commit \(commit.shortSHA) (\"\(commit.subject)\") in repository \(viewModel.repoPath.lastPathComponent)."
        if !commit.body.isEmpty {
            prompt += "\n\nCommit details:\n\(commit.body)"
        }
        if !stat.isEmpty {
            prompt += "\n\nChanges: +\(stat.additions) -\(stat.deletions)"
        }
        prompt += "\n\nFormat the release note with a bullet summary suitable for a product changelog under standard sections (e.g. Added, Fixed, Changed)."

        let projectID = viewModel.sessions.first?.projectID
        navigator.presentedSheet = .createSession(initialGoal: prompt, projectID: projectID)
    }

    private func copyReleaseNote(_ commit: GitCommit) {
        var note = "- **\(commit.subject)** (`\(commit.shortSHA)`"
        if let webURL = viewModel.webURL(for: commit) {
            note = "- **\(commit.subject)** ([\(commit.shortSHA)](\(webURL.absoluteString)))"
        }
        note += " by @\(commit.authorName))"

        let cleanBody = commit.body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isTrailerLine($0) }
            .joined(separator: " ")

        if !cleanBody.isEmpty {
            note += "\n  - \(cleanBody)"
        } else {
            let stat = viewModel.detail?.stat ?? commit.stat
            if !stat.isEmpty {
                note += "\n  - Changes: +\(stat.additions) -\(stat.deletions)"
            }
        }

        copy(note)
        withAnimation(FlotillaMotion.fast.curve) {
            isReleaseNoteCopied = true
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation(FlotillaMotion.fast.curve) {
                isReleaseNoteCopied = false
            }
        }
    }

    private func isTrailerLine(_ line: String) -> Bool {
        guard let colon = line.firstIndex(of: ":") else { return false }
        let key = String(line[line.startIndex..<colon]).lowercased()
        return key.hasPrefix("flotilla-") || key == "co-authored-by" || key == "signed-off-by"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - File row

struct CommitFileRow: View {
    let file: GitCommitFileChange
    let repoPath: URL

    @State private var isExpanded = false
    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                if file.hunks.isEmpty {
                    Text(emptyHunkExplanation)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .padding(.horizontal, FlotillaSpacing.large)
                        .padding(.bottom, FlotillaSpacing.small)
                } else {
                    ForEach(Array(file.hunks.enumerated()), id: \.offset) { _, hunk in
                        CommitHunkView(hunk: hunk)
                    }
                }
            }
        }
        .background(isHovering && !isExpanded ? FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) : .clear)
        .accessibilityIdentifier("ProjectHistory.File-\(file.path)")
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: 10)

            FileChangeKindBadge(kind: file.kind, size: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let previousPath = file.previousPath {
                    Text("was \(previousPath)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: FlotillaSpacing.small)

            if !file.stat.isEmpty {
                DiffStatBadge(stat: file.stat)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.small)
        .contentShape(.rect)
        .onTapGesture { withAnimation(FlotillaMotion.fast.curve) { isExpanded.toggle() } }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(file.path, forType: .string)
            }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repoPath.appendingPathComponent(file.path)])
            }
            .disabled(file.kind == .deleted)
        }
    }

    private var emptyHunkExplanation: String {
        switch file.kind {
        case .renamed, .copied: return "No content changes — the file only moved."
        default: return "No textual diff (this may be a binary file)."
        }
    }

}

// MARK: - Hunk

struct CommitHunkView: View {
    let hunk: FileDiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(hunk.header)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FlotillaColors.surfaceElevated)

            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(foreground(for: line))
                            .padding(.horizontal, FlotillaSpacing.large)
                            .padding(.vertical, 0.5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func background(for line: String) -> Color {
        if line.hasPrefix("+") { return FlotillaColors.diffAddedSurface }
        if line.hasPrefix("-") { return FlotillaColors.diffRemovedSurface }
        return .clear
    }

    private func foreground(for line: String) -> Color {
        if line.hasPrefix("+") { return FlotillaColors.diffAdded }
        if line.hasPrefix("-") { return FlotillaColors.diffRemoved }
        return FlotillaColors.textSecondary
    }
}
