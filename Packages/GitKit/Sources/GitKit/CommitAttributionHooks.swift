import Foundation

/// Prepares a Flotilla-owned hooks directory that records which agent session
/// made each commit, and arranges for the agent's git — and only the agent's
/// git — to use it.
///
/// ## Why not just drop a hook in the repo
///
/// The obvious approach, writing hooks into `.git/hooks`, is wrong in two ways
/// that only show up on a real machine:
///
/// 1. **`core.hooksPath` may redirect hooks elsewhere.** Set globally, it
///    means git never reads `.git/hooks` for *any* repository, so an installed
///    hook would sit there doing nothing.
/// 2. **The effective hooks directory may already be the user's own.** A
///    global hooks directory is shared by every repo they have; installing
///    into it would change behavior far outside Flotilla, and would collide
///    with hooks they already rely on.
///
/// ## What this does instead
///
/// Flotilla keeps its own hooks directory in application support and points
/// the *agent process* at it with `GIT_CONFIG_*` environment variables. Those
/// are inherited only by the agent's process tree, so the user's own `git` in
/// their own shell is completely unaffected.
///
/// Because overriding `core.hooksPath` would otherwise disable every hook the
/// repo would have run, every script first runs the hook the repository would
/// have used, keeping its ability to abort the commit.
///
/// ## Modes
///
/// The scripts read the session's mode from its `CommitAttributionPayload`
/// directory at commit time, so changing a project's mode reaches sessions
/// that are already running:
///
/// - **shared**: `pre-commit` swaps an empty marker under
///   `.flotilla/sessions/<session>/` into the commit being created, adding the
///   session's `prompt.md` the first time. A commit is attributed by the marker
///   it *adds*, so the tree only ever holds the latest marker while every
///   historical commit records its own addition. Complete replay operations
///   can carry the files, subject to Git conflict resolution and selection.
/// - **local**: `post-commit` and `post-rewrite` append events to the
///   payload's spool for the app to ingest. Nothing enters the repository.
/// - **off**: every script only forwards.
public struct CommitAttributionHooks: Sendable {
    public static let version = "v4"
    public static let markerPrefix = "# flotilla-agent-hooks"
    public static let marker = "\(markerPrefix) \(version)"

    /// Set on the agent's process tree only; the scripts only forward without it.
    public static let attributionDirectoryEnvironmentKey = "FLOTILLA_ATTRIBUTION_DIR"
    public static let sessionEnvironmentKey = "FLOTILLA_SESSION"
    /// Optional pin for the hooks that *would* have run. Normally empty — the
    /// scripts resolve it themselves, which stays correct even if the user's
    /// git config changes mid-session.
    public static let originalHooksEnvironmentKey = "FLOTILLA_ORIGINAL_HOOKS"

    /// Repository-relative folder holding one directory per session.
    public static let sharedDirectory = ".flotilla/sessions"

    /// Hooks that only forward. `pre-commit`, `post-commit` and `post-rewrite`
    /// carry the attribution logic and are generated separately.
    public static let forwardedHooks = [
        "applypatch-msg", "commit-msg", "post-applypatch", "post-checkout",
        "post-merge", "pre-applypatch", "pre-auto-gc", "pre-merge-commit",
        "pre-push", "pre-rebase", "post-index-change", "prepare-commit-msg",
    ]

    public init() {}

    // MARK: - Scripts

    public static var preCommitScript: String {
        #"""
        #!/bin/sh
        \#(marker)
        # Runs the repository's own pre-commit first, so a failing check still
        # aborts the commit before anything is staged. In Shared mode it then
        # swaps this session's attribution marker into the commit.

        \#(resolveOriginalHooks)

        if [ -n "$flotilla_original" ] && [ -x "$flotilla_original/pre-commit" ]; then
          "$flotilla_original/pre-commit" "$@" || exit $?
        fi

        \#(resolveMode)
        [ "$flotilla_mode" = shared ] || exit 0

        # A merge is attributed through the commits it brings in.
        flotilla_merge_head=$(git rev-parse --git-path MERGE_HEAD 2>/dev/null)
        [ -n "$flotilla_merge_head" ] && [ -f "$flotilla_merge_head" ] && exit 0

        flotilla_git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
        for flotilla_state in rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
          [ -e "$flotilla_git_dir/$flotilla_state" ] && exit 0
        done

        \#(stampFunction)

        flotilla_stamp >/dev/null 2>&1
        exit 0

        """#
    }

    public static var postCommitScript: String {
        #"""
        #!/bin/sh
        \#(marker)
        # Runs the repository's own post-commit, reconciles shared marker paths,
        # and publishes a complete local event when Local mode is active.

        \#(resolveOriginalHooks)

        if [ -n "$flotilla_original" ] && [ -x "$flotilla_original/post-commit" ]; then
          "$flotilla_original/post-commit" "$@"
        fi

        \#(resolveMode)
        case "$flotilla_mode" in
          shared|local) ;;
          *) exit 0 ;;
        esac
        [ -n "$flotilla_session" ] && [ -n "$flotilla_dir" ] || exit 0

        # Rebases, cherry-picks and reverts replay commits that already carry
        # their own attribution, or none that belongs to this session.
        flotilla_git_dir=$(git rev-parse --absolute-git-dir 2>/dev/null) || exit 0
        for flotilla_state in rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD; do
          [ -e "$flotilla_git_dir/$flotilla_state" ] && exit 0
        done
        git rev-parse -q --verify HEAD^2 >/dev/null 2>&1 && exit 0

        if [ "$flotilla_mode" = shared ]; then
          flotilla_rel="\#(sharedDirectory)/$flotilla_session"
          if git diff-tree --root --no-commit-id --no-renames --name-only -r --diff-filter=A HEAD -- "$flotilla_rel" | grep -q '/m-'; then
            # `git commit <path>` commits from a temporary index. Bring the real
            # index in line, or the next commit would delete the new marker.
            git reset -q HEAD -- "$flotilla_rel" >/dev/null 2>&1
            exit 0
          fi

          # Never amend a completed commit: doing so changes its identity and
          # can include unrelated staged changes. --no-verify opts out.
          exit 0
        fi

        flotilla_json() {
          printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
        }
        flotilla_sha=$(git rev-parse HEAD 2>/dev/null) || exit 0
        flotilla_email=$(git log -1 --format=%ae HEAD 2>/dev/null)
        flotilla_time=$(git log -1 --format=%at HEAD 2>/dev/null)
        flotilla_common=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || exit 0
        flotilla_event=$(mktemp "$flotilla_dir/event-pending-XXXXXXXX") || exit 0
        printf '{"event":"commit","sha":"%s","authorEmail":"%s","authorTime":%s,"commonDirectory":"%s","agent":"%s","model":"%s","session":%s,"recordedAt":%s}\n' \
          "$flotilla_sha" \
          "$(flotilla_json "$flotilla_email")" \
          "${flotilla_time:-0}" \
          "$(flotilla_json "$flotilla_common")" \
          "$(flotilla_json "$(cat "$flotilla_dir/agent" 2>/dev/null)")" \
          "$(flotilla_json "$(cat "$flotilla_dir/model" 2>/dev/null)")" \
          "$(cat "$flotilla_dir/session.json" 2>/dev/null || printf null)" \
          "$(date +%s)" > "$flotilla_event"
        mv "$flotilla_event" "$flotilla_event.ready"
        exit 0

        """#
    }

    public static var postRewriteScript: String {
        #"""
        #!/bin/sh
        \#(marker)
        # Runs the repository's own post-rewrite with the same input. In Local mode
        # it then records git's old -> new commit mapping for amend and rebase.

        \#(resolveOriginalHooks)

        flotilla_input=$(cat)
        if [ -n "$flotilla_original" ] && [ -x "$flotilla_original/post-rewrite" ]; then
          printf '%s\n' "$flotilla_input" | "$flotilla_original/post-rewrite" "$@"
        fi

        \#(resolveMode)
        [ "$flotilla_mode" = local ] && [ -n "$flotilla_dir" ] || exit 0

        flotilla_pairs=$(printf '%s\n' "$flotilla_input" | awk 'NF >= 2 { printf "%s[\"%s\",\"%s\"]", (n++ ? "," : ""), $1, $2 }')
        [ -n "$flotilla_pairs" ] || exit 0
        flotilla_common=$(cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P) || exit 0
        flotilla_common=$(printf '%s' "$flotilla_common" | sed 's/\\/\\\\/g; s/"/\\"/g')
        flotilla_event=$(mktemp "$flotilla_dir/event-pending-XXXXXXXX") || exit 0
        printf '{"event":"rewrite","kind":"%s","commonDirectory":"%s","pairs":[%s],"recordedAt":%s}\n' "${1:-unknown}" "$flotilla_common" "$flotilla_pairs" "$(date +%s)" > "$flotilla_event"
        mv "$flotilla_event" "$flotilla_event.ready"
        exit 0

        """#
    }

    /// A pass-through so overriding `core.hooksPath` doesn't silently disable
    /// the repo's other hooks (a `commit-msg` linter, say).
    public static func forwardingScript(for hook: String) -> String {
        #"""
        #!/bin/sh
        \#(marker)
        # Forwards to the hook this repository would have run.

        \#(resolveOriginalHooks)

        [ -n "$flotilla_original" ] || exit 0
        [ -x "$flotilla_original/\#(hook)" ] || exit 0
        exec "$flotilla_original/\#(hook)" "$@"

        """#
    }

    private static let resolveOriginalHooks = #"""
    # Remove our appended override while retaining prior environment config.
    # Nested Flotilla launches inherit the original base count.
    if [ -n "$FLOTILLA_ORIGINAL_HOOKS" ]; then
      flotilla_original="$FLOTILLA_ORIGINAL_HOOKS"
    else
      flotilla_original=$(GIT_CONFIG_COUNT="${FLOTILLA_BASE_GIT_CONFIG_COUNT:-0}" git config --get core.hooksPath 2>/dev/null)
      if [ -z "$flotilla_original" ]; then
        flotilla_original=$(GIT_CONFIG_COUNT="${FLOTILLA_BASE_GIT_CONFIG_COUNT:-0}" git rev-parse --git-path hooks 2>/dev/null)
      fi
    fi
    """#

    private static let resolveMode = #"""
    flotilla_dir="${FLOTILLA_ATTRIBUTION_DIR:-}"
    flotilla_session="${FLOTILLA_SESSION:-}"
    flotilla_mode=off
    if [ -n "$flotilla_dir" ] && [ -r "$flotilla_dir/mode" ]; then
      flotilla_mode=$(tr -d '[:space:]' < "$flotilla_dir/mode")
    fi
    """#

    /// Swaps this session's marker in the index for a fresh, empty one, adding
    /// the session's prompt document the first time. Best-effort: a failure
    /// leaves the commit as the agent staged it.
    private static let stampFunction = #"""
    flotilla_slug() {
      printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-64
    }

    flotilla_stamp() {
      [ -n "$flotilla_session" ] && [ -n "$flotilla_dir" ] || return 1
      flotilla_top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
      flotilla_rel="\#(sharedDirectory)/$flotilla_session"
      mkdir -p "$flotilla_top/$flotilla_rel" || return 1
      if [ -r "$flotilla_dir/prompt.md" ] && ! git ls-files --error-unmatch -- "$flotilla_rel/prompt.md" >/dev/null 2>&1; then
        cp "$flotilla_dir/prompt.md" "$flotilla_top/$flotilla_rel/prompt.md" || return 1
        git add -- "$flotilla_top/$flotilla_rel/prompt.md" || return 1
      fi
      for flotilla_old in $(git ls-files -- "$flotilla_rel/m-*"); do
        git rm -q --cached -- "$flotilla_old" >/dev/null 2>&1
        rm -f "$flotilla_top/$flotilla_old"
      done
      flotilla_agent=$(flotilla_slug "$(cat "$flotilla_dir/agent" 2>/dev/null)")
      flotilla_model=$(flotilla_slug "$(cat "$flotilla_dir/model" 2>/dev/null)")
      flotilla_marker="$flotilla_rel/m-$(od -An -N6 -tx1 /dev/urandom | tr -d ' \n').${flotilla_agent:-unknown}.${flotilla_model:-default}"
      : > "$flotilla_top/$flotilla_marker" || return 1
      git add -- "$flotilla_top/$flotilla_marker"
    }
    """#

    // MARK: - Installation

    /// Writes the directory. Idempotent: rewriting identical content is
    /// cheaper to reason about than tracking which files changed.
    public func prepare(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try write(Self.preCommitScript, to: directory.appendingPathComponent("pre-commit"))
        try write(Self.postCommitScript, to: directory.appendingPathComponent("post-commit"))
        try write(Self.postRewriteScript, to: directory.appendingPathComponent("post-rewrite"))
        for hook in Self.forwardedHooks {
            try write(Self.forwardingScript(for: hook), to: directory.appendingPathComponent(hook))
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    /// Environment for a git process that should record attribution: point
    /// git at Flotilla's hooks, and tell those hooks which session is
    /// committing and where its payload lives.
    ///
    /// `GIT_CONFIG_COUNT` is *appended to*, never overwritten — clobbering it
    /// would silently drop config another tool had already injected.
    public static func environment(
        base: [String: String],
        sessionID: String,
        attributionDirectory: URL,
        flotillaHooksDirectory: URL,
        originalHooksDirectory: URL?
    ) -> [String: String] {
        var environment = base
        let existingCount = Int(base["GIT_CONFIG_COUNT"] ?? "") ?? 0
        environment["GIT_CONFIG_KEY_\(existingCount)"] = "core.hooksPath"
        environment["GIT_CONFIG_VALUE_\(existingCount)"] = flotillaHooksDirectory.path
        environment["GIT_CONFIG_COUNT"] = String(existingCount + 1)
        environment["FLOTILLA_BASE_GIT_CONFIG_COUNT"] = base["FLOTILLA_BASE_GIT_CONFIG_COUNT"] ?? String(existingCount)
        environment[attributionDirectoryEnvironmentKey] = attributionDirectory.path
        environment[sessionEnvironmentKey] = sessionID
        // Set even when empty: a value inherited from an outer agent session
        // would otherwise point these scripts at that session's hooks.
        environment[originalHooksEnvironmentKey] = originalHooksDirectory?.path ?? ""
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
