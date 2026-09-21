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
>
> Destinations, state and layout policy live in [`ui-model.md`](ui-model.md); this file names components.
> Names marked **(variant)** are a mode of a shared type, not a separate view.

---

## 1. Window shell

The outermost layout. Everything else lives inside one of these three regions.

| Say | What it is | Code |
| --- | --- | --- |
| **Shell** | The whole window's root view: `NavigationSplitView` + overlays + sheets. | `FlotillaShell` — `Features/Shell/FlotillaShell.swift` |
| **Navigator** *(region)* | The split view's sidebar column, present in every scope: search on top, then **Home**, then each project as a selectable header with its sessions beneath it, then unassigned sessions, over a pinned **New Session** button. | `SessionsSidebar` — `Features/Shell/FleetSidebar.swift` |
| **Navigator list** | The `List` inside the navigator that holds Home, the projects and their sessions, and General. | `FleetSessionList` — same file |
| **Navigator row** | A standing destination line in the navigator. Home is the only one. | `NavigatorRow` — same file |
| **Project header** | A project's line in the navigator, and the header for its sessions: collapse chevron, 28pt project mark, name, home-relative path, and a hairline in the project's accent. Selecting it opens the project workspace. | `ProjectHeaderRow` — same file |
| **Smart list** | One of the standing fleet questions: **Needs You · Working · Ready**. Reached from the **Workspace** menu; it left the navigator, where its count only restated what every session row already shows. | `FleetSmartList` — `Features/Shell/FleetSmartList.swift` |
| **Session sidebar row** | One session line in the session list (status dot, title, meta, swipe-to-delete, context menu). | `SessionSidebarRow`, `SwipeToDeleteSession` — same file |
| **Detail column** *(region)* | The large right-hand area. Switches content by sidebar selection: Home dashboard, session terminal, project workspace, or a fleet presentation. | `DetailColumn` — `Features/Shell/DetailColumn.swift` |
| **Global bar** | The window toolbar, and the only bar present in every scope: wordmark, back/forward, Grid, Board, command palette, settings. Everything scope-specific moved to a bar that shares that scope's lifetime. | `WorkspaceToolbar` — `Features/Shell/WorkspaceToolbar.swift` |
| **Session group bar** | The in-window bar under the global bar in Sessions: the group chips (All · each project · General) on the left, and — in Grid only — the grid controls on the right. | `SessionGroupBar` — `Features/Shell/SessionGroupBar.swift` |
| **Group chip** | One offer in that bar. Its count is the sessions in that group. | `SessionGroupChip` — same file |
| **Session bar** | What one session *is*, and what you can do to it: `project / name` (the name renames inline), branch, worktree. Two variants, below. | `SessionBar` — `Features/Session/SessionBar.swift` |
| **Banner stack** *(region)* | The strip inset at the top of the detail column holding the startup warning and the operation error banner. | `DetailColumn.banners` |
| **Startup warning banner** | "Missing tools" warning shown after the startup check. | `StartupWarningBanner` — `Features/Settings/` |
| **Operation error banner** | Red dismissible bar for the last failed store operation. | `OperationErrorBanner` — `Features/Shell/DetailColumn.swift` |
| **Empty workspace view** | "Choose a session" / "Your agents, in formation" placeholder when nothing is selected. | `EmptyWorkspaceView` — same file |

### Navigation words

These are the terms for *state*, not views — use them to say **where** you want a change to apply.

| Say | Meaning | Code |
| --- | --- | --- |
| **Scope** | Which subset of the fleet a collection surface renders — a project, a smart list, or everything. Shared by Grid, Board and Focus. | `SessionScope` — `Features/Shell/FleetSmartList.swift` |
| **Selection** | What the detail column is showing: `.overview`, `.allSessions`, `.project(id)`, `.session(id)`. | `SidebarItem` |
| **Presentation** | How the fleet is rendered: **Grid**, **Board**, or **Focus**. Changes *how*, never *what* — that is the scope's job. | `WorkspacePresentation` |
| **Group** | Which slice of the fleet the group bar has lit: **All**, one project, or **General**. One of the two axes of a scope; it survives switching presentation. | `SessionGroup` — `Features/Shell/FleetSmartList.swift` |
| **Scope** | Shorthand for a selection kind — "fleet scope", "session scope", "project scope". | — |
| **Sheet** | A modal presentation: New Session, command palette, shortcuts, restore, delete. Note the first two render as in-window **overlays** with a dismissible scrim, the rest as real AppKit sheets. | `WorkspaceSheet` |

---

## 2. Home / Overview

Shown when the navigator's **Home** row is selected.

| Say | What it is | Code |
| --- | --- | --- |
| **Home dashboard** | The Overview page: a lobby for choosing a project. Greeting, project cards, and activity stats on the warm gradient. Home never creates sessions (⌘N does) and never lists them (the sidebar does). | `HomeDashboardView` — `Features/Home/` |
| **Project card** | A large glass card per project: branch, uncommitted work, unpushed commits, open worktrees, and a one-line session hint ("1 needs you · 2 working"). Its ⋯ / context menu holds the project actions (open in editor, commit attribution, remove). | `HomeProjectCard` |
| **Activity stats** | The section at the foot of Home: contribution heatmap, weekly rhythm, agent share, codebase growth — git history across every project. | `HomeStatsSection` |
| **Home widget grid** | The modular, customizable widget grid on Home displaying active telemetry, trends, and queue stats. | `HomeWidgetGrid` — `Features/Home/Widgets/` |
| **Home widget card** | The glass panel container for a single widget with drag-reorder handle, options menu, and status headers. | `HomeWidgetCard` |
| **Widget gallery sheet** | The modal sheet for browsing, previewing, and adding widgets to the Home dashboard. | `HomeWidgetGallerySheet` |
| **Widget settings popover** | Per-widget configuration menu for selecting time ranges, metrics, and display modes. | `HomeWidgetSettingsPopover` |
| **Widget grid empty state** | The placeholder state inviting the user to customize their dashboard when all widgets are removed. | `HomeWidgetGridEmptyState` |
| **Home insights** | The cached, throttled git reads behind the cards and stats. | `HomeInsights` / `HomeRepoState` / `HomeActivity` |
| **Activity line** | The agent's most recent terminal line, shown on live sessions only. | `HomeActivityLine` |
| **Section header** (home) | The "Needs You" / "Recent" / "Projects" headers. | `HomeSectionHeader`, `HomeEmptyHint` |

---

## 3. Fleet presentations

Three ways to render many sessions; Grid and Board are opened from the global bar.

### Grid

| Say | What it is | Code |
| --- | --- | --- |
| **Grid** | The tiled-terminals presentation. Owns which sessions are visible, their order, and per-tile actions. | `GridView` — `Features/Grid/` |
| **Mission control grid** | The concrete grid layout: uniform tiles, one 28pt chrome bar each, terminal-dominant. | `MissionControlGrid` / `MissionControlTile` |
| **Session tile** | One cell of the grid. | `MissionControlTile` |
| **Tile surface** | The tile's card background, border, context menu and drag source. The border colour carries status. | `SessionTileSurface` (a `ViewModifier`) — `SessionTileChrome.swift` |
| **Tile bar** | The tile's 28pt chrome bar — the session bar in its `.tile` variant. Replaces the former `TileTitleLockup` / `TileMetaRow` / `TileFocusButton` trio. | `SessionBar` (`.tile`) |
| **Tile terminal body** | The live terminal inside a tile (or its stopped placeholder). | `TileTerminalBody` |
| **Grid dimensions picker** | The group bar's swatch for choosing columns × rows. | `GridDimensionsPicker` / `GridDimensionsSwatch` |
| **Grid controls** | Add-all, empty, and dim controls next to the dimensions picker, on the right of the group bar. Add-all fills from the lit group. | `GridAddAllButton`, `GridEmptyButton`, `GridDimControl` |
| **Grid membership** | Which sessions are assigned to the grid. While the grid is on screen, clicking a sidebar row **toggles membership** rather than opening the session. | `GridSelection`, `GridSidebarSelection` |

### Board

| Say | What it is | Code |
| --- | --- | --- |
| **Board** *(or "Kanban board")* | The Kanban presentation. The session group bar is its only session-scope control. | `KanbanTabView` → `KanbanBoardView` — `Features/Projects/KanbanViews.swift` |
| **Kanban column** | One column of the board. | `KanbanColumnView`, `AddColumnButton` |
| **Kanban card** | A session rendered as a board card. | `SessionCard` in the `.board` variant |

### Focus

| Say | What it is | Code |
| --- | --- | --- |
| **Focus** | Single-session presentation: the session bar over one full-size terminal filling the detail column. | `DetailColumn.focusedSessionContent` |
| **Terminal host** | The SwiftUI wrapper around the real terminal renderer. | `TerminalHostView` — `Features/Session/` |
| **Terminal presentation** | `.session` (focus) vs `.grid` (tile) rendering mode of the terminal. | `TerminalPresentation` (TerminalKit) |
| **Session git sidebar** | The collapsible right-hand drawer showing working-copy file status, inline diffs, stage/discard, and commit actions for the current session. | `SessionGitSidebar` — `Features/Session/` |
| **Screenshot panel** | The drawer displaying real-time UI previews and visual tool outputs captured by the agent during its task. | `AgentScreenshotPanel` — `Features/Session/` |

---

## 4. Session card variants

**One type, four looks.** Say "the session card, board variant" — not "the board card component".

| Say | Where it appears | Variant |
| --- | --- | --- |
| **Session card — row** | Sidebar session list | `.row` |
| **Session card — tile** | Grid tiles | `.tile` |
| **Session card — board** | Kanban cards | `.board` |
| **Session card — compact** | Dense lists (project overview, home) | `.compact` |

**The session bar has two**, on the same principle — say "the session bar, tile variant".

| Say | Where it appears | Variant |
| --- | --- | --- |
| **Session bar — focus** | Above a full-size session terminal | `.focus` |
| **Session bar — tile** | Each grid tile's chrome bar | `.tile` |

Type: `SessionBar` — `Features/Session/SessionBar.swift`.

Type: `SessionCard<Terminal>` — `Features/Session/SessionCard.swift`.

---

## 5. Project workspace

Reached by selecting a project's row in the navigator, or a project tile on Home.

| Say | What it is | Code |
| --- | --- | --- |
| **Project detail** | Thin entry point: builds the workspace context and renders the Stream workspace. | `ProjectDetailView` — `Features/Projects/` |
| **Project workspace** *(or "the Stream")* | The whole project surface: a masthead over a two-region body — the activity feed on the left, the context column on the right. Git / Files / Skills / Rules render through it under a return breadcrumb. | `StreamProjectWorkspace` — `Features/Projects/Workspaces/` |
| **Masthead** | The `surface`-banded header: project mark, name, path, the monospace **instrument row** (branch · drift · working-copy delta · commits/wk), and the surface links. | `StreamProjectWorkspace.masthead` |
| **Surface links** | The **Git · Files · Skills · Rules** row in the masthead; each carries the `ProjectDetail.ModeTab-<Title>` identifier. The surface model is still `ProjectDetailView.ProjectTab`. | `StreamProjectWorkspace.surfaceNav` |
| **Activity feed** | The centred timeline: sessions and recent commits interleaved by recency down a spine, day-banded, with hero rows for live / waiting / ready sessions and an "earlier commits" footer. | `StreamProjectWorkspace.feed` / `timeline` |
| **Context column** | The full-height right panel: **Worktrees** (list + show-all), **Working tree** (diff / branch / ahead → Git), **This week** (commits / sessions / churn). | `StreamProjectWorkspace.contextColumn` |
| **Surface return bar** | The `← Overview / Git` breadcrumb shown above a routed-through surface. | `SurfaceReturnBar` — `Workspaces/ProjectWorkspaceChrome.swift` |
| **Git tab** | Hosts the sub-tab bar and the scope picker. | `ProjectGitView` |
| **Git sub-tabs** | **Changes** and **Commits**, inside the Git tab. | `ProjectGitView.GitSubTab` |
| **Scope picker** | The control choosing which worktree/checkout the Git tab is looking at. | `ProjectGitView.scopePicker` |
| **Files tab** | The file browser for the project root. | `FileBrowserView` |
| **Skills tab** / **Rules tab** | Thin hosts over the shared knowledge catalog. | `ProjectSkillsView`, `ProjectRulesView` |
| **Project command card** | The dense project card (live branch, diff stats, agent telemetry, Quick Launch / Terminal / Editor / Finder shortcuts). | `ProjectCommandCard` |
| **Project mark** | The project's generated identity glyph. | `ProjectMark` |
| **Project icon picker sheet** | The modal sheet for selecting an icon symbol, color, or custom image for a project. | `ProjectIconPickerSheet` — `Features/Projects/` |
| **Project icon cropper** | The interactive cropping and framing view for adjusting custom image avatars. | `ProjectIconCropperView` — `Features/Projects/` |
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
| **Elapsed** | A session's age in single-unit shorthand (`45s`, `12m`, `3h`, `2d`), shared by the session bar and the cards. | `SessionElapsed` — `Components/SessionElapsed.swift` |
| **File browser** | Tree on the left, Monaco editor on the right, with Markdown preview toggle and image/binary handling. | `FileBrowserView` — `Features/FileBrowser/` |
| **File tree** / **editor pane** *(regions)* | The two halves of the file browser. | `AXID.fileBrowserTree`, `.fileBrowserEditor` |
| **Monaco host** | The web-backed code editor view. | `MonacoHostView` — `Features/Session/` |
| **Markdown view** | Rendered Markdown (backed by the Textual package). | `MarkdownView` |
| **Syntax editor** | The syntax-highlighted plain-text editor used for editing rules/skills. | `SyntaxHighlightedTextEditor` |
| **Review window** | The separate window for reviewing a session's changes: file list, diff, comments, and the Send Review action. Opens only while a session is Ready for Review. | `SessionReviewWindow` — `Features/Review/` |
| **Review header bar** | The review's control strip: scope switcher, the Side by Side / Inline buttons, All Files / Single File, viewed progress, Send Review. | `ReviewHeaderBar` |
| **Review scope** *(All Branch Work / Uncommitted)* | Which changes are under review — everything since the merge-base with the default branch, or only what is uncommitted. | `ReviewScope` — SessionKit |
| **Side by Side** / **Inline** *(diff modes)* | The two diff layouts: two columns (pre-image opposite post-image) or one column in git's own order. | `ReviewDiffMode` |
| **Review file list** | The review's left rail — one row per changed file with its viewed tick and comment count. | `ReviewFileList`, `ReviewFileRow` |
| **Diff pane** | The review's right half, hosting either layout. | `ReviewDiffPane`, `ReviewFileSection` |
| **Diff line** | One rendered line: number gutter, marker, source text. The shared primitive behind both layouts. | `ReviewDiffLineView` |
| **Comment thread** | Comments attached to a line or to a whole file, drawn under what they refer to. | `ReviewCommentBubble`, `ReviewCommentEditor` |
| **Viewed tick** | The per-file checkbox. Clears itself when the file's diff changes after being ticked. | `ReviewedFile` — SessionKit |
| **Send sheet** | Picks which running session receives a finished review. | `ReviewSendSheet` |

---

## 7. Launchers & modals

| Say | What it is | Code |
| --- | --- | --- |
| **New Session window** | The modal launcher (⌘N, the navigator's New Session button, palette, "fix this commit"). It uses the Workspace, Agent, and Launch tiles. | `CreateSessionView`, `TilesDesign` — `Features/CreateSession/` |
| **Workspace tile** / **Agent tile** / **Launch tile** | The three decisions in the New Session window: where the agent works, which provider/model it uses, and the command that will run. | `TilesDesign` |
| **Session draft** | The shared editable state behind the home composer and the New Session tiles. | `SessionDraft` |
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
| **Settings pane** | One page of settings. Named by its tab: **General, Sessions, Terminal, Git & Worktrees, Notifications, iPhone Companion, Coding Agents**. Shortcut reference lives in the command palette; tool status lives in Coding Agents. | `…SettingsPane` |
| **Settings sidebar row** | A row in the settings window's own sidebar. | `SettingsSidebarRow` |
| **Settings section header** | The icon + title header inside a pane (e.g. "Worktrees", "Prompt Delivery"). | `SettingsSectionHeader` |
| **Tool status row** | The installed/missing line per external CLI. | `ToolStatusRow` |
| **Companion settings pane** | The iPhone Companion pane in Settings: QR code for pairing, manual pairing payload, LAN / Tailscale listener address, paired devices list, and unpair controls. | `CompanionSettingsPane` — `Features/Settings/` |

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

## 11. Mobile companion (iOS)

The iPhone companion app (`FlotillaCompanion`) pairs with Flotilla over LAN or Tailscale using an end-to-end encrypted protocol. It acts as a remote control for running agent sessions.

| Say | What it is | Code |
| --- | --- | --- |
| **Macs list** | The list of discovered and paired Macs, with reachability badges, pairing action, and manual address input. | `MacsView` — `Features/Macs/` |
| **Pair Mac sheet** | The camera scanner and manual key entry dialog for pairing an iPhone with a Mac via QR code. | `PairMacView` — `Features/Pairing/` |
| **Fleet view** | The mobile session fleet list grouped by status (Needs You, Working, Ready, Offline). | `FleetView` — `Features/Fleet/` |
| **Session detail** | The full session view on iOS: header bar with agent/branch info, transcript scroll, and docked composer. | `SessionDetailView` — `Features/SessionDetail/` |
| **Permission card** | Interactive card asking the user to allow or deny an agent tool execution (e.g. bash commands, file writes). | `PermissionCard` — `Features/SessionDetail/Cards/` |
| **Question card** | Multiple-choice or text input prompt card presented when an agent asks a question. | `QuestionCard` — `Features/SessionDetail/Cards/` |
| **Plan card** | Multi-step interactive plan / todo checklist showing progress and approval buttons. | `PlanCard` — `Features/SessionDetail/Cards/` |
| **Composer slot** | Docked prompt bar at the bottom of a session detail: text input, speech-to-text dictation, and interrupt/send controls. | `ComposerSlot` — `Features/SessionDetail/Composer/` |
| **Agent / model / effort controls** | Inline pickers in the session header or sheet for switching active agent provider, model, or reasoning effort. | `AgentModelEffortControls` — `Components/` |
| **Mobile diff view** | Changed file list and side-by-side or inline syntax diffs on iOS. | `DiffView` — `Features/Diff/` |
| **Mobile create session sheet** | iOS session creation form for picking project, branch, agent, model, and initial prompt. | `CreateSessionSheet` — `Features/CreateSession/` |
| **Companion settings** | Companion settings screen showing active device identity, encryption fingerprint, and telemetry preferences. | `CompanionSettingsView` — `Features/Settings/` |

---

## 12. Naming an element for a prompt

If you need to point at something this list doesn't name:

1. **Region + component.** "the *tile meta row* in the *grid*", "the *scope picker* in the *Git tab*".
2. **Reach for the accessibility identifier.** Every testable element has one in `Flotilla/App/AXID.swift`, and the names there are already canonical: `Toolbar.PresentationPicker`, `Knowledge.SortMenu`, `Home.LaunchButton`, `GridTile-<title>-FocusButton`. Quoting an AXID is unambiguous.
3. **Say the variant, don't invent a type.** "the session card in its compact variant", not "the mini session view".

When a name here and the code disagree, the code wins — and this file should be updated
in the same change.

---

## Visual reference

These screenshots are navigation aids for the vocabulary above, not pixel-accuracy specifications. They use Flotilla's deterministic UI-testing fixtures.

<!-- BEGIN GENERATED FIGURES · Scripts/update-ui-vocabulary-screenshots.swift -->

### Shell, Home, and Sessions

**Window shell with Home dashboard**

![Flotilla window shell showing the navigation rail and Home dashboard](images/ui-vocabulary/shell-home-dashboard.png)

**Sessions facet with session list**

![Sessions facet showing the navigation rail, session list, and detail column](images/ui-vocabulary/sessions-facet.png)

The Home view above shows the **project cards** and **customizable widget grid** named in sections 1 and 2.

### Fleet presentations and session cards

**Grid presentation**

![Grid presentation with its toolbar and six terminal tiles](images/ui-vocabulary/grid-presentation.png)

**Grid tile / session card**

![A grid tile showing the tile header, status, branch, focus control, and terminal surface](images/ui-vocabulary/grid-tile.png)

**Board presentation**

![Board presentation with status columns and session cards](images/ui-vocabulary/board-presentation.png)

**Focus presentation**

![Focus presentation with one terminal occupying the detail column](images/ui-vocabulary/focus-presentation.png)

**In-session Git sidebar**

![In-session Git sidebar docked beside the live terminal surface](images/ui-vocabulary/session-git-sidebar.png)

**Agent screenshots panel**

![Agent screenshots feed panel docked beside the live terminal surface](images/ui-vocabulary/session-screenshot-panel.png)

### Project workspace

The Stream workspace: the masthead over the activity feed on the left, the context column on the right.

**Project workspace — activity feed and context column**

![Project workspace — activity feed and context column](images/ui-vocabulary/project-overview.png)

**The worktrees block in the context column**

![The worktrees block in the context column](images/ui-vocabulary/worktree-section.png)

**Commit graph and history**

![Git Commits tab showing the commit graph, history list, and commit detail](images/ui-vocabulary/commit-graph.png)

**Knowledge catalog ledger**

![Skills tab showing the knowledge catalog ledger and inspector](images/ui-vocabulary/knowledge-ledger.png)

**Knowledge detail**

![Rules tab showing the knowledge catalog ledger and a selected knowledge detail](images/ui-vocabulary/knowledge-detail.png)

### Diff and files

**Diff panel**

![Git Changes tab showing a populated diff panel and changed file row](images/ui-vocabulary/diff-panel.png)

**File browser**

![Files tab showing the file browser's tree and editor pane](images/ui-vocabulary/file-browser.png)

**File tree region**

![File tree with filter field and selected README file](images/ui-vocabulary/file-tree.png)

**Editor pane region**

![Editor pane showing a rendered Markdown preview and its toolbar](images/ui-vocabulary/editor-pane.png)

### Launchers and modals

**New Session window and command bar**

![New Session window showing the command bar over its scrim](images/ui-vocabulary/new-session-window.png)

**Command palette and palette panel**

![Command palette floating over the Home dashboard](images/ui-vocabulary/command-palette.png)

**Delete session sheet**

![Delete session sheet with keep-worktree and delete-worktree actions](images/ui-vocabulary/delete-session-sheet.png)

### Settings

**Terminal pane**

![Settings window showing the Terminal pane](images/ui-vocabulary/settings-terminal-editor.png)

**Git & Worktrees pane**

![Settings window showing the Git and Worktrees pane](images/ui-vocabulary/settings-git-worktrees.png)

**Coding Agents pane**

![Settings window showing the Coding Agents pane](images/ui-vocabulary/settings-coding-agents.png)

**iPhone Companion pane**

![Settings window showing the iPhone Companion pane with pairing code and network status](images/ui-vocabulary/settings-companion.png)

### Mobile companion (iOS)

The iPhone companion app (`FlotillaCompanion`) pairs with Flotilla over encrypted local network or Tailscale links, giving full remote control over fleet status, live streaming transcripts, and pending agent interaction gates.

**Companion paired Macs view**

![Companion app root view showing list of paired Macs and their status](images/ui-vocabulary/companion-macs.png)

**Companion fleet view**

![Companion fleet view showing needs-you attention sessions and project session groups](images/ui-vocabulary/companion-fleet.png)

**Permission request card in session transcript**

![Permission request card prompting the user to allow a command](images/ui-vocabulary/companion-permission-card.png)

**Multiple-choice question card in transcript**

![Interactive multiple-choice question card for answering agent questions](images/ui-vocabulary/companion-question-card.png)

**Plan approval card in transcript**

![Plan approval card showing proposed agent steps and review actions](images/ui-vocabulary/companion-plan-card.png)

**Companion diff inspection view**

![Companion working changes view with collapsible file diffs and commit header](images/ui-vocabulary/companion-diff.png)

<!-- END GENERATED FIGURES -->

### Refreshing the visual reference

In Xcode, select the **UI Vocabulary Screenshots** scheme and choose **Product → Test**. The scheme runs only `VocabularyScreenshotUITests`; after every complete, successful capture it validates the manifest, crops the documentation variants, retains a high-resolution 2× master, republishes the 30 PNGs in `docs/images/ui-vocabulary/`, and rewrites the figure blocks between the `BEGIN/END GENERATED FIGURES` markers above — one image per line, captions and section headings included. The prose outside those markers is hand-maintained; edit captions, alt text, and section grouping in the `publications` list in `Scripts/update-ui-vocabulary-screenshots.swift`.

Run this workflow from Xcode so the UI-test runner inherits Xcode's Accessibility permission. A failed or partial run leaves the checked-in documentation images and this section unchanged. To retry only the publishing step after a completed run, use:

```bash
/bin/bash Scripts/update-ui-vocabulary-screenshots.sh
```
