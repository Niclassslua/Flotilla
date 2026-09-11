# Commit attribution

Flotilla can retain the agent/provider, selected model, and initial prompt behind a commit without adding commit-message trailers. Settings → Git chooses the default; a project's menu can override it.

| Mode | Storage | Sharing |
| --- | --- | --- |
| Off | No new attribution payload or events; existing attribution remains readable | None added |
| On this Mac (default) | Swift domain records persisted by GRDB, with hook delivery files in application support | Never written into the repository |
| Shared in repository | Empty rolling markers and a prompt document under `.flotilla/sessions/<session UUID>/` | Ordinary commits, pushes, and clones carry the files |

Changing modes affects subsequent recording. It neither rewrites existing commits nor exports old local records. The local deletion command removes local attribution records and published pending events; it cannot remove prompts already committed to Git. Normal session conversation storage is independent of this setting. The recorded model is the selected launch model; a missing model means provider default/unknown, not an observed model identity.

## Shared markers

The pre-commit hook replaces this session's tracked `m-*` file with an empty `m-<random>.<agent>.<model slug>` file and adds `prompt.md` if absent. History reads markers introduced by each commit, rather than the marker currently checked out. The current tree normally holds one marker per session; older commits retain their own marker in history. Model slugs are filename-safe and capped at 64 characters; the prompt document supplies the exact model when it agrees.

Existing repository hooks run first and can reject a commit. Flotilla uses a process-scoped `core.hooksPath` override, with its generated hooks in `attribution-hooks-v4` in application support. It does not install scripts into the repository's hooks folder. Session processes and app commit controls supply the same attribution environment. Cached commit controls refresh their session environment when reused.

Git allows `--no-verify` to bypass pre-commit. Flotilla respects that: it does not amend a completed commit to inject metadata. See [Git hooks](https://git-scm.com/docs/githooks). Path-specific commits are covered by the normal pre-commit hook, with the attribution index reconciled afterward.

The marker scheme carries files through complete rebases/cherry-picks and can retain a session's last marker in a squash. These are not universal guarantees:

- A lone later cherry-pick may bring a marker without the prompt introduced in an earlier commit. History reads the prompt from that commit, never from an unrelated current checkout.
- Selective code copying or a conflict resolution that omits metadata loses that attachment.
- Marker deletion/restoration can produce conflicts under different Git merge/rename settings. The tests cover concrete operations, not every merge configuration.
- A restored marker already introduced in the commit's ancestry is excluded, preventing ordinary reverts from claiming a new contribution.
- The current History detail displays one attribution per commit. A squash with several sessions retains their repository files, but does not yet show every contributor in the detail panel.
- Shared prompts are ordinary tracked content and remain in repository history after their current files are deleted.

## Local persistence and rewritten commits

`CommitAttributionService` drains hook events at startup and every two seconds while the app runs, before History resolution, and before worktree deletion. A hook writes a complete event to a unique temporary file, closes it, then renames it to `.ready`. Readers ignore incomplete files. Commit events include a snapshot of the session payload at event time. Failed ingestion retains published files for retry; ingestion ignores a duplicate original SHA/session/repository record.

Migration `v12_addCommitAttribution` adds the tables; `v13_scopeAttributionSessionsToRepository` upgrades the early session-only key without losing snapshots, commits, or links:

- `attribution_session`, keyed by session UUID and common Git directory, containing the prompt snapshot independently of the live session.
- `attributed_commit`, with a stable UUID, original SHA, agent/model, author fields, and patch evidence.
- `attributed_commit_link`, mapping record UUIDs to observed SHAs and recording the source of each association.

The common Git directory identifies a repository across its worktrees. A single general session can therefore contribute to multiple repositories without overwriting another repository's snapshot. Deleting the live session does not cascade into attribution. Payloads are retained for failed ingestion retries.

A rebase or amend creates new Git objects; old SHAs do not mutate. Flotilla retains old links and adds new ones. A `post-rewrite` event provides explicit old-to-new mappings, including multiple old commits mapped to one squash. For rewrites outside the hooked process, Flotilla searches recent reachable history and requires matching author fields plus a unique matching patch. Author email and second-resolution timestamps alone are not identities. Ambiguous or changed patches remain unresolved rather than receiving a guessed prompt.

Patch IDs are evidence of similar changes, not durable commit identities; Git's stable patch-ID mode ignores whitespace and file-diff order. See [git-patch-id](https://git-scm.com/docs/git-patch-id). Arbitrary external squashes, history filtering, clock anomalies, expired objects before ingestion, repository relocation, and identical repeated patches cannot always be recovered. No session-wide diff heuristic is used to claim unrelated intervening work.

## Integration and compatibility

- `Packages/SettingsKit/.../AppSettings.swift`: mode and project overrides. Legacy `stampAgentTrailer=false` becomes Off; true/absent becomes Local, never Shared.
- `Packages/GitKit/.../CommitAttributionHooks.swift` and `CommitAttributionPayload.swift`: hook scripts, event protocol, and marker/prompt format.
- `Packages/SessionKit/.../CommitAttributionRecords.swift`: storage domain types.
- `Packages/PersistenceKit/.../GRDBSessionRepository.swift`: migration and CRUD.
- `Flotilla/Services/CommitAttributionService.swift`: payload preparation, ingestion, and resolution.
- `Flotilla/Features/Projects/ProjectGraphViewModel.swift`: Shared → Local → legacy trailer/branch/author inference precedence, including paginated history.

Existing trailers remain readable. Stored attribution no longer depends on finding the live session's goal. This feature does not recover prompts that were already absent before attribution was recorded, and does not address the separate provider-hook-folder cleanup issue.

## Verification

`FlotillaUnitTests/CommitAttributionHooksTests.swift` uses disposable repositories and application-support directories. It covers Off, Local, Shared, repository-hook forwarding and failure, path-specific commits, bypassed hooks, rebases, squash examples, cherry-picks, local rewrites, timestamp collisions with different patches, ingestion retry, prompt newlines, multi-repository snapshots, and local deletion.

Run with an isolated test host:

```sh
TEST_RUNNER_UI_TESTING=1 xcodebuild -project Flotilla.xcodeproj -scheme Flotilla \
  -configuration Debug -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  test -only-testing:FlotillaUnitTests/CommitAttributionHooksTests \
  -only-testing:FlotillaUnitTests/CommitAttributionPersistenceTests \
  -only-testing:FlotillaUnitTests/ProjectHistoryViewModelTests
```
