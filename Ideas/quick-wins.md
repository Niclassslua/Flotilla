# Priority 1 — High-Leverage Quick Wins & Bug Fixes

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
