# Flotilla UI Vocabulary

A shared naming reference for talking about Flotilla's interface. Every entry gives
the **name to say** (in a prompt, an issue, a review comment), what it actually is on
screen, and the **type / file** it maps to in code.

The rule behind the names: **the spoken name is the type name, spaced out.** Saying
"the session tile surface" should be enough for an agent to `grep SessionTileSurface`
and land on the right file. Where a screen region has no single type (e.g. "the detail
column's toolbar area"), the name below is the canonical one — prefer it over inventing
a new one.

> Names marked **(region)** describe a *place* in the window rather than one type.
> Names marked **(variant)** are a mode of a shared type, not a separate view.

---

## 1. Window shell

The outermost layout. Everything else lives inside one of these three regions.

| Say | What it is | Code |
| --- | --- | --- |
| **Shell** | The whole window's root view: rail + split view + overlays + sheets. | `FlotillaShell` — `Features/Shell/FlotillaShell.swift` |
| **Sidebar rail** *(or just "the rail")* | The narrow fixed-width icon column pinned to the leading edge: Overview, Sessions, and the New button at its foot. Sits **outside** the split view. | `SidebarRail` — `Features/Shell/FleetSidebar.swift` |
| **Session list** *(or "the sidebar column")* | The split view's sidebar column: projects as sections, sessions as rows, with the search field on top. Only shown in the Sessions facet. | `FleetSessionList` — same file |
| **Session sidebar row** | One session line in the session list (status dot, title, meta, swipe-to-delete, context menu). | `SessionSidebarRow`, `SwipeToDeleteSession` — same file |
| **Detail column** *(region)* | The large right-hand area. Switches content by sidebar selection: Home dashboard, session terminal, project workspace, or a fleet presentation. | `DetailColumn` — `Features/Shell/DetailColumn.swift` |
| **Workspace toolbar** | The window toolbar: presentation picker (principal), session Git/Files jump buttons, grid controls, command palette, settings. | `WorkspaceToolbar` — `Features/Shell/WorkspaceToolbar.swift` |
| **Banner stack** *(region)* | The strip inset at the top of the detail column holding the startup warning and the operation error banner. | `DetailColumn.banners` |
| **Startup warning banner** | "Missing tools" warning shown after the startup check. | `StartupWarningBanner` — `Features/Settings/` |
| **Operation error banner** | Red dismissible bar for the last failed store operation. | `OperationErrorBanner` — `Features/Shell/DetailColumn.swift` |
| **Empty workspace view** | "Choose a session" / "Your agents, in formation" placeholder when nothing is selected. | `EmptyWorkspaceView` — same file |

### Navigation words

These are the terms for *state*, not views — use them to say **where** you want a change to apply.

| Say | Meaning | Code |
| --- | --- | --- |
| **Facet** | Which rail item is active: Overview or Sessions. | `SidebarFacet` |
| **Selection** | What the detail column is showing: `.overview`, `.allSessions`, `.project(id)`, `.session(id)`. | `SidebarItem` |
| **Presentation** | How the fleet is rendered in the Sessions facet: **Grid**, **Board**, or **Focus**. | `WorkspacePresentation` |
| **Scope** | Shorthand for a selection kind — "fleet scope", "session scope", "project scope". | — |
| **Sheet** | A modal presentation: New Session, command palette, shortcuts, restore, delete. Note the first two render as in-window **overlays** with a dismissible scrim, the rest as real AppKit sheets. | `WorkspaceSheet` |

---

## 2. Home / Overview

Shown when the rail is on **Overview** and no project is drilled into.

| Say | What it is | Code |
| --- | --- | --- |
| **Home dashboard** | The whole scrolling Overview page: hero, composer, fleet sections, harbor gradient background. | `HomeDashboardView` — `Features/Home/` |
| **Hero title** | The big Flotilla wordmark + fleet stats at the top. | `FlotillaHeroTitleView` |
| **Composer** *(or "the launchpad")* | The always-visible session composer card on Home — agent cards, model controls, project tiles, goal field, isolation switch. | `LaunchpadDesign` — `Features/CreateSession/Designs/` |
| **Attention queue** | The "needs you" section: sessions that can't progress without a human. Renders nothing when the fleet is healthy. | `HomeAttentionQueue` / `HomeAttentionRow` |
| **Recent sessions list** | The most-recently-active sessions, with live telemetry. | `HomeRecentSessionsList` / `HomeSessionRow` |
| **Projects gallery** | The grid of project tiles at the foot of Home. | `HomeProjectsGallery` |
| **Fleet bar** | The horizontal status histogram — one segment per status, width by count. | `HomeFleetBar` |
| **Fleet legend** | The count + label pairs under/next to the fleet bar. | `HomeFleetLegend` |
| **Activity line** | The agent's most recent terminal line, shown on live sessions only. | `HomeActivityLine` |
| **Section header** (home) | The "Needs You" / "Recent" / "Projects" headers. | `HomeSectionHeader`, `HomeEmptyHint` |

---

## 3. Fleet presentations (Sessions facet)

Three ways to render many sessions; picked in the toolbar's presentation picker.

### Grid

| Say | What it is | Code |
| --- | --- | --- |
| **Grid** | The tiled-terminals presentation. Owns which sessions are visible, their order, and per-tile actions. | `GridView` — `Features/Grid/` |
| **Mission control grid** | The concrete grid layout: uniform tiles, one 28pt chrome bar each, terminal-dominant. | `MissionControlGrid` / `MissionControlTile` |
| **Session tile** | One cell of the grid. | `MissionControlTile` |
| **Tile surface** | The tile's card background, border, context menu and drag source. The border colour carries status. | `SessionTileSurface` (a `ViewModifier`) — `SessionTileChrome.swift` |
| **Tile title lockup** | Status dot + title + provider mark, truncating in priority order. | `TileTitleLockup` |
| **Tile meta row** | Branch · diff stat · elapsed time, on one line. | `TileMetaRow` |
| **Tile focus button** | The button that opens a tile full-screen. | `TileFocusButton` |
| **Tile terminal body** | The live terminal inside a tile (or its stopped placeholder). | `TileTerminalBody` |
| **Grid dimensions picker** | The toolbar swatch for choosing columns × rows. | `GridDimensionsPicker` / `GridDimensionsSwatch` |
| **Grid toolbar controls** | Add-all, empty, and dim controls next to the dimensions picker. | `GridAddAllButton`, `GridEmptyButton`, `GridDimControl` |
| **Grid membership** | Which sessions are assigned to the grid. While the grid is on screen, clicking a sidebar row **toggles membership** rather than opening the session. | `GridSelection`, `GridSidebarSelection` |

### Board

| Say | What it is | Code |
| --- | --- | --- |
| **Board** *(or "Kanban board")* | The Kanban presentation with its own header bar and board picker. | `KanbanTabView` → `KanbanBoardView` — `Features/Projects/KanbanViews.swift` |
| **Kanban column** | One column of the board. | `KanbanColumnView`, `AddColumnButton` |
| **Kanban card** | A session rendered as a board card. | `SessionCard` in the `.board` variant |
| **New board sheet** / **New column sheet** | The two creation dialogs. | `NewBoardSheet`, `NewColumnSheet` |

### Focus

| Say | What it is | Code |
| --- | --- | --- |
| **Focus** | Single-session presentation: one full-size terminal filling the detail column. | `DetailColumn.focusedSessionContent` |
| **Terminal host** | The SwiftUI wrapper around the real terminal renderer. | `TerminalHostView` — `Features/Session/` |
| **Terminal presentation** | `.session` (focus) vs `.grid` (tile) rendering mode of the terminal. | `TerminalPresentation` (TerminalKit) |

---

## 4. Session card variants

**One type, four looks.** Say "the session card, board variant" — not "the board card component".

| Say | Where it appears | Variant |
| --- | --- | --- |
| **Session card — row** | Sidebar session list | `.row` |
| **Session card — tile** | Grid tiles | `.tile` |
| **Session card — board** | Kanban cards | `.board` |
| **Session card — compact** | Dense lists (project overview, home) | `.compact` |

Type: `SessionCard<Terminal>` — `Features/Session/SessionCard.swift`.

---

## 5. Project workspace

Reached by selecting a project (rail → Overview → a project tile, or the sidebar).

| Say | What it is | Code |
| --- | --- | --- |
| **Project detail** | The whole project workspace: header, mode tabs, tab content. | `ProjectDetailView` — `Features/Projects/` |
| **Project header** | Name, branch, diff stat, and actions above the tabs. | `ProjectDetailView.projectHeader` |
| **Mode tabs** | The five-tab strip: **Overview · Git · Files · Skills · Rules**. | `ProjectDetailView.ProjectTab` |
| **Project overview tab** | Active sessions, worktrees, recent sessions. | `ProjectOverviewView` |
| **Worktree section** | The worktree list — used both by the overview tab and by Git's worktree-scoped Changes. | `ProjectWorktreeSection` |
| **Git tab** | Hosts the sub-tab bar and the scope picker. | `ProjectGitView` |
| **Git sub-tabs** | **Changes** and **Commits**, inside the Git tab. | `ProjectGitView.GitSubTab` |
| **Scope picker** | The control choosing which worktree/checkout the Git tab is looking at. | `ProjectGitView.scopePicker` |
| **Files tab** | The file browser for the project root. | `FileBrowserView` |
| **Skills tab** / **Rules tab** | Thin hosts over the shared knowledge catalog. | `ProjectSkillsView`, `ProjectRulesView` |
| **Project command card** | The dense project card (live branch, diff stats, agent telemetry, Quick Launch / Terminal / Editor / Finder shortcuts). | `ProjectCommandCard` |
| **Project mark** | The project's generated identity glyph. | `ProjectMark` |
| **Project path sheet** | The add/relocate-a-project dialog. | `ProjectPathSheet` |

### Commit graph & history

| Say | What it is | Code |
| --- | --- | --- |
| **Commit graph** *(or "the graph view")* | The commit DAG drawn as lanes beside a commit table and a detail inspector. `ProjectHistoryView` is an alias of it. | `ProjectGraphView` |
| **Graph commit row** | One commit line in the table. | `GraphCommitRow` |
| **Lane painter** | The branch-topology drawing to the left of the rows. | `GraphLanePainter` |
| **Branch chip** / **ref chip** | Capsule decorations for branch, remote, or tag. | `GraphBranchChip`, `CommitRefChip` |
| **Commit detail** | The right-hand pane: identity, decoration, touched files, patch. | `CommitDetailView`, `CommitFileRow`, `CommitHunkView` |

### Knowledge catalog (Skills & Rules)

| Say | What it is | Code |
| --- | --- | --- |
| **Knowledge catalog** | The shared host behind both the Skills and Rules tabs: header bar, loading states, ledger + docked inspector. | `KnowledgeCatalogView` — `Features/Projects/Knowledge/` |
| **Ledger** | The dense table with hairline dividers, compact rows, and keyboard navigation. | `LedgerDesign` / `LedgerRow` |
| **Knowledge detail** | The read-and-edit pane for one item — Markdown by default, syntax editor on Edit, ⌘S to save. | `KnowledgeDetailView`, `KnowledgeNoSelectionView` |
| **Knowledge chrome** | The catalog's small parts: icon tile, scope/framework/version/tag/invocation chips, metric pill, search field, scope picker, sort menu. | `KnowledgeChrome.swift` |

---

## 6. Diff & files

| Say | What it is | Code |
| --- | --- | --- |
| **Diff panel** | Staging, discard, commit, push, PR — the working-copy review surface. | `DiffPanelView` — `Features/Diff/` |
| **Diff file row** | One changed file in the diff panel, with its discard confirmation. | `DiffFileRow` |
| **Diff stat badge** | The `+n −n` badge. `SessionDiffStatView` is its session-bound wrapper. | `DiffStatBadge`, `SessionDiffStatView` |
| **File browser** | Tree on the left, Monaco editor on the right, with Markdown preview toggle and image/binary handling. | `FileBrowserView` — `Features/FileBrowser/` |
| **File tree** / **editor pane** *(regions)* | The two halves of the file browser. | `AXID.fileBrowserTree`, `.fileBrowserEditor` |
| **Monaco host** | The web-backed code editor view. | `MonacoHostView` — `Features/Session/` |
| **Markdown view** | Rendered Markdown (backed by the Textual package). | `MarkdownView` |
| **Syntax editor** | The syntax-highlighted plain-text editor used for editing rules/skills. | `SyntaxHighlightedTextEditor` |

---

## 7. Launchers & modals

| Say | What it is | Code |
| --- | --- | --- |
| **New Session window** | The modal launcher (⌘N, rail's New button, palette, "fix this commit"). Renders the command bar. | `CreateSessionView` — `Features/CreateSession/` |
| **Command bar** | The Spotlight-style single-field design inside the New Session window: `@` = project search, `/` = agent switch, everything else is the goal. | `CommandBarDesign` |
| **Chip strip** | The row of already-decided values (project, agent, isolation) under the command bar's query row. | `CommandBarDesign.chipStrip` |
| **Summary line** | The dim monospace line stating exactly what will happen on launch (branch name, destination). Both the command bar and the composer render it. | `CommandBarDesign.summaryLine`, backed by the `SessionLaunchPreview` model |
| **Session draft** | The shared editable state behind both the composer and the command bar. | `SessionDraft` |
| **Command palette** | ⌘K launcher for workspace commands, projects, and sessions. | `CommandPaletteView`, `PaletteRow`, `PaletteSectionTitle` |
| **Palette panel** | The borderless floating panel that hosts it (dismisses on click-outside, unlike a sheet). | `CommandPalettePanel` |
| **Shortcuts sheet** | The keyboard-shortcut reference. | `KeyboardShortcutsView` |
| **Restore sheet** | The "restart stopped sessions" dialog. | `RestoreSessionsView` |
| **Delete session sheet** | The delete confirmation, with the keep/delete-worktree choice. | `DeleteSessionSheet` |

---

## 8. Settings

| Say | What it is | Code |
| --- | --- | --- |
| **Settings window** | The whole preferences window. | `SettingsView` — `Features/Settings/` |
| **Settings pane** | One page of settings. Named by its tab: **General, Session, Terminal, Git, Notifications, Agent, Appearance, Project, Environment, Advanced, Shortcuts**. | `…SettingsPane` |
| **Settings sidebar row** | A row in the settings window's own sidebar. | `SettingsSidebarRow` |
| **Settings section header** | The icon + title header inside a pane (e.g. "Worktrees", "Prompt Delivery"). | `SettingsSectionHeader` |
| **Tool status row** | The installed/missing line per external CLI. | `ToolStatusRow` |

---

## 9. Shared components

Small parts reused across screens — `Flotilla/Components/`.

| Say | What it is | Code |
| --- | --- | --- |
| **Status badge** | The pill showing a session's status. Renders **nothing** for a `nil` (unstarted) status. | `StatusBadge` |
| **Status dot** | The bare coloured dot — the compact form of the same status presentation. | `StatusPresentation` |
| **Provider logo** | The real brand mark (Claude, Codex/OpenAI, OpenCode, Antigravity) from vector assets. | `ProviderLogo` |
| **Agent brand** | Fixed per-agent brand colours — deliberately *not* adaptive tokens. | `AgentBrand` |
| **Model picker** | Dropdown of the current agent's live model list plus "Custom…". | `ModelPickerView` |
| **Effort picker** | The reasoning-effort chip + explanatory popover. Renders nothing for agents with no effort knob. | `EffortLevelPicker` |
| **Material file icon** | VS Code Material Icon Theme SVG icon for a path. | `MaterialFileIcon` |

---

## 10. Design system

Tokens and primitives — `Packages/DesignSystem/`. Refer to these by token name, not by value ("use `FlotillaSpacing.large`", not "use 16pt").

| Say | What it is | Code |
| --- | --- | --- |
| **Colors** | Semantic palette: `canvas`, `surface`, `accent`, `terminalCanvas`, `textSecondary`, status colours. | `FlotillaColors` |
| **Spacing / Radius / Border width / Icon size / Control height / Layout width / State opacity** | The scalar token scales. | `FlotillaSpacing`, `FlotillaRadius`, `FlotillaBorderWidth`, `FlotillaIconSize`, `FlotillaControlHeight`, `FlotillaLayoutWidth`, `FlotillaStateOpacity` |
| **Typography** | Font ramp, plus `Tracking` and `Weight`. | `FlotillaTypography` |
| **Motion** | Named curves (e.g. `FlotillaMotion.snappy`). | `FlotillaMotion` |
| **Elevation / shadow** | `.flotillaShadow(.level3)` and friends. | `FlotillaElevation` |
| **Panel** | The standard panel surface modifier. | `FlotillaPanel` |
| **Banner** | The standard inline banner. | `FlotillaBanner`, `FlotillaBannerStyle` |
| **Marquee text** | Scrolling text for overflowing single lines. | `MarqueeText` |

---

## 11. Naming an element for a prompt

If you need to point at something this list doesn't name:

1. **Region + component.** "the *tile meta row* in the *grid*", "the *scope picker* in the *Git tab*".
2. **Reach for the accessibility identifier.** Every testable element has one in `Flotilla/App/AXID.swift`, and the names there are already canonical: `Toolbar.PresentationPicker`, `Knowledge.SortMenu`, `Home.LaunchButton`, `GridTile-<title>-FocusButton`. Quoting an AXID is unambiguous.
3. **Say the variant, don't invent a type.** "the session card in its compact variant", not "the mini session view".

When a name here and the code disagree, the code wins — and this file should be updated
in the same change.
