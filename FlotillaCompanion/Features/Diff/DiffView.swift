import SwiftUI
import DesignSystem
import CompanionKit

/// Shows a value fetched from the Mac: a spinner, an error with Retry, or the
/// content.
struct RemoteContent<Value: Sendable, Content: View>: View {
    let value: Remote<Value>
    let retry: () async -> Void
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        switch value {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }
            }
        case .loaded(let loaded):
            content(loaded)
        }
    }
}

/// All files in one scroll with collapsible headers. Shows a session's working
/// diff, or a single commit's.
struct DiffView: View {
    let sessionID: CompanionSession.ID
    let commitHash: String?
    let focusPath: String?

    @Environment(CompanionStore.self) private var store
    @State private var collapsed: Set<String> = []
    @State private var scrollTarget: String?

    var body: some View {
        let commit = commitHash.flatMap { hash in store.commits(for: sessionID).value?.first { $0.hash == hash } }
        let remote = store.diff(for: sessionID, commitHash: commitHash)
        let files = remote.value ?? []

        RemoteContent(value: remote, retry: load) { files in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12, pinnedViews: [.sectionHeaders]) {
                    if let commit {
                        CommitHeader(commit: commit)
                    }
                    if files.count > 1 {
                        ChangedFilesOverview(files: files) { file in
                            collapsed.remove(file.path)
                            withAnimation(.snappy) { scrollTarget = file.path }
                        }
                    }
                    ForEach(files) { file in
                        Section {
                            if !collapsed.contains(file.path) {
                                FileDiffBody(file: file)
                            }
                        } header: {
                            FileDiffHeader(
                                sessionID: sessionID,
                                file: file,
                                isCollapsed: collapsed.contains(file.path)
                            ) {
                                withAnimation(.snappy) {
                                    if collapsed.contains(file.path) { collapsed.remove(file.path) } else { collapsed.insert(file.path) }
                                }
                            }
                        }
                        .id(file.path)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrollTarget, anchor: .top)
            .overlay {
                if files.isEmpty {
                    ContentUnavailableView("No Changes", systemImage: "doc.text", description: Text("This session hasn't changed any files."))
                }
            }
        }
        .background(FlotillaColors.canvas)
        .refreshable { await load() }
        .navigationTitle(commit.map { $0.shortHash } ?? (commitHash.map { String($0.prefix(7)) } ?? "Changes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if files.count > 1 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("Jump to File", systemImage: "list.bullet") {
                        ForEach(files) { file in
                            Button {
                                collapsed.remove(file.path)
                                withAnimation { scrollTarget = file.path }
                            } label: {
                                Text(file.fileName)
                                Text("+\(file.additions) −\(file.deletions)")
                            }
                        }
                    }
                }
            }
        }
        .task {
            if commitHash == nil { store.acknowledgeReview(sessionID) }
            await load()
            if let focusPath {
                collapsed.remove(focusPath)
                scrollTarget = focusPath
            }
        }
    }

    private func load() async {
        await store.loadDiff(for: sessionID, commitHash: commitHash)
    }
}

private struct CommitHeader: View {
    let commit: CommitSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(commit.subject)
                .font(.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
            Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.shortHash)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

/// A scannable list of every changed file — type, path, and line counts —
/// above the detailed per-file sections. Tapping a row jumps to that
/// file's existing section instead of opening anything new.
private struct ChangedFilesOverview: View {
    let files: [FileDiff]
    let onSelect: (FileDiff) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(files) { file in
                Button { onSelect(file) } label: {
                    HStack(spacing: 8) {
                        changeMarker(for: file.change)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.fileName)
                                .font(.subheadline)
                                .foregroundStyle(FlotillaColors.textPrimary)
                                .lineLimit(1)
                            Text(file.path)
                                .font(.caption2)
                                .foregroundStyle(FlotillaColors.textTertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer(minLength: 8)
                        Text("+\(file.additions)").foregroundStyle(FlotillaColors.diffAdded)
                        Text("−\(file.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                    }
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("DiffView.Overview.Row")
                if file.id != files.last?.id {
                    Divider().padding(.leading, 34)
                }
            }
        }
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .padding(.horizontal, 16)
        .accessibilityIdentifier("DiffView.Overview")
    }

    @ViewBuilder
    private func changeMarker(for change: FileDiff.Change) -> some View {
        Group {
            switch change {
            case .added: Text("A").foregroundStyle(FlotillaColors.diffAdded)
            case .deleted: Text("D").foregroundStyle(FlotillaColors.diffRemoved)
            case .renamed: Text("R").foregroundStyle(FlotillaColors.textSecondary)
            case .modified: Text("M").foregroundStyle(FlotillaColors.textSecondary)
            }
        }
        .font(.caption2.weight(.bold).monospaced())
        .frame(width: 16)
    }
}

private struct FileDiffHeader: View {
    let sessionID: CompanionSession.ID
    let file: FileDiff
    let isCollapsed: Bool
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .foregroundStyle(FlotillaColors.textTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.fileName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textPrimary)
                        Text(file.path)
                            .font(.caption2)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 4)
                    changeBadge
                    Text("+\(file.additions)").foregroundStyle(FlotillaColors.diffAdded)
                    Text("−\(file.deletions)").foregroundStyle(FlotillaColors.diffRemoved)
                }
                .font(.caption.monospacedDigit())
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if file.change != .deleted {
                NavigationLink(value: Route.file(sessionID, path: file.path)) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("View File")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var changeBadge: some View {
        switch file.change {
        case .added: Text("New").foregroundStyle(FlotillaColors.diffAdded)
        case .deleted: Text("Deleted").foregroundStyle(FlotillaColors.diffRemoved)
        case .renamed: Text("Renamed").foregroundStyle(FlotillaColors.textSecondary)
        case .modified: EmptyView()
        }
    }
}

/// Soft-wrapped lines with `+` / `−` tints only — no syntax highlighting yet.
private struct FileDiffBody: View {
    let file: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(file.hunks.indices, id: \.self) { hunkIndex in
                let hunk = file.hunks[hunkIndex]
                Text(hunk.header)
                    .font(.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                    .background(FlotillaColors.surface)
                ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                    let line = hunk.lines[lineIndex]
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(line.marker)
                            .foregroundStyle(markerColor(line.kind))
                            .frame(width: 10)
                        Text(line.text.isEmpty ? " " : line.text)
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 1)
                    .background(background(line.kind))
                }
            }
        }
    }

    private func markerColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: FlotillaColors.diffAdded
        case .removed: FlotillaColors.diffRemoved
        case .context: FlotillaColors.textTertiary
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: FlotillaColors.diffAddedSurface
        case .removed: FlotillaColors.diffRemovedSurface
        case .context: .clear
        }
    }
}

struct CommitsView: View {
    let sessionID: CompanionSession.ID
    @Environment(CompanionStore.self) private var store

    var body: some View {
        RemoteContent(value: store.commits(for: sessionID), retry: load) { commits in
            List(commits) { commit in
                NavigationLink(value: Route.diff(sessionID, commitHash: commit.hash, focusPath: nil)) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(commit.subject)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: 6) {
                            Text(commit.shortHash).monospaced()
                            Text("·")
                            Text(commit.author)
                            Text("·")
                            Text(commit.date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                            if !commit.isPushed {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(FlotillaColors.statusWaitingForInput)
                                    .accessibilityLabel("Unpushed")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                }
                .listRowBackground(FlotillaColors.surface)
            }
            .scrollContentBackground(.hidden)
            .overlay {
                if commits.isEmpty {
                    ContentUnavailableView("No Commits", systemImage: "clock.arrow.circlepath", description: Text("This session's branch has no commits yet."))
                }
            }
        }
        .background(FlotillaColors.canvas)
        .refreshable { await load() }
        .navigationTitle("Commits")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func load() async {
        await store.loadCommits(for: sessionID)
    }
}

/// Read-only, monospaced.
struct FileViewer: View {
    let sessionID: CompanionSession.ID
    let path: String
    @Environment(CompanionStore.self) private var store
    @State private var wrapLines = false
    @State private var isSearching = false
    @State private var searchQuery = ""
    @State private var currentMatchIndex = 0

    var body: some View {
        RemoteContent(value: store.fileContents(at: path, in: sessionID), retry: load) { contents in
            if let contents {
                let lines = contents.components(separatedBy: "\n")
                let matches = isSearching ? FileSearch.matches(in: lines, query: searchQuery) : []

                ScrollViewReader { proxy in
                    ScrollView(wrapLines ? [.vertical] : [.vertical, .horizontal]) {
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .trailing, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { index in
                                    Text("\(index + 1)")
                                }
                            }
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(lines.indices, id: \.self) { index in
                                    Text(lines[index].isEmpty ? " " : lines[index])
                                        .fixedSize(horizontal: !wrapLines, vertical: false)
                                        .id(index)
                                }
                            }
                            .frame(maxWidth: wrapLines ? .infinity : nil, alignment: .leading)
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .textSelection(.enabled)
                        }
                        .font(.caption.monospaced())
                        .padding(16)
                    }
                    .scrollIndicators(.visible)
                    .safeAreaInset(edge: .top, spacing: 0) {
                        if isSearching {
                            TranscriptSearchBar(
                                query: $searchQuery,
                                matchCount: matches.count,
                                currentIndex: currentMatchIndex,
                                onNext: { advance(1, in: matches, proxy: proxy) },
                                onPrevious: { advance(-1, in: matches, proxy: proxy) },
                                onClose: { closeSearch() }
                            )
                            .background(FlotillaColors.canvas)
                        }
                    }
                    .onChange(of: searchQuery) { _, _ in
                        currentMatchIndex = 0
                        if let first = matches.first { jumpToMatch(first, proxy: proxy) }
                    }
                }
            } else {
                ContentUnavailableView("File Unavailable", systemImage: "doc.questionmark", description: Text("\(path)\n\nThe file is outside the session's folder, too large, or not text."))
            }
        }
        .background(FlotillaColors.canvas)
        .navigationTitle((path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search File", systemImage: "magnifyingglass") {
                    if isSearching { closeSearch() } else { isSearching = true }
                }
                .accessibilityIdentifier("FileViewer.SearchToggle")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("File Actions", systemImage: "ellipsis") {
                    Button(
                        wrapLines ? "Scroll Horizontally" : "Wrap Lines",
                        systemImage: wrapLines ? "arrow.left.and.right" : "arrow.turn.down.right"
                    ) {
                        wrapLines.toggle()
                    }
                    .accessibilityIdentifier("FileViewer.WrapToggle")
                    Button("Copy Path", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = path
                    }
                    .accessibilityIdentifier("FileViewer.CopyPath")
                }
            }
        }
        .task { await load() }
    }

    private func advance(_ delta: Int, in matches: [FileSearchMatch], proxy: ScrollViewProxy) {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + delta + matches.count) % matches.count
        jumpToMatch(matches[currentMatchIndex], proxy: proxy)
    }

    private func jumpToMatch(_ match: FileSearchMatch, proxy: ScrollViewProxy) {
        withAnimation(.snappy) { proxy.scrollTo(match.lineIndex, anchor: .center) }
    }

    private func closeSearch() {
        isSearching = false
        searchQuery = ""
        currentMatchIndex = 0
    }

    private func load() async {
        await store.loadFile(at: path, in: sessionID)
    }
}

#Preview("Diff") {
    NavigationStack { DiffView(sessionID: MockFixtures.SessionID.offlineBanner, commitHash: nil, focusPath: nil) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}

#Preview("Commits") {
    NavigationStack { CommitsView(sessionID: MockFixtures.SessionID.offlineBanner) }
        .environment(CompanionStore(data: MockCompanionDataSource()))
        .preferredColorScheme(.dark)
}
