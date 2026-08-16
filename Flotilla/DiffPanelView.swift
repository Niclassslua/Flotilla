import SwiftUI
import Observation
import SessionKit
import GitKit

@Observable
@MainActor
final class DiffPanelViewModel {
    let session: Session
    private let gitService: any GitServiceProtocol

    private(set) var snapshot = GitChangesSnapshot(
        status: GitStatus(entries: []),
        staged: [],
        unstaged: [],
        untracked: []
    )
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var errorMessage: String?

    private var repoPath: URL {
        session.worktree?.worktreePath ?? session.workingDirectory
    }

    init(session: Session, gitService: any GitServiceProtocol) {
        self.session = session
        self.gitService = gitService
    }

    func monitor() async {
        await refresh()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            await refresh(showsSpinner: false)
        }
    }

    func refresh(showsSpinner: Bool = true) async {
        if showsSpinner { isLoading = true }
        defer {
            isLoading = false
            hasLoadedOnce = true
        }
        do {
            snapshot = try await gitService.changes(at: repoPath)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The XCUITest runner is sandboxed away from the fixture checkout; this
    /// automation-only seam performs the edit in the app process, then the
    /// normal live Git pipeline observes it independently.
    func simulateEditForAutomation() async {
        let readme = repoPath.appendingPathComponent("README.md")
        do {
            let existing = (try? String(contentsOf: readme, encoding: .utf8)) ?? ""
            try (existing + "edit-\(UUID().uuidString.prefix(8))\n").write(
                to: readme,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct DiffPanelView: View {
    let session: Session
    @State private var viewModel: DiffPanelViewModel

    #if DEBUG
    private var isUITesting: Bool {
        ProcessInfo.processInfo.environment["UI_TESTING"] == "1"
    }
    #else
    private var isUITesting: Bool { false }
    #endif

    init(session: Session, gitService: any GitServiceProtocol) {
        self.session = session
        _viewModel = State(initialValue: DiffPanelViewModel(session: session, gitService: gitService))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working Changes")
                        .font(.headline)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("DiffPanel.Summary")
                }
                Spacer()
                #if DEBUG
                if isUITesting {
                    Button("Simulate Edit") {
                        Task { await viewModel.simulateEditForAutomation() }
                    }
                    .accessibilityIdentifier("DiffPanel.SimulateEditButton")
                }
                #endif
                Button {
                    Task { await viewModel.refresh() }
                } label: {
                    Label("Refresh Changes", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh changes")
                .accessibilityIdentifier("DiffPanel.RefreshButton")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            Divider()

            if viewModel.isLoading && !viewModel.hasLoadedOnce {
                ProgressView("Reading Git changes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("DiffPanel.Loading")
            } else if viewModel.snapshot.allDiffs.isEmpty {
                ContentUnavailableView(
                    "Working Tree Clean",
                    systemImage: "checkmark.circle",
                    description: Text("No staged, unstaged, or untracked changes.")
                )
                .accessibilityIdentifier("DiffPanel.Empty")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(viewModel.snapshot.allDiffs.enumerated()), id: \.offset) { _, diff in
                            DiffFileView(diff: diff)
                        }
                    }
                    .padding(14)
                }
                .accessibilityIdentifier("DiffPanel.List")
            }
        }
        .task(id: session.id) { await viewModel.monitor() }
    }

    private var summary: String {
        let snapshot = viewModel.snapshot
        return "\(snapshot.staged.count) staged · \(snapshot.unstaged.count) unstaged · \(snapshot.untracked.count) untracked"
    }
}

private struct DiffFileView: View {
    let diff: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: stageIcon)
                    .foregroundStyle(stageColor)
                Text(diff.path)
                    .font(.system(.body, design: .monospaced, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("DiffPanel.File-\(diff.path)")
                Spacer()
                Text(diff.stage.rawValue.capitalized)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(stageColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(stageColor.opacity(0.12), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(nsColor: .controlBackgroundColor))

            ForEach(diff.hunks.indices, id: \.self) { hunkIndex in
                let hunk = diff.hunks[hunkIndex]
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.07))

                ForEach(hunk.lines.indices, id: \.self) { lineIndex in
                    let line = hunk.lines[lineIndex]
                    Text(highlighted(line, path: diff.path))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 1)
                        .background(lineBackground(for: line))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7))
        }
    }

    private var stageColor: Color {
        switch diff.stage {
        case .staged: .green
        case .unstaged: .orange
        case .untracked: .blue
        }
    }

    private var stageIcon: String {
        switch diff.stage {
        case .staged: "checkmark.circle.fill"
        case .unstaged: "pencil.circle.fill"
        case .untracked: "plus.circle.fill"
        }
    }

    private func lineBackground(for line: String) -> Color {
        if line.hasPrefix("+") { return .green.opacity(0.08) }
        if line.hasPrefix("-") { return .red.opacity(0.08) }
        return .clear
    }

    private func highlighted(_ line: String, path: String) -> AttributedString {
        let result = NSMutableAttributedString(string: line)
        let fullRange = NSRange(location: 0, length: result.length)
        let baseColor: NSColor = line.hasPrefix("+") ? .systemGreen : line.hasPrefix("-") ? .systemRed : .labelColor
        result.addAttribute(.foregroundColor, value: baseColor, range: fullRange)

        let codeExtensions = Set(["swift", "js", "ts", "tsx", "jsx", "py", "go", "rs", "java", "kt", "c", "h", "cpp"])
        guard codeExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) else {
            return AttributedString(result)
        }

        let patterns: [(String, NSColor)] = [
            (#"\b(class|struct|enum|protocol|func|let|var|if|else|switch|case|return|import|async|await|throws|throw|public|private|internal|extension|init|self|true|false|nil)\b"#, .systemPurple),
            (#"\"(?:\\.|[^\"\\])*\""#, .systemOrange),
            (#"\b\d+(?:\.\d+)?\b"#, .systemBlue),
            (#"//.*$|#.*$"#, .secondaryLabelColor)
        ]
        for (pattern, color) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { continue }
            for match in regex.matches(in: line, range: fullRange) {
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }
        return AttributedString(result)
    }
}
