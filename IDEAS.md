# Flotilla — Feature & Improvement Ideas Roadmap

> Comprehensive tracking of research findings, recent implementations, and prioritized ideas for Flotilla.

---

## 1. Recently Implemented Milestones (Status Check)

The following items from earlier reviews and explorations have already been implemented:

- [x] **Git Write Path & GitHub PRs** (`73466d5`): Full staging, unstaging, discarding, committing, auto-upstream pushing, and GitHub CLI PR creation in `DiffPanelView`.
- [x] **Claude Code Structured Hooks** (`73466d5`): `HookConfigurationWriter` & `HookEventReceiver` in `HooksKit` configuring hooks in `.claude/settings.json` and tailing status events alongside screen heuristics.
- [x] **Interactive Notifications** (`73466d5`): `FlotillaNotificationDelegate` with inline "Reply" straight to session PTY, deep-linking, and `notifySessionFinished` wired via `AppStore.onSessionFinished`.
- [x] **Git Log & Commit History Browser** (Recent Working Tree):
  - `GitKit` ASCII-delimited log parser (`GitCommit`, `GitCommitRef`, `GitCommitFileChange`, `GitCommitDetail`, `GitDiffStat`).
  - `ProjectDetailView` mode switcher (`Worktrees` ↔ `History`).
  - `ProjectHistoryView` with date grouping, full-text search, ref filtering, unpushed badges, and pagination.
  - `CommitDetailView` with author/committer attribution, clickable parent traversal, file status chips, and line-by-line unified diff hunk rendering (`CommitHunkView`).

---

## 2. Priority 1 — High-Leverage Quick Wins & Bug Fixes

### A. Inline Hunk Viewer in `DiffPanelView`
- **Context:** `CommitDetailView` now has a dedicated `CommitHunkView` for commit patches, but the live session `DiffPanelView` still only shows file names and `+N −M` counts.
- **Action:** Allow expanding any staged, unstaged, or untracked file in `DiffPanelView` to render its hunks using `CommitHunkView` (or a shared `DiffHunkView`), providing immediate visibility into uncommitted agent edits.
- **Files:** `Flotilla/DiffPanelView.swift`, `Flotilla/CommitDetailView.swift`.

### B. File Browser Markdown Editing
- **Context:** In `FileBrowserView`, files with `.md` / `.markdown` / `.mdx` extensions render a read-only `Text(AttributedString(...))` view inside what looks like an editor container. The "Save" button writes `viewModel.content`, which cannot be mutated in that view.
- **Action:** Render markdown files with `SyntaxHighlightedFileEditor` (with markdown syntax highlighting), and optionally offer a segmented toggle between "Source" and "Rendered Preview".
- **Files:** `Flotilla/FileBrowserView.swift`.

### C. Remove Dead Code & Restore Motion Pulse
- **Context:** `SessionRow.swift` is dead code superseded by `SessionCard(variant: .row)` in `FleetSidebar.swift`, but `SessionRow` contained a reduce-motion-aware pulsing status beacon that was lost during migration.
- **Action:** Delete `SessionRow.swift` and ensure `SessionCard` retains the pulse effect on active sessions.
- **Files:** `Flotilla/SessionRow.swift`, `Flotilla/FleetSidebar.swift`.

### D. Kanban Session Actions & Project Scoping
- **Context:** `KanbanColumnView` currently uses empty closures for `onDelete` and `onRestart`, preventing session actions from the board view. In addition, `NewBoardSheet` / `createKanbanBoard` support a `projectID`, but the board picker provides no UI to scope new boards to a specific project.
- **Action:** Wire up real delete and restart handlers in `KanbanColumnView`, and add a project selector when creating new Kanban boards.
- **Files:** `Flotilla/KanbanColumnView.swift`, `Flotilla/KanbanBoardView.swift`, `Flotilla/NewBoardSheet.swift`.

### E. Consolidate Session Creation Forms
- **Context:** `CreateSessionView` and `SessionLaunchForm` independently reimplement goal/agent/model/effort selectors and title-truncation rules with slight inconsistencies in worktree toggle visibility.
- **Action:** Refactor into a single shared `SessionCreationForm` component used by sheets, inline views, and quick-launch modals.
- **Files:** `Flotilla/CreateSessionView.swift`, `Flotilla/SessionLaunchForm.swift`.

---

## 3. Priority 2 — Multi-Session Orchestration & Fleet Control

### A. Multi-Selection & Batch Fleet Actions
- **Context:** Grid, Kanban, and Sidebar only support selecting a single active session at a time.
- **Action:**
  - Add multi-selection support (Cmd-click, Shift-click, drag/marquee selection in Grid).
  - Add a floating bulk action bar when multiple sessions are selected (e.g., "Restart All (3)", "Terminate All (3)", "Delete All (3)", "Move to Column").
- **Files:** `Flotilla/GridView.swift`, `Flotilla/KanbanBoardView.swift`, `Flotilla/FleetSidebar.swift`, `Flotilla/AppStore.swift`.

### B. Live Terminal / Activity Preview on Kanban Cards
- **Context:** `SessionCard(variant: .board)` reserves layout space for terminal output previews, but is currently passed `activityStore: nil` and `terminal: { EmptyView() }`.
- **Action:** Pass the active terminal snapshot or activity buffer to board cards with lazy viewport-based rendering.
- **Files:** `Flotilla/KanbanBoardView.swift`, `Flotilla/SessionCard.swift`.

### C. Adaptive Activity Polling
- **Context:** The Home screen enforces a static budget of 6 sessions to bound polling cost, leaving sessions beyond the 6th without live activity indicators. The Attention Queue is similarly capped at 5 items without a "View All" option.
- **Action:**
  - Implement adaptive, visibility-based polling that prioritizes sessions currently in the viewport or in `waitingForInput` / error states.
  - Add a "View All" sheet/navigation destination for the Attention Queue.
- **Files:** `Flotilla/Home/HomeDashboardView.swift`, `Flotilla/AppStore.swift`.

### D. Focus Mode Entry Point
- **Context:** `WorkspacePresentation.focus` exists and has a keyboard shortcut (`⌘⌃1`), but the main `WorkspaceToolbar` mode picker only displays Grid, Board, and List.
- **Action:** Add Focus mode to `WorkspaceToolbar` or show it conditionally when a session is selected.
- **Files:** `Flotilla/WorkspaceToolbar.swift`.

---

## 4. Priority 3 — Agent Parity & Hook Expansion

### A. Codex CLI Native `notify` Hook Wiring
- **Context:** Claude Code uses native hook JSON files to report status transitions directly (`HookConfigurationWriter`). Codex CLI also supports a native `notify` hook mechanism, but Flotilla currently falls back to regex substring heuristics (`TerminalScreenHeuristic`) for Codex.
- **Action:** Mirror the `HookConfigurationWriter` & `HookEventReceiver` architecture for Codex CLI, configuring Codex's native notification dispatching on session launch.
- **Files:** `Packages/HooksKit/Sources/HooksKit/`, `Packages/AgentKit/Sources/AgentKit/`.

### B. Dynamic Model Catalog Refresh
- **Context:** Model catalogs discovered via CLI tools are cached for the lifetime of the process. Updating an agent CLI requires restarting Flotilla to reflect newly supported models.
- **Action:** Add a "Rescan Models" button adjacent to the Agent / Model pickers in session creation and Settings.
- **Files:** `Packages/AgentKit/Sources/AgentKit/ModelCatalogFetcher.swift`, `Flotilla/CreateSessionView.swift`, `Flotilla/SettingsView.swift`.

---

## 5. Priority 4 — Settings, File Browser & Rules Polish

### A. Advanced Diagnostics & Reset
- **Context:** The "Advanced" tab in Settings currently displays static copy with no interactive diagnostic tools.
- **Action:** Add "Export Diagnostic Logs", "Clear Terminal Cache", and "Reset to Default Settings" buttons.
- **Files:** `Flotilla/SettingsView.swift`, `Packages/SettingsKit/Sources/SettingsKit/`.

### B. Persist Startup Warning Dismissals
- **Context:** If optional tools (like `tmux` or `gh`) are missing, the warning banner reappears on every launch even after dismissal, with no inline "Recheck" action.
- **Action:** Persist dismissed tool warning keys in `UserDefaults` / `AppSettings` and add an inline "Check Again" button to the banner.
- **Files:** `Flotilla/AppEnvironment.swift`, `Flotilla/ContentView.swift`.

### C. File Browser Enhancements
- **Context:** The file browser lacks filtering, file lifecycle operations (create/rename/delete), and debounced syntax highlighting on large files.
- **Action:**
  - Add a lightweight search/filter bar to the file tree.
  - Add context-menu actions for "New File", "Rename", and "Delete".
  - Debounce the regex syntax highlighting in `SyntaxHighlightedTextEditor`.
- **Files:** `Flotilla/FileBrowserView.swift`, `Flotilla/SyntaxHighlightedTextEditor.swift`.

### D. Appearance / Theme Cleanup
- **Context:** `AppearanceSettingsPane` is fully written and `AppSettings.appearance` is persisted, but the tab is commented out in Settings and the app forces dark mode.
- **Action:** Either complete and enable dynamic light/dark/system mode switching throughout all color tokens, or clean up the unused appearance settings code.
- **Files:** `Flotilla/SettingsView.swift`, `Packages/SettingsKit/Sources/SettingsKit/AppSettings.swift`, `Packages/DesignSystem/Sources/DesignSystem/FlotillaPalette.swift`.
