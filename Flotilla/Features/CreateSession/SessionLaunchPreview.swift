import Foundation
import SessionKit
import GitKit
import AgentKit
import SettingsKit

/// What a launch is actually going to do, resolved before the user commits.
///
/// The old form asked you to choose "New Worktree" and then silently derived a
/// branch name from your goal text and a destination under the worktree base
/// directory, showing neither. This computes both up front using the same
/// `BranchNaming` and `WorktreePlanner` the real creation path uses, so the
/// preview cannot drift from the behaviour.
struct SessionLaunchPreview: Equatable {
    /// The prompt-derived fallback title. AI naming resolves at launch.
    let title: String
    /// `nil` for general sessions and main-checkout runs.
    let branchSlug: String?
    let namingPending: Bool
    let workingDirectory: URL
    /// Rendered argv, e.g. `claude --model opus --effort high`.
    let command: String
    /// Set when the agent will edit a shared checkout that other sessions can
    /// also be writing to.
    let sharedCheckoutWarning: String?

    var isWorktree: Bool { branchSlug != nil }

    /// The path with `~` substituted for the home prefix.
    var displayDirectory: String {
        workingDirectory.path.replacingOccurrences(
            of: FileManager.default.homeDirectoryForCurrentUser.path,
            with: "~"
        )
    }

    /// AI naming is not known until launch. For prompt-derived branches, the
    /// preview shows only the stable human-readable slug.
    var displayBranch: String? {
        if namingPending { return "Name chosen on launch" }
        return branchSlug
    }

    static func resolve(
        goal: String,
        projectChoice: ProjectChoice,
        agent: AgentKind,
        model: String?,
        effort: AgentEffort?,
        createWorktree: Bool,
        namingSource: SessionNamingSource = .promptDerived,
        worktreeBaseDirectory: URL,
        generalSessionDirectory: URL,
        linkedIssue: IssueLink? = nil
    ) -> SessionLaunchPreview {
        let title = linkedIssue?.sessionTitle ?? derivedTitle(goal: goal, projectChoice: projectChoice)
        // An issue names the session itself, exactly as `createSession` does.
        let namingSource = linkedIssue == nil ? namingSource : .promptDerived

        var branchSlug: String?
        var workingDirectory = generalSessionDirectory
        var warning: String?
        // Apple Intelligence resolves its name at launch; agent-managed
        // naming is decided by the agent itself once it's running — in both
        // cases nothing about the eventual title, branch, or destination is
        // knowable yet, so the preview shows a placeholder for either.
        let namingPending = createWorktree && namingSource != .promptDerived

        if let folder = projectChoice.folder {
            // The same planner the creation path uses. Its branch argument is
            // opaque to it, so a placeholder UUID keeps the destination shape
            // honest while the slug is reported separately.
            let decision = WorktreePlanner().plan(
                useNewWorktree: createWorktree,
                projectRoot: folder,
                worktreeBaseDirectory: worktreeBaseDirectory,
                branchName: linkedIssue?.branchName(uuid: Self.previewUUID) ?? BranchNaming.generate(from: title, uuid: Self.previewUUID)
            )
            switch decision {
            case .useExistingCheckout(let path):
                workingDirectory = path
                warning = "The agent edits this checkout directly — concurrent sessions can conflict."
            case .createWorktree(_, let branch, let destination):
                workingDirectory = namingPending
                    ? worktreeBaseDirectory.appendingPathComponent("flotilla/…", isDirectory: true)
                    : destination
                branchSlug = Self.stripSuffix(from: branch)
            }
        }

        return SessionLaunchPreview(
            title: title,
            branchSlug: branchSlug,
            namingPending: namingPending,
            workingDirectory: workingDirectory,
            command: renderCommand(agent: agent, model: model, effort: effort),
            sharedCheckoutWarning: warning
        )
    }

    /// Prompt-derived titles are the synchronous fallback when Apple Intelligence
    /// is off or returns nothing usable. They must stay sidebar-sized: strip the
    /// conversational ask, then clip to a short phrase — never paste the first
    /// 60 characters of the goal (that produced titles like "I would like to
    /// build a comprehensive documentation of hooks").
    static func derivedTitle(goal: String, projectChoice: ProjectChoice) -> String {
        let firstLine = goal
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty {
            return clipPromptTitle(firstLine)
        }
        switch projectChoice {
        case .general: return "General session"
        case .known(let project): return project.name
        case .custom(let url): return url.lastPathComponent
        }
    }

    /// Shared clip used by prompt-derived naming and by the Apple Intelligence
    /// salvage path when the model returns a long or request-shaped phrase.
    static func clipPromptTitle(_ line: String) -> String {
        var text = stripRequestPreamble(line)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop trailing sentence punctuation the goal often carries.
        while let last = text.last, ".,:;!?".contains(last) {
            text = String(text.dropLast()).trimmingCharacters(in: .whitespaces)
        }
        guard !text.isEmpty else { return line.trimmingCharacters(in: .whitespacesAndNewlines) }

        var words = Array(text.split(whereSeparator: \.isWhitespace).prefix(Self.maxDerivedWords).map(String.init))
        while words.count > 2, Self.trailingFillers.contains(words[words.count - 1].lowercased()) {
            words.removeLast()
        }
        var clipped = words.joined(separator: " ")
        if clipped.count > Self.maxDerivedCharacters {
            clipped = truncateAtWordBoundary(clipped, limit: Self.maxDerivedCharacters)
        }
        return AppleIntelligenceSessionNameGenerator.applySentenceCaseIfNeeded(clipped)
    }

    private static let maxDerivedWords = 5
    private static let maxDerivedCharacters = 40
    private static let trailingFillers: Set<String> = [
        "a", "an", "the", "of", "to", "for", "and", "or", "in", "on", "with", "from",
    ]

    /// Leading politeness / intent wrappers that turn a subject into a request.
    private static let requestPreamblePattern = #"(?i)^(i would like to|i'd like to|i want to|i need to|i'm trying to|i am trying to|i'm going to|i am going to|please|can you|could you|would you|help me(?: to)?)\b[\s,]*"#

    private static func stripRequestPreamble(_ line: String) -> String {
        var text = line
        // Apply once — nested wrappers ("Please can you…") are rare and a single
        // pass keeps the heuristic predictable.
        if let range = text.range(of: requestPreamblePattern, options: .regularExpression) {
            text = String(text[range.upperBound...])
        }
        return text
    }

    private static func truncateAtWordBoundary(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit)
        let head = text[..<end]
        if let lastSpace = head.lastIndex(where: \.isWhitespace), lastSpace > head.startIndex {
            return String(head[..<lastSpace]).trimmingCharacters(in: .whitespaces)
        }
        return String(head).trimmingCharacters(in: .whitespaces)
    }

    /// The argv the CLI will receive, built from the same descriptor flag specs
    /// `CLIAgentProvider` uses — so the preview shows real flags, not a guess at
    /// them. The goal itself is deliberately omitted: it is delivered to the PTY
    /// rather than passed as an argument, and pasting a paragraph into this line
    /// would drown the flags.
    static func renderCommand(agent: AgentKind, model: String?, effort: AgentEffort?) -> String {
        let descriptor = AgentCatalog.descriptor(for: agent)
        var tokens = [descriptor.binaryName]

        if let model, !model.isEmpty, let modelFlag = descriptor.modelFlag {
            tokens.append(contentsOf: modelFlag.arguments(for: model))
        }
        if let effort, agent.supportsEffortSelection, let effortFlag = descriptor.effortFlag {
            tokens.append(contentsOf: effortFlag.arguments(for: effort))
        }
        return tokens.joined(separator: " ")
    }

    // MARK: - Private

    /// A fixed UUID so preview resolution is pure and testable. Only the
    /// suffix it produces is discarded.
    private static let previewUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    /// `BranchNaming` returns `flotilla/<slug>-<8hex>`; both the namespace and
    /// suffix are implementation details, so only the stable part is surfaced.
    private static func stripSuffix(from branch: String) -> String {
        BranchNaming.displayName(for: branch)
    }
}
