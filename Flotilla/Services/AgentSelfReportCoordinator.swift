import Foundation

/// A small JSON descriptor file the agent writes once to report back
/// metadata it chose itself — session title, worktree branch name,
/// and worktree path. Flotilla polls for this file after launch and
/// applies any fields it finds to the running session's bookkeeping.
///
/// This mirrors the existing `HookConfigurationWriter`/`HookEventReceiver`
/// pattern: a per-session file under the app's support directory,
/// written by the agent, polled by Flotilla.
struct AgentSelfReportDescriptor: Codable, Equatable, Sendable {
    var title: String?
    var branch: String?
    var worktreePath: String?
}

enum AgentSelfReportCoordinator {

    /// Deterministic path for a session's self-report descriptor file.
    static func descriptorPath(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("self-report", isDirectory: true)
            .appendingPathComponent("\(sessionID.uuidString).json", isDirectory: false)
    }

    /// Removes any leftover descriptor from a previous launch.
    static func clearDescriptor(for sessionID: UUID, supportDirectory: URL) {
        let path = descriptorPath(for: sessionID, supportDirectory: supportDirectory)
        try? FileManager.default.removeItem(at: path)
    }

    /// Polls the descriptor file at ~0.5 s intervals until it appears and
    /// decodes, or until `timeout` elapses. Returns `nil` on timeout.
    static func waitForDescriptor(
        sessionID: UUID,
        supportDirectory: URL,
        timeout: Duration = .seconds(25)
    ) async -> AgentSelfReportDescriptor? {
        let path = descriptorPath(for: sessionID, supportDirectory: supportDirectory)
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let data = try? Data(contentsOf: path),
               let descriptor = try? JSONDecoder().decode(AgentSelfReportDescriptor.self, from: data) {
                return descriptor
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    /// Composes the setup instructions prepended to the agent's prompt.
    ///
    /// - Parameters:
    ///   - wantsTitle: Whether the agent should propose a session title.
    ///   - wantsWorktree: Whether the agent should create its own worktree.
    ///   - descriptorPath: Absolute path to write the JSON descriptor to.
    ///   - projectRoot: The project's main checkout (for `git worktree add`).
    ///   - worktreeBaseDirectory: Where new worktrees should be created.
    static func instructions(
        wantsTitle: Bool,
        wantsWorktree: Bool,
        descriptorPath: URL,
        projectRoot: URL?,
        worktreeBaseDirectory: URL?
    ) -> String {
        guard wantsTitle || wantsWorktree else { return "" }

        var lines: [String] = ["Before starting the task below, complete this setup:"]

        if wantsTitle {
            lines.append(
                "- Choose a concise 2–5 word noun-phrase title in sentence case naming what this session is about, so it is easily identifiable in a list of sessions:\n"
                + "  * Lead with the most specific subject named — the component, feature, file, function, service, error, or concept — keeping code identifiers verbatim.\n"
                + "  * State the subject directly rather than describing the task: omit request verbs (such as fix, add, implement, investigate, update) and trailing action nouns (such as implementation, analysis, or review), as every session in the list is a task and the action carries no distinguishing information.\n"
                + "  * If the session is a question or discussion rather than a task, name the topic being asked about.\n"
                + "  * Do not append explanations after dashes or colons."
            )
        }

        if wantsWorktree, let projectRoot, let worktreeBaseDirectory {
            if wantsTitle {
                lines.append(
                    "- Create an isolated git worktree for this task: convert your chosen title into a kebab-case slug and name the branch \"flotilla/<slug>\", then from \(projectRoot.path) run "
                    + "`git worktree add -b flotilla/<slug> \(worktreeBaseDirectory.path)/<slug>`. "
                    + "From then on, read and edit files using absolute paths under that worktree "
                    + "— do not modify files under \(projectRoot.path) directly."
                )
            } else {
                lines.append(
                    "- Create an isolated git worktree for this task: choose a concise 2–4 word kebab-case slug naming the specific component, feature, file, or error (omitting action verbs like fix or add) and name the branch \"flotilla/<slug>\". Then from \(projectRoot.path) run "
                    + "`git worktree add -b flotilla/<slug> \(worktreeBaseDirectory.path)/<slug>`. "
                    + "From then on, read and edit files using absolute paths under that worktree "
                    + "— do not modify files under \(projectRoot.path) directly."
                )
            }
        }

        var jsonKeys: [String] = []
        if wantsTitle { jsonKeys.append("\"title\": \"...\"") }
        if wantsWorktree, let worktreeBaseDirectory {
            jsonKeys.append("\"branch\": \"flotilla/<slug>\"")
            jsonKeys.append("\"worktreePath\": \"\(worktreeBaseDirectory.path)/<slug>\"")
        } else if wantsWorktree {
            jsonKeys.append("\"branch\": \"flotilla/<slug>\"")
            jsonKeys.append("\"worktreePath\": \"...\"")
        }
        lines.append(
            "- Write a JSON file to \(descriptorPath.path) with the keys you determined: "
            + "{\(jsonKeys.joined(separator: ", "))}"
        )

        lines.append("")
        lines.append("Once setup is complete, begin the actual task:")
        lines.append("")

        return lines.joined(separator: "\n")
    }
}
