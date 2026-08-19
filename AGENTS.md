# Flotilla — Agent Guide

> For AI coding assistants working on this codebase. This document is the authoritative reference for architecture, conventions, and build workflows.

## Project Overview

Flotilla is a **macOS-only** SwiftUI application that serves as a local command center for running multiple coding agent sessions simultaneously (Claude Code, Codex CLI, OpenCode). It provides integrated terminal emulation, git worktree management, session lifecycle tracking, and a dark, keyboard-first developer UI.

- **Platform:** macOS 15.0+ (Sequoia)
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
| `make test` | Run unit tests |
| `make test-ui` | Run UI tests |
| `make archive` | Create xcarchive |
| `make run` | Build and launch the app |
| `make clean` | Remove build artifacts |
| `xcodegen generate` | Regenerate `.xcodeproj` from `project.yml` |

## Project Structure

```
Flotilla/
├── Flotilla/                      # Main app target (31 source files)
│   ├── FlotillaApp.swift          # @main entry point
│   ├── AppEnvironment.swift       # Dependency injection container
│   ├── AppStore.swift             # Central @Observable state (ViewModel)
│   ├── ContentView.swift          # Root view, NavigationSplitView
│   ├── TerminalManager.swift      # Per-session terminal lifecycle
│   ├── TerminalHostView.swift     # SwiftTerm host view
│   ├── SessionProcessManager.swift# Process lifecycle management
│   ├── HookCoordinator.swift      # Notification/hook orchestration
│   ├── CreateSessionView.swift    # New session creation UI
│   ├── GridView.swift / GridTileView.swift  # Multi-session grid
│   ├── DiffPanelView.swift        # Git diff inspector
│   ├── FileBrowserView.swift      # File tree browser
│   ├── RulesPanelView.swift       # Project rules/skills viewer
│   ├── SettingsView.swift         # App settings UI
│   ├── HomeDashboardView.swift    # Home/overview screen
│   ├── CommandPaletteView.swift   # Keyboard command palette
│   └── Assets.xcassets/           # App icon + agent logos
├── FlotillaUnitTests/             # Unit tests (10 files)
├── FlotillaUITests/               # UI tests (10 files)
├── Packages/                      # 9 local Swift packages
├── project.yml                    # XcodeGen specification
├── Makefile                       # Build automation
├── .impeccable.md                 # Brand/design guidelines
└── AGENTS.md                      # This file
```

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
- Terminal scrollback uses a 256 KB ring buffer with 2s debounced persistence
- Process events flow through `processManager.eventHandler` callback
- Views observe state changes via `@Bindable var store: AppStore`

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
DesignSystem (leaf)
GitKit (leaf)

AgentKit       → SessionKit, SettingsKit, ProcessKit
PersistenceKit → SessionKit, GRDB.swift (external)
TerminalKit    → ProcessKit, SwiftTerm (external)
HooksKit       → SessionKit, ProcessKit

Flotilla (app) → all packages
```

### Package Reference

| Package | Purpose | External Deps |
|---------|---------|---------------|
| **SessionKit** | Domain models (Session, Project, AgentKind, SessionStatus), SessionRepository protocol, SessionStatusMachine, BranchNaming | None |
| **ProcessKit** | PTY process abstraction (forkpty-backed), PTYProcessProtocol, CommandRunning, StartupEnvironmentChecker, OutputBroadcaster | None |
| **GitKit** | GitServiceProtocol, GitService (real), MockGitService, WorktreePlanner, diff parsing | None |
| **DesignSystem** | FlotillaPalette (colors), FlotillaSpacing, FlotillaRadius, FlotillaPanel modifier, StatusIndicator | None |
| **SettingsKit** | AppSettings (Codable), SettingsStoring, UserDefaultsSettingsStore | None |
| **AgentKit** | AgentProviding, CLIAgentProvider, AgentLaunchPlan, ModelCatalogFetcher | None |
| **PersistenceKit** | GRDBSessionRepository (SQLite), versioned migrations (v1–v3) | GRDB.swift 6.29+ |
| **TerminalKit** | TerminalController, SwiftUI/AppKit bridge to SwiftTerm | SwiftTerm 1.2+ |
| **HooksKit** | SessionStatusObserver, WaitingNotificationGate, TerminalOutputDigest | None |

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
idle          → working, waitingForInput, finished, crashed
working       → idle, waitingForInput, finished, crashed
waitingForInput → working, idle, finished, crashed
finished      → working (restart only)
crashed       → working (restart only)
```

Illegal transitions are silently ignored by `SessionStatusMachine`. Always use `SessionStatusMachine.transition()` — never set `.status` directly.

### AgentKind & AgentDescriptor

| Case | CLI | Supports Effort | Resume Strategy |
|------|-----|-----------------|-----------------|
| `.claudeCode` | `claude` | Yes (`--effort`) | Assignable (`--session-id` / `--resume`) |
| `.codexCLI` | `codex` | Yes (`--config model_reasoning_effort`) | Discoverable (`codex resume <id>`) |
| `.openCode` | `opencode` | No | Discoverable (`--session <id>`) |
| `.antigravity` | `agy` | Yes (`--effort`) | Discoverable (`--conversation <id>`) |

## Testing

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

> **⚠️ Slow — run only when needed.** The full UI test suite takes ~5 minutes (12 test classes, 12 app launches) and launches the actual app repeatedly. Do **not** run it as a routine verification step (e.g., after every change). Only run UI tests when:
> - The change affects UI structure, navigation, or accessibility identifiers
> - The change touches session lifecycle, terminal, or process handling
> - You are explicitly asked to run or verify UI tests
> For most changes, a Debug build + unit tests is sufficient verification. When running UI tests, prefer the minimal targeted set of test classes over the full suite (`-only-testing:FlotillaUITests/<SpecificClass>`).

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
| `MACOSX_DEPLOYMENT_TARGET` | 15.0 |
| `CODE_SIGN_IDENTITY` | `-` (ad-hoc) |
| `ENABLE_HARDENED_RUNTIME` | YES (app), NO (tests) |
| `GENERATE_INFOPLIST_FILE` | YES |
| `MARKETING_VERSION` | 0.1.0 |
| `CURRENT_PROJECT_VERSION` | 1 |

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
1. Checkout → Xcode selection → XcodeGen install
2. Generate project → Build (Debug) → Unit tests → Build (Release)
3. Upload `.app` artifact
4. On `main` push: Archive with `developer-id` export → Upload zip

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

**Always dark mode.** The app forces `.environment(\.colorScheme, .dark)`.

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
- **Navigation:** `NavigationSplitView` with manual `AppDestination` enum tracking (no `NavigationStack`)
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
| `AppEnvironment.swift` | DI container — read this first to understand what's wired where |
| `AppStore.swift` | Central state — all business logic lives here |
| `ContentView.swift` | Root view — understand the view hierarchy and navigation |
| `SessionProcessManager.swift` | Process lifecycle — start, terminate, event handling |
| `TerminalManager.swift` | Terminal controller lifecycle — retain/release per session |
| `HookCoordinator.swift` | Notification orchestration — status observation and dispatch |
| `project.yml` | Build configuration — source of truth for xcodeproj generation |
| `SessionKit/Models.swift` | Core domain types — Session, Project, AgentKind, SessionStatus |
| `ProcessKit/PTYProcessProtocol.swift` | Core process abstraction — read to understand PTY protocol |
| `PersistenceKit/GRDBSessionRepository.swift` | Database layer — migrations, CRUD operations |
| `make test-ui` | Run UI tests (~5 min, 12 test classes, 12 app launches) |
