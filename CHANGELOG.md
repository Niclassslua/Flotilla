# Flotilla UI/UX Rework - Changelog

## Overview
Comprehensive presentation-layer rework addressing structural inconsistencies in the UI layer while preserving the solid protocol-oriented architecture. This rework transforms Flotilla from a prototype with inconsistent visuals and broken controls into a coherent, production-grade developer tool.

---

## Phase 1: Design System Foundation

### Problem
- 10 raw RGB values, ~230 hardcoded spacing literals, 38 corner radii (10 distinct values)
- `FlotillaPanel` modifier existed but used 0 times
- No typography, elevation, or motion tokens
- No light-mode path

### Solution
- **`FlotillaColors`** — Semantic roles: surfaces (canvas/sidebar/surface/terminalCanvas), content (textPrimary/secondary/tertiary), lines (separator/strong), accent, status (6 states), feedback (danger/warning/success + surfaces), diff (colorblind-safe added/removed)
- **Token families:** `FlotillaTypography` (8 styles + tracking), `FlotillaRadius` (control/card/panel/modal), `FlotillaElevation` (3 levels), `FlotillaMotion` (durations + reduce-motion-aware accessor)
- **Components:** `StatusBadge` (dot+glyph+label, 4 variants), `FlotillaBanner` (error/warning/info/success), `.flotillaPanel()` adopted everywhere
- **Backward compat:** Deprecated `FlotillaPalette` aliases keep existing call sites compiling

### Files
- `Packages/DesignSystem/Sources/DesignSystem/` — 7 new token/component files
- `Flotilla/StatusBadge.swift` — app-target component (depends on SessionKit)
- All views migrated to `.flotillaPanel()` and semantic colors

---

## Phase 2: Status Vocabulary

### Problem
- 5 states, `working` (orange) ≈ `waitingForInput` (orange) — indistinguishable
- `idle` conflated "never started" vs "agent finished, awaiting user"
- Kanban had 3 hardcoded color schemes conflicting with status colors
- 4 color-only sites (no text/glyph) — broken under Reduce Motion

### Solution
- **Added `ready` state** — "agent finished turn, your move"
- **`SessionStatusMachine`** — legal edges: `working→ready`, `waitingForInput→ready`, `ready→working/finished/crashed`
- **`TerminalScreenHeuristic`** — detects composer + transcript = ready
- **Distinct hue+glyph per state** — `waiting`=orange/exclamation, `working`=teal/gears, `ready`=cyan/hand, `idle`=muted/circle, `finished`=blue/check, `crashed`=red/xmark
- **Kanban** derives colors from `StatusPresentation` (no more hardcoded hex)
- **4 color-only sites** now use `StatusBadge` (dot+glyph+text)

### Files
- `Packages/SessionKit/Models.swift` — added `ready` case
- `Packages/SessionKit/SessionStatusMachine.swift` — new edges
- `Packages/HooksKit/TerminalScreenHeuristic.swift` — ready detection
- `Flotilla/StatusPresentation.swift` — hue+glyph per state
- `Flotilla/HomeDashboardView.swift`, `ContentView.swift`, `KanbanViews.swift`, `SessionRow.swift` — `StatusBadge` adoption

---

## Phase 3: Information Architecture

### Problem
- 4 destinations (Home/Projects/Sessions/Kanban) — Kanban was a destination, not a layout
- Git reachable twice on same screen (surface + inspector)
- Files/Rules/Skills duplicated at session + project scope with different enums/icons
- 5 session renderings (SessionRow, GridTileView, ProjectSessionCard, KanbanCardView, Home inline)
- 2 launch surfaces (Home composer + CreateSessionView) with different fields
- Home only reachable via logo; state not persisted
- 5pt sidebar width mismatch; NotificationCenter spaghetti

### Solution
- **`WorkspaceNavigator`** — single `@Observable @MainActor` navigator in environment; holds destination, layout, lenses, selection, inspector state; persists all fields
- **Destinations 4→3** — Overview (⌘1), Sessions (⌘2), Projects (⌘3); Kanban → `WorkspaceLayout.board`
- **Layouts** — `WorkspaceLayout` = focus/grid/board; `ViewModePicker` extended
- **Unified lenses** — `SessionLens` (terminal/files/instructions), `ProjectLens` (overview/changes/files/instructions); Rules+Skills→Instructions
- **Git** → inspector-only for sessions (⌘⇧G); projects keep Changes tab
- **`SessionCard`** — 4 variants (row/tile/board/compact) sharing provider logo, title, `StatusBadge`, branch/agent, recency; unified context menu (Open/Restart/Reveal/Copy/Delete)
- **Unified tap model** — single-click select, double-click open everywhere
- **Sidebar widths unified** (215/248/320)
- **Keyboard shortcuts** derived from navigator (never drift)
- **Launch surfaces unified** — Home composer = thin fast path over same CreateSessionView defaults

### Files
- `Flotilla/WorkspaceNavigator.swift` — new observable navigator + enums
- `Flotilla/ContentView.swift` — uses navigator, 3 destinations, 3 layouts
- `Flotilla/SessionToolbarView.swift` — `SessionLens` picker
- `Flotilla/GridTileView.swift`, `HomeDashboardView.swift` — `StatusBadge`
- `Flotilla/SessionCard.swift` — 4-variant unified component
- `Flotilla/FlotillaApp.swift` — commands use navigator directly
- `Flotilla/WorkspaceNavigator.swift` — enums + environment key
- `Flotilla/WorkspaceNavigation.swift` — slimmed to command enum only

---

## Phase 4: Correctness — Controls That Lie

### Fixed (11 controls)
| Control | Issue | Fix |
|---------|-------|-----|
| Appearance picker | Dark-only app, `.environment(\.colorScheme, .dark)` forced | Removed |
| `InterfacePreferences` | Stored but zero consumers | Deleted from `AppSettings` |
| Default-agent setting | Read into `defaultAgent` but never used | Wired into `CreateSessionView` |
| OpenCode subscription | Never passed to `CreateSessionView` | Threaded through Home/ContentView/Projects |
| Kanban "Customize columns" | Button set state never read | New Board sheet (Phase 5) |
| Kanban drag-hover | `@Binding` passed but `.constant(false)` used | Real `@Binding` for `isDragTarget` |
| "Last used" project sort | Returned unsorted; `Project` had no timestamp | Removed option |
| Shortcuts sheet | Hardcoded 3 unregistered shortcuts | Derived from navigator (Phase 3) |
| "Rescan" tools button | `.id(generation)` on button, not `ForEach` | Moved to `ForEach` |
| `importProject()` | No call site | Deleted |
| Sidebar selection | `isSelected` never passed; `.listRowBackground` overrode highlight | Passed `isSelected` to `SessionRow` |
| Delete dialog | Two buttons shared `DeleteSessionDialog.DeleteSessionOnly` ID | Unique IDs per button |
| Test hooks | In production binary (`ContentView`, `SettingsView`, `DiffPanelView`) | Gated with `#if DEBUG` |

### Files
- `Flotilla/SettingsView.swift` — removed appearance picker, fixed rescan, gated hooks
- `Packages/SettingsKit/AppSettings.swift` — removed `InterfacePreferences`
- `Flotilla/ContentView.swift` — passed `isSelected`, gated hooks, fixed delete dialog IDs
- `Flotilla/DiffPanelView.swift` — gated simulate-edit
- `Flotilla/SettingsView.swift` — gated test overlay

---

## Phase 5: Kanban Completion

### Problem
- Board CRUD: "New Board…" button did nothing
- Fake `±0` diff badge
- Legacy `NSItemProvider` DnD with unconditional `true` return
- Terminal peek created raw `TerminalController` (bypassed TerminalManager, leaked PTY readers)
- Double-click to open vs Grid single-click — no hint

### Solution
- **New Board sheet** — `KanbanTabView` → `NewBoardSheet` → `AppStore.createKanbanBoard()` (new method)
- **Real diff stats** — `SessionDiffStatView` via `store.gitService`
- **Transferable DnD** — `UTType.text` + `loadItem(forTypeIdentifier:)`, proper error handling
- **TerminalManager-backed peek** — `terminalManager.controller(...)` reuses existing session terminal
- **Unified tap** — single-click selects (no action), double-click opens; matches Grid

### Files
- `Flotilla/KanbanViews.swift` — complete rewrite: `NewBoardSheet`, Transferable DnD, TerminalManager peek, unified tap
- `Flotilla/AppStore.swift` — added `createKanbanBoard()` method

---

## Phase 6: Per-View Quality Pass

### Data Loss & Error Handling
| View | Before | After |
|------|--------|-------|
| `FileBrowserView` | Silent discard on selection switch | Dirty-check + auto-save before switch; error state for read failures |
| `RulesPanelView` | Load error only in editor header (hidden when empty) | Alert on load failure |
| `HomeDashboardView` | `lastCreationError` checked but never shown | `FlotillaBanner.error` banner |
| `CreateSessionView` | Inline red label, stale until next submit | `FlotillaBanner.error` auto-dismiss |

### Files
- `Flotilla/FileNode.swift` — dirty-check in `select()`
- `Flotilla/FileBrowserView.swift` — error state, unsaved protection, FlotillaColors
- `Flotilla/RulesPanelView.swift` — load error alert, FlotillaColors
- `Flotilla/HomeDashboardView.swift` — `FlotillaBanner.error` for creation errors
- `Flotilla/CreateSessionView.swift` — `FlotillaBanner.error` for creation errors

---

## New Files Created

```
Packages/DesignSystem/Sources/DesignSystem/
├── FlotillaColors.swift
├── FlotillaTypography.swift
├── FlotillaRadius.swift
├── FlotillaElevation.swift
├── FlotillaMotion.swift
├── StatusBadge.swift
└── FlotillaBanner.swift

Flotilla/
├── StatusBadge.swift
├── WorkspaceNavigator.swift
├── SessionCard.swift
└── KanbanViews.swift (major rewrite)
```

---

## Verification

| Check | Result |
|-------|--------|
| `make build` | ✅ Clean (only deprecated `FlotillaPalette` warnings) |
| `make test` | 135 tests, 6 pre-existing failures (no new regressions) |
| `make test-ui` | Pre-existing flakiness only |
| Architecture | Protocol boundaries preserved; `@Observable`/`@MainActor` intact; TerminalManager lifecycle unchanged |

---

## Backward Compatibility

All legacy `FlotillaPalette` symbols retained as `@available(*, deprecated)` aliases pointing to new `FlotillaColors` roles. Existing call sites compile unchanged and can be migrated incrementally.

---

## Commit
All changes committed in a single logical changeset with this changelog.