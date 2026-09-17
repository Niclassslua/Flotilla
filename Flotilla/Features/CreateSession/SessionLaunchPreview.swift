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
        generalSessionDirectory: URL
    ) -> SessionLaunchPreview {
        let title = derivedTitle(goal: goal, projectChoice: projectChoice)

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
                branchName: BranchNaming.generate(from: title, uuid: Self.previewUUID)
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

    /// Matches the rule the old `CreateSessionView.sessionTitle` used, so
    /// existing sessions and new ones are named the same way.
    static func derivedTitle(goal: String, projectChoice: ProjectChoice) -> String {
        let firstLine = goal
            .components(separatedBy: .newlines)
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if !firstLine.isEmpty {
            return String(firstLine.prefix(60))
        }
        switch projectChoice {
        case .general: return "General session"
        case .known(let project): return project.name
        case .custom(let url): return url.lastPathComponent
        }
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
