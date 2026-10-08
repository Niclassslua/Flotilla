# Flotilla — Agent Guide

> For AI coding assistants working on this codebase. This document is the authoritative reference for architecture, conventions, and build workflows.

## Project Overview

Flotilla is a macOS SwiftUI application that serves as a local command center for running multiple coding agent sessions simultaneously (Claude Code, Codex CLI, OpenCode). It provides integrated terminal emulation, git worktree management, session lifecycle tracking, and a dark, keyboard-first developer UI.

An iOS companion (`FlotillaCompanion`) lives in the same project: a remote control for a running Flotilla, paired over the LAN or Tailscale with an end-to-end encrypted link hosted inside the Mac app (Settings ▸ iPhone Companion). Architecture, protocol, and every assumption are in [`docs/companion.md`](docs/companion.md). The companion shares `SessionKit`, `TranscriptKit`, `DesignSystem`, and `CompanionKit` with the Mac; its demo mode (`-demo`) runs on the fixture fleet.

- **Platform:** macOS 26.0+ (companion: iOS 18.0+; Liquid Glass on iOS 26, system fallbacks below via `GlassCompatibility.swift`)
- **Language:** Swift 6.0 (strict concurrency)
- **Build system:** XcodeGen (`project.yml` → `Flotilla.xcodeproj`)
- **Bundle ID:** `com.niclassslua.flotilla`
- **Version:** 0.1.0 (Beta)
- **Code signing:** Ad-hoc (`CODE_SIGN_IDENTITY: "-"`)

## Quick Reference

| Command | Purpose |
|---------|---------|
| `make build` | Debug build via xcodebuild |
| `make build-release` | Release build |
| `make build-ephemeral` | Full app build with launch-scoped preferences |
| `make test` | Run unit tests |
| `make test-ui` | Run UI tests |
| `make install` | Release build, then replace `/Applications/Flotilla.app` with it (inside a Flotilla session it does not quit the app) |
| `make archive` | Create xcarchive |
| `make run` | Build and launch the Debug app (same identity as the installed one; not from inside a Flotilla session) |
| `make run-ephemeral` | Build and launch the full app without saving preferences |
| `make build-companion` | Build the iOS companion for the simulator |
| `make run-companion` | Build, install, and launch the companion in an iPhone simulator, talking to real Macs (`SIMULATOR="iPhone 17"` picks the device) |
| `make run-companion-device` | Build, install, and launch the companion on a connected iPhone (team in `Config/CompanionSigning.local.xcconfig`) |
| `make run-companion-demo` | The companion on its fixture fleet; `SCENARIO=<name>` boots into a scripted state |
| `make test-companion` | `CompanionKit` package tests and the iOS unit tests (built outside `~/Documents`, which simulator processes can't read) |
| `make clean` | Remove build artifacts |
| `xcodegen generate` | Regenerate `.xcodeproj` from `project.yml` |

### Mandatory reinstall

After every relevant change you commit or push (app code, packages, resources, `project.yml`, anything that alters the built `Flotilla.app`), you **must** run `make install` so `/Applications/Flotilla.app` matches the latest committed state. Docs-only, CI-only, and test-only changes are exempt. Report the reinstall in your final message; if it fails, fix or say so rather than skipping it.

### Branches

Don't create new branches, locally or on the remote, unless the user explicitly asks for one. Commit to the branch you are on, and when asked to land work, put it on `main` directly instead of pushing a feature branch.

### You are probably running inside Flotilla

Agents working on this repo usually run *inside* the installed Flotilla app, which hosts your terminal and every other agent's session. `FLOTILLA_HOST_APP` is set in your environment when that is the case.

- **Never quit, kill, or restart the installed Flotilla** — no `killall Flotilla`, `pkill Flotilla`, `kill` on its PID, `osascript … quit`, or `open -a Flotilla` relaunch. It ends your own session and everyone else's.
- `make install` already handles this: inside a session it swaps the bundle without quitting, and the running app shows a "Relaunch" banner so the user restarts it when it suits them. Mention the pending relaunch in your final message.
- To exercise your change, run the Ephemeral build (`make run-ephemeral`), not `make run`. Ephemeral is a separate app ("Flotilla Ephemeral", `com.niclassslua.flotilla.ephemeral`) with its own tmux server, sockets, and launch-scoped preferences, so it runs next to the installed one and is safe to quit with `killall "Flotilla Ephemeral"`. The Debug build shares the installed app's name, bundle ID, session database, and tmux server, so launching or quitting it from a session can hit the real app.

## Project Structure

```
Flotilla/
├── Flotilla/                      # Main app target
│   ├── App/                       # Lifecycle, AppEnvironment, AppStore, AXID
│   ├── Features/                  # User-facing domain feature modules
│   │   ├── Shell/                 # FlotillaShell, FleetSidebar, WorkspaceToolbar, Inspector
│   │   ├── Home/                  # HomeDashboardView, project cards, activity stats, HomeInsights, preview fixtures
│   │   ├── CreateSession/         # CreateSessionView (the only session launcher), Drafts, Tiles design
│   │   ├── Grid/                  # MissionControlGrid, GridView, zoom gestures, layout engine
│   │   ├── Session/               # TerminalHostView, TerminalManager, MonacoHost, editors
│   │   ├── Projects/              # ProjectOverview, Git visualizer, graph, history, rules, Kanban
│   │   ├── Diff/                  # DiffPanelView, DiffStatBadge, DiffStatStore, CommitDetail
│   │   ├── CommandPalette/        # CommandPaletteView, CommandPalettePanel
│   │   ├── Settings/              # SettingsView, SettingsViewModel, Startup warning/checks
│   │   └── FileBrowser/           # FileBrowserView, FileBrowserViewModel, WorkspaceFileServicing, icon helpers
│   ├── Services/                  # SessionProcessManager, SessionMetadataMonitor, SessionScrollbackStore, HookCoordinator, WorkspaceRegistry, ActivityStore; Companion/ (CompanionHost, command router, Claude permission bridge)
│   ├── Components/                # StatusBadge, MaterialFileIcon, AgentBrand, pickers
│   └── Resources/                 # Assets.xcassets, MaterialIcons SVG catalog
├── FlotillaCompanion/             # iOS companion (remote control; docs/companion.md)
│   ├── App/                       # CompanionApp (demo vs remote, opened pairing links), CompanionStore, Route
│   ├── Model/                     # Phone-only types: MacHost + connection state, ProviderCapabilities, transcript layout
│   ├── Data/                      # CompanionDataSource; Remote/ (MacConnection, pairing, LAN browser, diagnosis, persistence); Mock/ (demo fleet, scenarios)
│   ├── Components/                # Session row, status dot, unreachable banner, agent/model/effort controls
│   ├── Features/                  # Macs, Pairing, Fleet, SessionDetail (transcript, composer slot, cards), CreateSession + Handoff, Diff/Commits/File, Settings
│   └── Debug/                     # Scenario toolbar menu (DEBUG only)
├── FlotillaCompanionTests/        # iOS unit tests (real loopback pairing against CompanionServer)
├── docs/                          # Long-form references (provider hooks, UI vocabulary)
├── FlotillaUnitTests/             # Unit and local integration tests, grouped by subsystem
├── FlotillaUITests/               # UI tests
├── Packages/                      # 11 local Swift packages
├── project.yml                    # XcodeGen specification
├── Makefile                       # Build automation
├── .impeccable.md                 # Brand/design guidelines
└── AGENTS.md                      # This file
```

### Reference documents

| File | Covers |
|------|--------|
| `docs/ui-vocabulary.md` | Canonical names for every UI region and component — use these terms in prompts, issues, and review comments |
| `docs/provider-hooks.md` | Per-provider hook wiring and the status-transition matrix |
| `docs/providers/` | Per-provider reference: every hook, screen string, dialog, storage path and model query Flotilla relies on, with the CLI version it was verified against, captured fixtures (`FlotillaUnitTests/ProviderFixtures`), and an update checklist. Read the provider's page before touching its integration or after it ships a new release |
| `docs/commit-attribution.md` | Attribution modes, marker protocol, local persistence, rewrite matching, and limitations |
| `docs/session-handoff.md` | Moving a live session between agents: the codec layer, the transaction, every agent's transcript format, and how to add a fifth agent |
| `docs/companion.md` | iPhone companion: architecture, pairing handshake, protocol, error surfaces, and the assumptions made building it |
| `docs/testing.md` | Testing policy: behavioral contracts, assertion quality, isolation, and choosing the right test layer |
| `docs/test-suite-audit.md` | Dated test-value findings, cleanup priorities, and complete inventory link |
| `.impeccable.md` | Brand and visual design guidelines |

## Architecture

### Dependency Injection (`AppEnvironment`)

All dependencies are assembled in `AppEnvironment` at launch and passed down through SwiftUI's `@State`:

```swift
@MainActor
final class AppEnvironment {
    let sessionRepository: SessionRepository    // PersistenceKit
    let gitService: GitServiceProtocol          // GitKit
    let worktreeBaseDirectory: URL
    let isUITesting: Bool
    let startupWarning: String?
}
```

- `FlotillaApp.init()` creates `AppEnvironment` → `SettingsViewModel` → `AppStore` → `HookCoordinator`
- Under `UI_TESTING=1`, mock factories and in-memory repositories are injected
- Database corruption recovery: corrupt GRDB files are moved aside with a UUID suffix

### State Management (`AppStore`)

Uses Swift's `@Observable` macro (not Combine, not `ObservableObject`):

```swift
@Observable @MainActor
final class AppStore {
    private(set) var projects: [Project] = []
    private(set) var sessions: [Session] = []
    var selectedSessionID: UUID?
    var lastCreationError: String?
    var lastOperationError: String?
}
```

- All state is `@MainActor`-isolated
- Process events flow through `processManager.eventHandler` callback
- Views observe state changes via `@Bindable var store: AppStore`

`AppStore` owns the observable session/project state and is the entry point for
session commands; work with its own lifetime or storage is delegated to
collaborators it holds:

| Collaborator | Owns |
|--------------|------|
| `SessionScrollbackStore` | The 256 KB scrollback ring buffer and its 2s debounced persistence. Deliberately **not** `@Observable` — PTY output must not invalidate session views |
| `SessionMetadataMonitor` | Title-discovery and self-report polling tasks, keyed by session ID, with the generation check that rejects a result from a superseded run |
| `KanbanStore` | Board configuration and its persistence. Board actions that change a *session* still go back through `AppStore` and its traced status-transition wrapper |
| `DiffStatStore` | Per-session diff statistics |
| `ProjectIssuesViewModel` | Not an `AppStore` collaborator — owned by the project's Issues tab. Lists open issues through `GhService.openIssues`, loads bodies on selection, and joins issues to sessions by `Session.linkedIssue`. Starting a session from an issue goes through `WorkspaceSheet.createSession(issueNumber:)` |
| `CIStatusStore` | GitHub CI per worktree session branch, polled through `gh` (`GhService.ciStatus`): 30 s while checks run, 3 min once settled, stopped after the PR merges, backed off on `gh` errors. Polls every session, not only visible ones, because failing CI joins Needs You (`FleetAttention`, Dock badge, menu bar, Home). Started by `FlotillaApp`, never in tests or UI tests |

`reload()` refreshes the persisted snapshot and nothing else. Restarting
processes is launch-time recovery (`restoreSessions()`), run once from `init`
— a refresh after session creation must never traverse it.

### Protocol-Oriented Boundaries

Every service boundary uses protocols for testability:

| Protocol | Real Implementation | Test Double |
|----------|-------------------|-------------|
| `SessionRepository` | `GRDBSessionRepository` | In-memory repository |
| `GitServiceProtocol` | `GitService` | `MockGitService` |
| `PTYProcessProtocol` | `SystemPTYProcess` | `MockPTYProcess` |
| `PTYProcessCreating` | `SystemPTYProcessFactory` | `MockPTYProcessFactory` |
| `CommandRunning` | `ProcessCommandRunner` | `RecordingCommandRunner` |
| `ExecutableLocating` | `PATHExecutableLocator` | `FixedExecutableLocator` |
| `AgentProviding` | `CLIAgentProvider` | — |
| `SettingsStoring` | `UserDefaultsSettingsStore` | — |

### Data Flow

```
User Action
    ↓
AppStore.createSession() / deleteSession() / restartSession()
    ↓
SessionProcessManager.start() → PTYProcessProtocol.start()
    ↓
AgentProviderRegistry.launchPlan() → executable + args + env
    ↓
WorktreePlanner.plan() → main-checkout or new-worktree decision
    ↓
GitServiceProtocol.createWorktree() → git worktree add
    ↓
SessionStatusMachine.transition() → enforces legal transitions
    ↓
SessionRepository.save() → persists to GRDB/SQLite
    ↓
Views (via @Observable) observe changes and re-render
```

### View Composition Pattern

Views are decomposed into computed properties, not extracted sub-views:

```swift
struct ContentView: View {
    var body: some View { workspace }

    private var globalBar: some View { ... }
    private var sessionsWorkspace: some View { ... }
    private var focusedSessionWorkspace: some View { ... }
    private func terminal(for session: Session) -> some View { ... }
    private func sessionSurface(for session: Session) -> some View { ... }
}
```

## Local Swift Packages

### Package Dependency Graph

```
SessionKit (leaf)
SettingsKit (leaf)
ProcessKit (leaf)
DesignSystem   → SessionKit

AgentKit       → SessionKit, SettingsKit, ProcessKit
GitKit         → ProcessKit
PersistenceKit → SessionKit, GRDB.swift (external)
TerminalKit    → ProcessKit, SwiftTerm (external)
HooksKit       → SessionKit, ProcessKit
TranscriptKit  → SessionKit
CompanionKit   → SessionKit, TranscriptKit

Flotilla (app)          → all packages
FlotillaCompanion (iOS) → SessionKit, TranscriptKit, DesignSystem, CompanionKit, Textual (external)
```

### Package Reference

| Package | Purpose | External Deps |
|---------|---------|---------------|
| **SessionKit** | Domain models (Session, Project, AgentKind, SessionStatus), SessionRepository protocol, SessionStatusMachine, BranchNaming | None |
| **ProcessKit** | PTY process abstraction (forkpty-backed), PTYProcessProtocol, the one `CommandRunning`/`ProcessCommandRunner` subprocess runner, StartupEnvironmentChecker, OutputBroadcaster | None |
| **GitKit** | GitServiceProtocol, GitService (real), MockGitService, WorktreePlanner, diff parsing | ProcessKit |
| **DesignSystem** | FlotillaColors, spacing/radius tokens, FlotillaPanel modifier, `StatusPresentation`, `ProviderLogo` and the provider logo assets. macOS + iOS | None |
| **SettingsKit** | AppSettings (Codable), SettingsStoring, UserDefaultsSettingsStore | None |
| **AgentKit** | AgentProviding, CLIAgentProvider, AgentLaunchPlan, ModelCatalogFetcher | None |
| **PersistenceKit** | GRDBSessionRepository (SQLite), versioned migrations (v1–v18) | GRDB.swift 6.29+ |
| **TerminalKit** | TerminalController, SwiftUI/AppKit bridge to SwiftTerm | SwiftTerm 1.2+ |
| **HooksKit** | SessionStatusObserver, WaitingNotificationGate, TerminalOutputDigest | None |
| **CompanionKit** | iPhone companion wire protocol: Codable models and messages, pairing link, Ed25519/X25519/ChaChaPoly handshake and sealed channel, Network.framework server/client, interface classification. macOS + iOS | None |
| **TranscriptKit** | CanonicalEntry, TranscriptReading/TranscriptWriting codecs, ToolCallPairing, TranscriptCodecRegistry — reads and writes agents' native transcripts so a session can move between agents | None |

### Package Structure Convention

All packages follow this layout:

```
Packages/<Name>/
  Package.swift
  Sources/<Name>/
    <Name>.swift          # Module re-export with doc comment
    <OtherFiles>.swift    # Public types, protocols, implementations
```

- All public APIs use `public` access control
- All types are `Sendable` where possible
- No internal state leaks across module boundaries

## Session Handoff

A running session can be moved to another agent with its conversation intact.
The move is a **transcode, not a summary**: the current agent's native transcript
is read into `CanonicalEntry` values and re-emitted in the destination's own
format, so the destination resumes what it takes to be its own prior session.

Exactly one agent owns a conversation. `HandoffService` writes the destination
and relaunches, but leaves the source transcript in place and records a
`PendingHandoff`; only once the destination survives its probation window is the
source released. A destination that dies inside it is rolled back onto a
transcript that was never deleted.

Not to be confused with `AppStore.moveSessionToAgent(sessionID:agent:)`, which
changes the agent and deliberately starts a **fresh** conversation — that is the
Kanban agent-lane gesture.

| agent | source | destination |
|---|:-:|:-:|
| Claude Code | yes | yes |
| Codex CLI | yes | yes |
| Antigravity | yes | yes |
| Cursor Agent | yes | yes |
| OpenCode | no | yes |

These differences are expressed by which protocol each codec conforms to
(`TranscriptReading`, `TranscriptWriting`, or both), so the destination picker
cannot offer an impossible move.

**See `docs/session-handoff.md`** for the codec layer, the transaction, every
agent's transcript format, how to verify a codec against a real CLI, and the
invariants that will bite you when changing this area.

## Key Domain Models

### Session (SessionKit)

```swift
public struct Session: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var title: String
    public var goal: String
    public var agent: AgentKind           // .claudeCode, .codexCLI, .openCode, .antigravity
    public var model: String?             // Optional model override
    public var effort: AgentEffort?       // .low, .medium, .high, .xhigh, etc.
    public var projectID: UUID?           // nil = general session
    public var workingDirectory: URL
    public var worktree: WorktreeInfo?
    public var status: SessionStatus
    public var terminalScrollback: Data   // Ring buffer (256 KB max)
    public var createdAt: Date
    public var lastActiveAt: Date
    public var agentSessionID: String?    // Native agent conversation/session identifier
}
```

### SessionStatus — Legal Transitions

```
none (never observed) → any status
working               → waitingForInput, readyForReview, crashed
waitingForInput       → working, readyForReview, crashed
readyForReview        → working, waitingForInput, crashed
crashed               → working (restart only)
```

Illegal transitions leave the session unchanged. Always use `SessionStatusMachine.transition()` — never set `.status` directly; inside `AppStore`, go through its private `transition(_:to:origin:)` wrapper so the change is traced.

Every applied, refused, and suppressed status change is logged to the unified log under category `SessionStatus` (`Flotilla/Services/SessionStatusTrace.swift`), with the cause that produced it — the hook event, the screen marker, the process exit code, or the user's board drag:

```
log stream --style compact --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionStatus"'
```

See `docs/provider-hooks.md` → "Debugging a status change" for the line formats.

### AgentKind & AgentDescriptor

| Case | CLI | Supports Effort | Resume Strategy |
|------|-----|-----------------|-----------------|
| `.claudeCode` | `claude` | Yes (`--effort`) | Assignable (`--session-id` / `--resume`) |
| `.codexCLI` | `codex` | Yes (`--config model_reasoning_effort`) | Discoverable (`codex resume <id>`) |
| `.openCode` | `opencode` | No | Discoverable (`--session <id>`) |
| `.antigravity` | `agy` | Yes (`--effort`) | Discoverable (`--conversation <id>`) |

## Testing

### Test value policy

Follow [docs/testing.md](docs/testing.md) when adding or changing tests. Every test should name a plausible user consequence and an assertion that detects it. Exercise production behavior, establish the relevant precondition, and verify the result after the action. Required interactions must not be hidden behind conditional assertions.

Do not add constructor/non-nil checks, copied test-local algorithms, or exact styling/copy snapshots. Preserve protocol, persistence, lifecycle, terminal, and meaningful accessibility contracts. Use distinguishing fixtures, bounded waits, isolated resources, and failure-safe cleanup. Additional test layers must catch a different failure; consolidate duplicate coverage instead of increasing test count for its own sake.

Use manual visual inspection for appearance, and keep documentation captures, live-provider compatibility, and performance diagnostics separate from ordinary regression coverage. The current execution gaps and method-level recommendations are documented in [the audit](docs/test-suite-audit.md); this policy does not imply those follow-up changes have already been made.

### Unit Tests (`FlotillaUnitTests`)

- Framework: `XCTest` (no third-party test libraries)
- All test classes are `final class <Name>Tests: XCTestCase`
- Use `@MainActor` on tests that exercise `@MainActor`-isolated types
- Import with `@testable import Flotilla` for app-layer tests
- Import packages directly (e.g., `import SessionKit`) for package-layer tests

**Test naming convention:**
```swift
func testLegalTransitions() { ... }           // Describes behavior
func testWorktreeCreationFailureDoesNotCreateSession() { ... }
```

**Test doubles:**
- `RecordingProcessFactory` — captures started processes
- `FixedExecutableLocator` — returns known URLs
- `SelectiveExecutableLocator` — returns `nil` for specific tools
- `MockPTYProcess` — scriptable via `simulateOutput()` / `simulateCrash()`
- `MockGitService` — configurable errors and recorded calls

**Fixtures:**
- `fixtureSession(title:goal:status:)` helper methods create test sessions
- `AppEnvironment.makeUITesting()` seeds in-memory repositories with fixture data

### UI Tests (`FlotillaUITests`)

> **⚠️ Slow — run only when needed.** The full UI test suite launches the actual app repeatedly. Do **not** run it as a routine verification step (e.g., after every change). Only run UI tests when:
> - The change affects UI structure, navigation, or accessibility identifiers
> - The change touches session lifecycle, terminal, or process handling
> - You are explicitly asked to run or verify UI tests
> For most changes, a Debug build + unit tests is sufficient verification. When running UI tests, prefer the minimal targeted set of test classes over the full suite (`-only-testing:FlotillaUITests/<SpecificClass>`).

**Run them from a normal desktop Space, not while another app is full screen.** The test app's window then opens in a Space that isn't visible: clicks and queries still work, but `window.screenshot()` fails with "Image creation failed" (`RestartSessionUITests`, `VocabularyScreenshotUITests`).

**Scope: only write a UI test for something a human can't easily eyeball, or that's a stable behavioral contract.** Don't write UI tests asserting on visual/styling details — background tints, padding, corner radius, colors, frame sizes chosen for looks. A human glances at a screenshot and knows instantly if those are wrong; a test asserting on them breaks on every intentional visual change and becomes pure maintenance overhead with no signal. Reserve UI tests for things that are easy to silently regress and hard to notice by eye: keyboard-shortcut wiring, focus/dismissal behavior, data flowing correctly into fields, multi-step interaction sequences, accessibility-identifier contracts other tests depend on.

- All UI tests set `UI_TESTING=1` environment variable
- Element lookup uses accessibility identifiers: `app.descendants(matching: .any)["CreateSession.GoalField"]`
- Use `waitForExistence(timeout:)` for async UI state
- Use `XCTNSPredicateExpectation` for value polling

**Accessibility identifier convention:**
```
Global.Home
Global.Projects
Global.Sessions
NewSessionButton
CommandPaletteButton
SidebarList
SessionRow-<title>
CreateSession.GoalField
Settings.AppearancePicker
DeleteSessionDialog.Cancel
DeleteSessionDialog.DeleteWithWorktree
```

### UI Vocabulary Screenshot Pipeline

`VocabularyScreenshotUITests` is a documentation generator, not a visual-regression test. Its purpose is to keep the visual appendix in `docs/ui-vocabulary.md` aligned with the app's current UI so contributors can connect canonical vocabulary such as **navigation rail**, **grid presentation**, and **diff panel** to the actual interface. It uses the deterministic `UI_TESTING=1` fixtures and deliberately makes no pixel-level styling assertions.

To refresh the screenshots, open the project in Xcode, select the **UI Vocabulary Screenshots** scheme, and choose **Product → Test**. Run this workflow through Xcode rather than `xcodebuild` in a terminal because macOS UI automation requires Accessibility permission from the process driving the test. The dedicated scheme is declared in `project.yml`, selects only `VocabularyScreenshotUITests`, disables parallel execution, and runs `Scripts/update-ui-vocabulary-screenshots.sh` as its post-test action. Running the screenshot class through another scheme captures raw files but does not publish them.

The pipeline works as follows:

1. The test launches Flotilla with deterministic fixtures, moves capture windows onto the primary display, navigates the documented surfaces, and saves both persistent XCTest attachments and raw Retina PNGs in the UI-test runner's sandbox at `~/Library/Containers/com.niclassslua.FlotillaUITests.xctrunner/Data/Documents/flotilla-vocab-shots/`.
2. Class teardown writes `manifest.txt`. It contains `COMPLETE  schema=1` only when every image required by the documentation was captured successfully.
3. The scheme post-action runs `Scripts/update-ui-vocabulary-screenshots.swift`. The publisher validates the completed manifest and all required inputs, derives the documented crops, retains high-resolution output (up to 3,200 px wide for full-window images), and stages the complete 21-image set before writing to `docs/images/ui-vocabulary/`. It then rewrites the visual-reference figures in `docs/ui-vocabulary.md` between the `BEGIN/END GENERATED FIGURES` markers — one image per line, from the same `publications` list — so that section never needs hand-editing and can't drift into multi-column tables. Prose outside the markers is untouched.
4. If the test is partial, a required capture is missing, or rendering fails, publication stops and the checked-in documentation images and Markdown remain unchanged.

After changing a documented surface, capture name, caption, or visual-reference entry, update these together: `VocabularyScreenshotUITests.requiredCaptureNames` and the `publications` list in `Scripts/update-ui-vocabulary-screenshots.swift` (which carries each figure's `section`, `caption`, `alt`, and crop). The `docs/ui-vocabulary.md` figure blocks are regenerated from that list — don't edit them by hand; edit any surrounding prose directly. Run the dedicated scheme, inspect the refreshed PNGs visually, and commit the image and Markdown changes with the code. To rerun only publication from the most recent complete capture, use:

```bash
/bin/bash Scripts/update-ui-vocabulary-screenshots.sh
```

### Accessibility

- Extensive use of `.accessibilityIdentifier()` with dot-notation namespacing
- `.accessibilityHidden(true)` on decorative elements
- `.accessibilityLabel()` on status indicators
- Respect `\.accessibilityReduceMotion` for animations
- `StatusIndicator` uses color + label (not color alone)

## Build System

### XcodeGen (`project.yml`)

The `.xcodeproj` is generated, never edited manually. After any change to `project.yml`, run:

```bash
xcodegen generate
```

### Build Settings

| Setting | Value |
|---------|-------|
| `SWIFT_VERSION` | 6.0 |
| `MACOSX_DEPLOYMENT_TARGET` | 26.0 |
| `CODE_SIGN_IDENTITY` | `-` (ad-hoc) |
| `ENABLE_HARDENED_RUNTIME` | YES (app), NO (tests) |
| `GENERATE_INFOPLIST_FILE` | YES |
| `MARKETING_VERSION` | 0.1.0 |
| `CURRENT_PROJECT_VERSION` | 2 |

### Ephemeral Test App

The **Flotilla Ephemeral** scheme builds a complete app with real agents,
terminals, git operations, and session storage. It does not enable
`UI_TESTING` mocks. The `Ephemeral` build configuration defines
`FLOTILLA_EPHEMERAL`, starts from default launch-scoped settings, and bypasses
the app's preference reads and writes. Its scenes use
`.restorationBehavior(.disabled)` so SwiftUI/AppKit does not restore or save
scene state. Because `NavigationSplitView` separately installs an AppKit
autosave name, `EphemeralWindowStateDisabler` clears the Ephemeral preferences
domain before scene creation, disables native window and split-view autosave,
and reapplies the design-system sidebar width once per launch. It also uses the
separate bundle identifier `com.niclassslua.flotilla.ephemeral` so macOS-managed
state cannot affect the normal app. Its hook support files and companion bridge
socket live under `Application Support/Flotilla Ephemeral/`, and its tmux server
uses `flotilla-ephemeral`, so a preview cannot unlink or attach to the running
Flotilla instance's sockets. The companion permission bridge also holds an
exclusive lock for its socket path: a second instance refuses to replace a
live bridge, while a crash-left socket can be reclaimed after the lock drops.

Use `make run-ephemeral` locally. When
`Config/CompanionSigning.local.xcconfig` supplies a development team, that
Makefile target signs the Ephemeral app with a stable Apple Development
identity so Handy can remember its local speech approval across rebuilds.
The Xcode project configuration remains ad-hoc for CI and contributors
without that local signing file. Override with
`EPHEMERAL_SIGNING_OVERRIDE=` to force the ad-hoc build. CI uploads the same
build as the `Flotilla-Ephemeral` artifact for pull requests and `main` pushes.

### xcodebuild Commands

```bash
# Debug build
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build

# Release build
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -configuration Release \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData build

# Unit tests
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  test -only-testing:FlotillaUnitTests

# UI tests
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData \
  test -only-testing:FlotillaUITests
```

### CI/CD (GitHub Actions)

Pipeline at `.github/workflows/build.yml`:
1. Checkout → install XcodeGen, tmux and the Metal toolchain → generate project
2. Run standalone `CompanionKit` and `TerminalKit` SwiftPM tests → build Release
3. `make test` (FlotillaUnitTests) with a 2-minute per-test timeout
4. Upload the `.xcresult` bundles and any Flotilla crash reports as `test-results`

Both workflows run on GitHub's `xcode-27` image (a preview label), so CI and
releases use the same Xcode 27 as local builds and compile the real
`Flotilla.icon`. That image lacks the Metal toolchain SwiftTerm's shader needs,
and tmux, which the real-pipeline tests drive at `/opt/homebrew/bin/tmux`.
The log names failing tests but not their messages; read those from the
`test-results` artifact (`xcrun xcresulttool get test-results tests --path …`).

A newer push to the same ref cancels the in-flight run. There is no Debug
build (Xcode compiles it on every Run) and no CI archive or artifact; the
only archive is the one `release-dmg.yml` builds for a release.

Release DMGs are a separate workflow (`.github/workflows/release-dmg.yml`).
Publishing a GitHub Release archives the app with `make archive`, wraps `Flotilla.app` plus an Applications symlink in
`Flotilla-<version>.dmg` via `hdiutil`, and attaches that file to the release
(also uploaded as the `Flotilla-DMG` artifact). Notarization is not included
yet — Gatekeeper will still warn on first open until that is added.

A parallel `ui-tests` job runs `make test-ui` on its own runner (results in
the `ui-test-results` artifact). The runner boots at 1024x768, narrower than
the main window's minimum width, so the job switches the display to 1920x1080
with `displayplacer` first. XCUITest drags never reach the Home grid's
`DragGesture`, so widget reordering is tested via the context menu and the
drag itself stays a manual check.

An `.accessibilityIdentifier` on a plain container is applied to every
descendant, overriding their own identifiers — UI tests then find the wrong
element or none. Give identified containers
`.accessibilityElement(children: .contain)`, and icon+text labels
`.accessibilityElement(children: .combine)`.

Debug signs with the maintainer's own Apple Development team
(`DEVELOPMENT_TEAM: UWAHVC4JTL` in `project.yml`) so that Screen Recording
consent survives an ordinary rebuild — that team/certificate doesn't exist on
a CI runner or another contributor's machine. Pass
`make build SIGNING_OVERRIDE="..."` (see the Makefile) if you hit a "No signing certificate"
error building Debug on a machine without that team.

Release and Ephemeral project configs are ad-hoc by default (`project.yml`'s
base `CODE_SIGN_IDENTITY: "-"`), so `make archive` always succeeds without
secrets. The local `make build-ephemeral` signing override is described above.
Distributed builds are signed and notarized only by `release-dmg.yml` (runs
when a GitHub Release is published). It imports the certificate into a
temporary keychain, archives with `make archive DEVELOPER_ID=1` (Developer ID,
manual style, timestamped), signs the DMG, notarizes it with `notarytool` and
staples the ticket. Without the secrets below the DMG falls back to the ad-hoc
build and Gatekeeper warns on first open.

| Secret | Value |
|--------|-------|
| `DEVELOPER_ID_CERTIFICATE_P12` | Base64 of a "Developer ID Application" `.p12` export (`base64 -i cert.p12 \| pbcopy`) |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password used when exporting that `.p12` |
| `NOTARY_API_KEY` | Contents of an App Store Connect API key `.p8` (Users and Access → Integrations → Team Keys, role Developer) |
| `NOTARY_API_KEY_ID` | That key's Key ID |
| `NOTARY_API_ISSUER_ID` | The Issuer ID shown above the key list |

Add them as **environment secrets** of the `release` environment (Settings →
Environments), not repo secrets. It requires the maintainer's approval before
the job runs and only admits `v*` tags, so nothing else can read them.

The certificate must belong to team `UWAHVC4JTL`, which the Makefile's
`ARCHIVE_SIGNING_OVERRIDE` names.

`Flotilla.icon` is an Icon Composer bundle using features (`specular-location`,
`refractivity`) that Xcode 26.6's `actool` crashes on. CI used to swap in
`FlotillaFallback.appiconset` for that; on the `xcode-27` image it compiles
the real icon, so both workflows build it as-is.

## Design System

### Color Palette (`FlotillaPalette`)

| Name | RGB | Usage |
|------|-----|-------|
| `ocean` | `(0.96, 0.36, 0.16)` | Warm orange — primary actions, accent |
| `signal` | `(0.19, 0.78, 0.64)` | Teal/green — success, live status |
| `cyan` | `(0.26, 0.72, 0.92)` | Bright cyan — secondary accent |
| `canvas` | `(10, 10, 12)/255` | Near-black — main background |
| `sidebar` | `(18, 18, 22)/255` | Dark gray — sidebar |
| `panel` | `(22, 22, 26)/255` | Dark gray — panel cards |
| `elevated` | `(30, 30, 35)/255` | Elevated surface |
| `terminal` | `(10, 10, 12)/255` | Terminal background |
| `subtleStroke` | `(50, 50, 58)/255` | Hairline borders |
| `mutedText` | `white @ 0.52` | Secondary/muted text |

**Appearance.** Configurable via Settings (Dark, Light, System) applying `FlotillaColors` semantic tokens.

### Spacing Scale (`FlotillaSpacing`)

| Name | Value |
|------|-------|
| `xSmall` | 4 |
| `small` | 8 |
| `medium` | 12 |
| `large` | 16 |
| `xLarge` | 24 |
| `xxLarge` | 32 |

### Corner Radii (`FlotillaRadius`)

| Name | Value |
|------|-------|
| `small` | 6 |
| `medium` | 10 |
| `large` | 14 |

### Components

- `FlotillaPanel` — ViewModifier: panel background + corner radius + subtle stroke
- `.flotillaPanel()` — Convenience extension
- `StatusIndicator(color:label:pulses:)` — 8x8 colored dot with optional pulse animation, respects reduce motion

## Code Conventions

### Naming

| Element | Convention | Example |
|---------|-----------|---------|
| Types | PascalCase | `AppStore`, `SessionProcessManager` |
| Files | Named after primary type | `AppStore.swift`, `GridView.swift` |
| Enums (cases) | camelCase | `.claudeCode`, `.waitingForInput` |
| Protocols | Descriptive noun/verb | `SessionRepository`, `ExecutableLocating` |
| Test classes | `<Type>Tests` | `SessionStatusMachineTests` |
| Test methods | `test<Behavior>` | `testLegalTransitions` |
| Accessibility IDs | Dot-notation | `"SessionRow-\(session.title)"` |

### Import Patterns

```swift
import SwiftUI
import SessionKit
import DesignSystem
import SettingsKit
import ProcessKit
```

Import only what you need. Package modules are imported by product name.

### SwiftUI Patterns

- **State:** `@State` for local view state, `@Bindable` for `@Observable` objects, `@Binding` for passed bindings
- **Environment:** `@Environment(\.openSettings)`, `@Environment(\.accessibilityReduceMotion)`
- **Animations:** `.snappy(duration:)` for quick transitions; explicit `Animation?` values
- **Sheets:** `sheet(item:)` with `Identifiable` enums
- **Navigation:** `NavigationSplitView` with `WorkspaceNavigator` observable navigator and `SidebarItem` selection tracking
- **Notifications:** `NotificationCenter.default.publisher(for:)` for keyboard shortcuts and cross-view communication

### Access Control

- Package types: `public` for all cross-module API
- App types: `private` and `internal` by default
- `@unchecked Sendable` only on classes that manage thread safety internally (e.g., `GRDBSessionRepository`)

### Error Handling

- Custom error enums conforming to `LocalizedError`: `LaunchError`, `GitServiceError`, `PTYProcessError`
- Best-effort operations with warning propagation (e.g., worktree cleanup)
- User-facing errors stored on `AppStore.lastCreationError` / `lastOperationError`

## Key Architectural Decisions

1. **No Combine** — Swift Observation (`@Observable`) handles all reactivity
2. **No `ObservableObject`** — all ViewModels use `@Observable` with `@MainActor`
3. **No NavigationStack** — `NavigationSplitView` with manual destination tracking
4. **Always dark mode** — forced via `.environment(\.colorScheme, .dark)`
5. **Protocol boundaries** — every service has a protocol seam for testing
6. **SessionStatusMachine** — single authority for state transitions, never bypass
7. **Ring buffer scrollback** — 256 KB cap with debounced persistence to avoid DB thrashing
8. **UI_TESTING=1** — environment variable swaps in mock factories for deterministic UI tests

## Files to Know

| File | Why It Matters |
|------|---------------|
| `Flotilla/App/AppEnvironment.swift` | DI container — read this first to understand what's wired where |
| `Flotilla/App/AppStore.swift` | Observable owner of sessions and projects, and the entry point for session commands |
| `Flotilla/Features/Shell/FlotillaShell.swift` | Root shell view — navigation and split presentation |
| `Flotilla/Services/SessionProcessManager.swift` | Process lifecycle — start, terminate, event handling |
| `Flotilla/Features/Session/TerminalManager.swift` | Terminal controller lifecycle — retain/release per session |
| `Flotilla/Services/HookCoordinator.swift` | Notification orchestration — status observation and dispatch |
| `project.yml` | Build configuration — source of truth for xcodeproj generation |
| `Packages/SessionKit/Sources/SessionKit/Models.swift` | Core domain types — Session, Project, AgentKind, SessionStatus |
| `Packages/ProcessKit/Sources/ProcessKit/PTYProcessProtocol.swift` | Core process abstraction — read to understand PTY protocol |
| `Packages/PersistenceKit/Sources/PersistenceKit/GRDBSessionRepository.swift` | Database layer — migrations, CRUD operations |
| `make test` | Run the app unit/local integration test target; package test targets require explicit selection |
