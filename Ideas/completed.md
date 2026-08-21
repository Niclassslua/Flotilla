# Completed Milestones

Status check of items from earlier reviews and explorations that have since shipped.

- [x] **Git Write Path & GitHub PRs** (`73466d5`): Full staging, unstaging, discarding, committing, auto-upstream pushing, and GitHub CLI PR creation in `DiffPanelView`.
- [x] **Claude Code Structured Hooks** (`73466d5`): `HookConfigurationWriter` & `HookEventReceiver` in `HooksKit` configuring hooks in `.claude/settings.json` and tailing status events alongside screen heuristics.
- [x] **Interactive Notifications** (`73466d5`): `FlotillaNotificationDelegate` with inline "Reply" straight to session PTY, deep-linking, and `notifySessionFinished` wired via `AppStore.onSessionFinished`.
- [x] **Git Log & Commit History Browser** (Recent Working Tree):
  - `GitKit` ASCII-delimited log parser (`GitCommit`, `GitCommitRef`, `GitCommitFileChange`, `GitCommitDetail`, `GitDiffStat`).
  - `ProjectDetailView` mode switcher (`Worktrees` ↔ `History`).
  - `ProjectHistoryView` with date grouping, full-text search, ref filtering, unpushed badges, and pagination.
  - `CommitDetailView` with author/committer attribution, clickable parent traversal, file status chips, and line-by-line unified diff hunk rendering (`CommitHunkView`).
