import Foundation

/// Prepares a Flotilla-owned hooks directory that stamps agent attribution
/// into commit messages, and arranges for the agent's git — and only the
/// agent's git — to use it.
///
/// ## Why not just drop a hook in the repo
///
/// The obvious approach, writing `prepare-commit-msg` into `.git/hooks`, is
/// wrong in two ways that only show up on a real machine:
///
/// 1. **`core.hooksPath` may redirect hooks elsewhere.** Set globally, it
///    means git never reads `.git/hooks` for *any* repository, so an installed
///    hook would sit there doing nothing.
/// 2. **The effective hooks directory may already be the user's own.** A
///    global hooks directory is shared by every repo they have; installing
///    into it would change behavior far outside Flotilla, and would collide
///    with a `prepare-commit-msg` they already rely on.
///
/// ## What this does instead
///
/// Flotilla keeps its own hooks directory in application support and points
/// the *agent process* at it with `GIT_CONFIG_*` environment variables. Those
/// are inherited only by the agent's process tree, so the user's own `git` in
/// their own shell is completely unaffected — no repository state is modified
/// at all.
///
/// Because overriding `core.hooksPath` would otherwise disable every hook the
/// repo would have run, the directory contains a forwarding shim for each of
/// those hooks, and the `prepare-commit-msg` runs the original first — keeping
/// its ability to edit the message or abort the commit — then appends the
/// trailer.
public struct AgentTrailerHooks: Sendable {
    public static let version = "v2"
    public static let markerPrefix = "# flotilla-agent-hooks"
    public static let marker = "\(markerPrefix) \(version)"

    /// Set on the agent's process tree only. The stamp is skipped without it,
    /// so the shims stay inert for anything else that happens to run them.
    public static let agentEnvironmentKey = "FLOTILLA_AGENT"
    public static let sessionEnvironmentKey = "FLOTILLA_SESSION"
    /// Optional pin for the hooks that *would* have run. Normally unset — the
    /// scripts resolve it themselves, which keeps the launch path synchronous
    /// and stays correct even if the user's git config changes mid-session.
    public static let originalHooksEnvironmentKey = "FLOTILLA_ORIGINAL_HOOKS"

    /// Hooks worth forwarding. Anything not listed simply won't fire for agent
    /// commits, so this covers the ones that realistically exist and matter.
    public static let forwardedHooks = [
        "applypatch-msg", "commit-msg", "post-applypatch", "post-checkout",
        "post-commit", "post-merge", "post-rewrite", "pre-applypatch",
        "pre-auto-gc", "pre-commit", "pre-merge-commit", "pre-push",
        "pre-rebase", "post-index-change",
    ]

    public init() {}

    /// The stamping hook. Delegates *before* stamping so a user hook that
    /// rewrites the message can't clobber the trailer, and so a non-zero exit
    /// from it still aborts the commit exactly as it would have.
    public static var prepareCommitMessageScript: String {
        """
        #!/bin/sh
        \(marker)
        # Appends a Flotilla-Agent trailer to commits made by an agent session.
        # Runs the repository's own prepare-commit-msg first, unchanged.

        # Resolve the hooks git *would* have used. `GIT_CONFIG_COUNT=0` drops
        # Flotilla's own env-injected core.hooksPath for this one call, so this
        # reads the user's real configuration rather than our override.
        if [ -n "$FLOTILLA_ORIGINAL_HOOKS" ]; then
          flotilla_original="$FLOTILLA_ORIGINAL_HOOKS"
        else
          flotilla_original=$(GIT_CONFIG_COUNT=0 git config --get core.hooksPath 2>/dev/null)
          if [ -z "$flotilla_original" ]; then
            flotilla_original=$(GIT_CONFIG_COUNT=0 git rev-parse --git-path hooks 2>/dev/null)
          fi
        fi

        if [ -n "$flotilla_original" ] && [ -x "$flotilla_original/prepare-commit-msg" ]; then
          "$flotilla_original/prepare-commit-msg" "$@" || exit $?
        fi

        [ -n "$\(agentEnvironmentKey)" ] || exit 0

        # Merge and squash messages are assembled by git from commits that
        # already carry their own trailers.
        case "$2" in
          merge|squash) exit 0 ;;
        esac

        git interpret-trailers --in-place --if-exists doNothing \\
          --trailer "Flotilla-Agent=$\(agentEnvironmentKey)" "$1" || exit 0

        if [ -n "$\(sessionEnvironmentKey)" ]; then
          git interpret-trailers --in-place --if-exists doNothing \\
            --trailer "Flotilla-Session=$\(sessionEnvironmentKey)" "$1" || exit 0
        fi

        exit 0

        """
    }

    /// A pass-through so overriding `core.hooksPath` doesn't silently disable
    /// the repo's other hooks (a `pre-commit` linter, say).
    public static func forwardingScript(for hook: String) -> String {
        """
        #!/bin/sh
        \(marker)
        # Forwards to the hook this repository would have run.

        # Resolve the hooks git *would* have used. `GIT_CONFIG_COUNT=0` drops
        # Flotilla's own env-injected core.hooksPath for this one call, so this
        # reads the user's real configuration rather than our override.
        if [ -n "$FLOTILLA_ORIGINAL_HOOKS" ]; then
          flotilla_original="$FLOTILLA_ORIGINAL_HOOKS"
        else
          flotilla_original=$(GIT_CONFIG_COUNT=0 git config --get core.hooksPath 2>/dev/null)
          if [ -z "$flotilla_original" ]; then
            flotilla_original=$(GIT_CONFIG_COUNT=0 git rev-parse --git-path hooks 2>/dev/null)
          fi
        fi

        [ -n "$flotilla_original" ] || exit 0
        [ -x "$flotilla_original/\(hook)" ] || exit 0
        exec "$flotilla_original/\(hook)" "$@"

        """
    }

    /// Writes the directory. Idempotent: rewriting identical content is
    /// cheaper to reason about than tracking which files changed.
    public func prepare(directory: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        try write(
            Self.prepareCommitMessageScript,
            to: directory.appendingPathComponent("prepare-commit-msg")
        )
        for hook in Self.forwardedHooks {
            try write(Self.forwardingScript(for: hook), to: directory.appendingPathComponent(hook))
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Environment for the agent process: point git at Flotilla's hooks, and
    /// tell those hooks who is committing and where the real hooks live.
    ///
    /// `GIT_CONFIG_COUNT` is *appended to*, never overwritten — clobbering it
    /// would silently drop config another tool had already injected.
    public static func environment(
        base: [String: String],
        agentRawValue: String,
        sessionID: String,
        flotillaHooksDirectory: URL,
        originalHooksDirectory: URL?
    ) -> [String: String] {
        var environment = base
        let existingCount = Int(base["GIT_CONFIG_COUNT"] ?? "") ?? 0
        environment["GIT_CONFIG_KEY_\(existingCount)"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_\(existingCount)"] = flotillaHooksDirectory.path
        environment["GIT_CONFIG_COUNT"] = String(existingCount + 1)
        environment[agentEnvironmentKey] = agentRawValue
        environment[sessionEnvironmentKey] = sessionID
        if let originalHooksDirectory {
            environment[originalHooksEnvironmentKey] = originalHooksDirectory.path
        }
        return environment
    }
}

public extension GitServiceProtocol {
    /// The hooks directory this repository would use right now, honoring a
    /// `core.hooksPath` override at any config scope.
    ///
    /// `--git-path hooks` rather than `--git-common-dir` + "hooks": only the
    /// former accounts for `core.hooksPath`, and getting this wrong means
    /// writing hooks into a directory git will never read.
    func effectiveHooksDirectory(at repoPath: URL) async throws -> URL {
        let raw = try await currentHooksPath(at: repoPath)
        return raw.hasPrefix("/")
            ? URL(fileURLWithPath: raw).standardizedFileURL
            : repoPath.appendingPathComponent(raw).standardizedFileURL
    }
}
