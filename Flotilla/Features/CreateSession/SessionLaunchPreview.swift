import Foundation
import SessionKit
import GitKit
import AgentKit

/// What a launch is actually going to do, resolved before the user commits.
///
/// The old form asked you to choose "New Worktree" and then silently derived a
/// branch name from your goal text and a destination under the worktree base
/// directory, showing neither. This computes both up front using the same
/// `BranchNaming` and `WorktreePlanner` the real creation path uses, so the
/// preview cannot drift from the behaviour.
struct SessionLaunchPreview: Equatable {
    /// The title the session will get — also the string the branch slug comes from.
    let title: String
    /// `nil` for general sessions and main-checkout runs.
    let branchSlug: String?
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

    /// `BranchNaming.generate` appends a fresh random 8-hex suffix on every
    /// call, so the exact branch cannot be known before `createSession` runs.
    /// Showing a concrete suffix here would be a lie the user could check and
    /// find wrong — so the stable slug is shown with the suffix as a visible
    /// placeholder.
    var displayBranch: String? {
        branchSlug.map { "\($0)-••••••••" }
    }

    static func resolve(
        goal: String,
        projectChoice: ProjectChoice,
        agent: AgentKind,
        model: String?,
        effort: AgentEffort?,
        createWorktree: Bool,
        worktreeBaseDirectory: URL,
        generalSessionDirectory: URL
    ) -> SessionLaunchPreview {
        let title = derivedTitle(goal: goal, projectChoice: projectChoice)

        var branchSlug: String?
        var workingDirectory = generalSessionDirectory
        var warning: String?

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
                workingDirectory = destination
                branchSlug = Self.stripSuffix(from: branch)
            }
        }

        return SessionLaunchPreview(
            title: title,
            branchSlug: branchSlug,
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

    /// `BranchNaming` returns `flotilla/<slug>-<8hex>`; the suffix is
    /// per-launch noise, so only the stable part is surfaced.
    private static func stripSuffix(from branch: String) -> String {
        guard let separator = branch.lastIndex(of: "-") else { return branch }
        return String(branch[branch.startIndex..<separator])
    }
}
