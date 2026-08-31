# Flotilla UI Model

Destinations, state, and layout policy. The companion to [`ui-vocabulary.md`](ui-vocabulary.md),
which names *components*; this document names *places*, *state*, and the rules that govern how
space is spent.

Written as U1 of the `ui-part-two` branch. U2–U4 are built against it, so a change here is a
change to what those units are implementing.

---

## 1. Destination canon

One destination, one name — in the picker, the breadcrumb, the palette, the window title, and
the accessibility identifier. Before this, the landing surface carried four names at once
("Projects" in the scope picker, "Overview" in the breadcrumb and `SidebarItem`, "the goal-first
launch dashboard" in the palette) and "Overview" *also* named a tab inside every project.

| Destination | Canonical name | `SidebarItem` | Identifier | Notes |
| --- | --- | --- | --- | --- |
| The app's landing surface — attention, activity, projects, composer | **Home** | `.overview` | `Sidebar.Overview` | Matches what the code already calls it: `HomeDashboardView`, `HomeComponents`, `AXID.homeDashboard`. Frees "Overview" for the project tab. |
| Every running agent, as a collection | **Sessions** | `.allSessions` | `Sidebar.AllSessions` | The destination. **All Sessions** is a *row* within the navigator, not a second name for the place. |
| One project's durable workspace | **the project's name** | `.project(UUID)` | `Sidebar.ProjectRow-<name>` | Never the literal word "Project" in user-facing copy — a project is always named. |
| One session, full screen | **the session's title** | `.session(UUID)` | `SessionRow-<title>` | The presentation is **Focus**; the destination is the session. |

> **Identifiers lag the canon deliberately.** `Sidebar.Overview` and `Sidebar.AllSessions` are load
> bearing for six UI test files, and `SidebarItem` is `Codable` into persisted workspace state, so
> the enum cases and identifiers keep their old spelling until U2 rebuilds the navigator and can
> remap them in one move. Only user-facing strings changed in U1.

Reserved words that mean exactly one thing:

- **Overview** — a tab inside a project workspace (`ProjectDetailView.ProjectTab.overview`). Never the app landing surface.
- **Grid**, **Board**, **Focus** — presentations of the Sessions collection (`WorkspacePresentation`). Never destinations.
- **Fleet** — internal vocabulary for the whole set of sessions (`FleetSidebar`, `FleetSessionList`). Correct in code and in review comments; does not appear in user-facing copy.

No two palette commands may resolve to the same destination. Enforced by
`WorkspaceCommandTests.testNoTwoCommandsShareADestination`.

---

## 2. State matrix

Seven kinds of state. **None is an alias of another**, and conflating any two is what produced the
grid sidebar hijack (F4). Each row gives the scenario in which it differs from every other.

| # | State | Lives in | Proof it is not an alias |
| --- | --- | --- | --- |
| 1 | **Navigation selection** — what the detail column is showing | `WorkspaceNavigator.selection` | Differs from *active session* whenever the selection is `.overview`, `.project`, or `.allSessions`: something is on screen while no session is active. |
| 2 | **Active session** — which session's terminal has focus and receives keystrokes | `AppStore.selectedSessionID`, `DetailColumn.activeGridSessionID` | Differs from *navigation selection* in Grid: nine tiles are on screen, one is active, and the navigation selection is `.allSessions`, not a session. |
| 3 | **Batch selection** — rows marked for a bulk action | `WorkspaceNavigator.sidebarSelection` (`Set<SidebarItem>`) | Differs from *navigation selection* by cardinality: ⌘-clicking three rows to delete them must not change what the detail column shows. Already modelled correctly. |
| 4 | **Grid membership** — which sessions the grid renders | `settings.workspace.gridSelectedSessionIDs` | Differs from all of the above: a session can be in the grid while unselected, unfocused, and not batch-marked. Persisted across launches; the others are not. |
| 5 | **Filter state** — what narrows a collection | `WorkspaceNavigator.searchText` today; the filter set in U4 | Differs from *navigation selection* because it survives switching presentation: the same query must yield the same sessions in Grid, Board and List. |
| 6 | **Project-root scope** — the repository a surface is reading | `Project.rootURL` | Differs from *worktree scope* for every session with a worktree, which is the normal case. Owns history, root files, skills, rules, repository config. |
| 7 | **Worktree scope** — the checkout a session is working in | `session.worktree?.worktreePath ?? session.workingDirectory` | Differs from *project-root scope* as above, and exists for sessions with **no** `projectID` at all — which is why keying a diff to a project ID leaves the "Unassigned" group with dead buttons (F7). |

**Rule.** A surface declares which scope it belongs to. Scope is never inferred from where the user
navigated from. `projectGitScopes[projectID]` exists only because a session-scoped diff had to be
injected into a project-owned container; once Changes declares itself worktree-scoped, that
dictionary and F7's guard both disappear.

---

## 3. Layout policy

There is no single maximum content width. Flotilla has several legitimate layout modes, and the
failure this replaces was not "too much black" — it was space allocated with no stated relationship
to the task. Every surface declares one of these.

| Mode | Rule | Examples |
| --- | --- | --- |
| **Reading** | Bounded measure. Long-form text does not stretch to the window. | Rules, markdown, skill detail, settings explainers |
| **Data** | Take the available width. Hunks, columns and graphs are wider-is-better. | Terminal, diff, session List, commit graph, file tree |
| **Board** | Adaptive columns sharing the container width, with controlled horizontal overflow. | Kanban |
| **Master–detail** | Resizable, collapsible, and persisted per surface. Never a fixed split. | Skills ledger, navigator + detail, inspector |

The binding constraint on Data and Master–detail: at `windowMin = 1000`, a `sidebarMin` of 260 plus
an `inspectorMin` of 280 leaves under 460pt for a terminal before dividers. Four permanently visible
regions is not viable — which is why availability, not visibility, is the requirement (U3).

---

## 4. Header grammar

One system, varied by emphasis. Today all-caps, title-case-plus-pill-in-a-card, and
all-caps-plus-toolbar coexist on a single page.

- **Section header** — sentence case, secondary colour, optional count of *the rows actually rendered*.
- **Emphasis** is carried by weight and spacing, never by switching to a different header system. A
  section outranking its neighbours (a "Needs you" queue above "Recent sessions") is correct and is
  expressed within this grammar.
- A count in a header always counts the rendered collection. Counting a source collection over a
  filtered body is the defect fixed as F2.
