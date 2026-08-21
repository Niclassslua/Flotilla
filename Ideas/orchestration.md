# Priority 2 — Multi-Session Orchestration & Fleet Control

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
