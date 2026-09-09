# Test suite value audit

Reviewed source at `6461b54` on 2026-09-09.

Most of this suite protects useful behavior. The problem is a smaller set of tests that create false confidence, duplicate existing contracts, freeze presentation choices, or run in the wrong context. Broad deletion would remove valuable protection around processes, transcripts, Git operations and saved data.

## Scope and result

I inspected all 652 declared test methods, their fixtures/helpers, the build/test selections, and relevant production implementations. This is a source-based value assessment: tests were not executed, runtime and flake rates were not measured, and no runtime coverage or mutation score is claimed. Test names and comments were checked against assertions rather than accepted as evidence.

| Source | Test-bearing files | XCTest classes | Declared methods |
|---|---:|---:|---:|
| `FlotillaUnitTests` | 63 | 88 | 624 |
| `FlotillaUITests` | 18 | 18 | 26 |
| `Packages/TerminalKit/Tests` | 1 | 1 | 2 |
| Total | 82 | 107 | 652 |

Two additional Swift files contain shared support without test methods. Method counts include optional/live tests and documentation captures; they are not counts of tests proven to execute in CI. The old guide's 537 tests / 77 suites and 12 UI classes were stale.

| Recommendation | Methods | Meaning |
|---|---:|---|
| Keep | 524 | Useful regression contract; retain, with harness improvements where noted |
| Strengthen | 56 | Valuable intended behavior, insufficient or misleading proof |
| Consolidate | 45 | Preserve meaningful cases while removing duplicated setup/assertions |
| Remove | 21 | Constructor, test-local algorithm, or presentation checks with little independent value |
| Move | 6 | Documentation, diagnostics, live-provider or performance work outside ordinary regression execution |

These categories are mutually exclusive recommendations for the current methods. Consolidation preserves cases and does not imply 45 deletions. Keep does not certify completeness or reliability. The [complete inventory](test-value-inventory.md) accounts for every file and names all 128 exceptions to Keep with source links and proposed replacements. The durable [testing policy](testing.md) turns the findings into rules.

## Highest-priority repairs: tests that can pass with the behavior broken

| Test / location | Why it is misleading | Useful replacement |
|---|---|---|
| [StartupCheckUITests](../FlotillaUITests/StartupCheckUITests.swift) | Both warning existence and dismissal checks are conditional; no banner means no assertion. | Force a known missing dependency, require its banner, dismiss it, and verify the app remains usable. |
| [RestartSessionUITests](../FlotillaUITests/RestartSessionUITests.swift) | Missing restart control skips the test; any status element can satisfy the result. | Establish Crashed, require restart, then await the Working label for that session. |
| [TerminalUITests](../FlotillaUITests/TerminalUITests.swift) | Generates a unique probe but only asserts the terminal still exists after typing. | Observe that exact probe through the UI input-to-PTY-to-renderer path. |
| [SettingsUITests](../FlotillaUITests/SettingsUITests.swift) | Ends after typing a value; no assertion checks it was applied. | Reopen the setting or use it in a subsequent worktree creation and verify the result. |
| [SessionDraftTests.testLaunchClearsIsCreatingEvenOnFailure](../FlotillaUnitTests/SessionDraftTests.swift) | The launch succeeds and the test requires a non-nil ID. | Inject launch failure and assert reset, retained draft, error, and nil result. |
| [KanbanAppStoreTests.testMoveSessionToStatus](../FlotillaUnitTests/KanbanTests.swift) | Creation already makes the session Working; moving it to Working proves no transition. | Start in another legal state and verify changed in-memory and persisted status. |
| [DiffPanelViewModelTests.testCommitNoOpsWhenMessageIsBlank](../FlotillaUnitTests/DiffPanelViewModelTests.swift) | There are no staged changes either, so the other guard masks the condition under test. | Seed staged changes, then use a whitespace-only message. |
| [TerminalControllerReflowTests.testMakeAuthoritativeIgnoresDegenerateDimensions](../FlotillaUnitTests/TerminalControllerReflowTests.swift) | Does not create invalid dimensions and only asserts a constructed controller is non-nil. | Supply invalid dimensions and prove they do not reach the PTY. |
| [AgentSessionProviderTests.testOutputBroadcasterNeverOverflowsOnHeavyTraffic](../FlotillaUnitTests/AgentSessionProviderTests.swift) | Collects some traffic without asserting bytes or order; dropping all output can pass. | Assert distinguishing bytes, subscriber delivery and bounded retained history, with a collection deadline. |
| [TerminalControllerCoalescingTests.testCursorHideShowSequenceCoalescesIntoASingleFlush](../FlotillaUnitTests/TerminalPipelineTests.swift) | Three chunks with a limit of three flushes accepts one flush per chunk. Cursor visibility is not asserted. | Check the cursor state and a justified coalescing property; rename the inaccurate single-flush claim. |

Other repairs are smaller but real: Grid's focus branch is optional; the rule-save test checks generic `UI test` rather than its unique marker; the body-search test has no nonmatching control; the back-stack bound accepts an empty stack; and several tests named for refresh, ordering or persistence observe only a call or final in-memory value. The inventory includes each of these.

## Low-value checks to remove

The 21 removal candidates are a deliberately narrow list:

- Five `AgentBrandTests` methods freeze colors, opacity, arbitrary RGB distances or convenience forwarding. Keep framework-to-agent mapping.
- Four `GitIconTests` / `GitBranchIconTests` constructor methods read back their initializer arguments. Keep resource lookup coverage, consolidated into a packaging smoke test.
- Both `MarqueeTextTests` methods assert non-nil on a non-optional SwiftUI struct.
- Six `ProjectOverviewTests` methods: three test algorithms written inside the test instead of production code; three pin tab counts, titles and symbols. Keep all four real navigator/cache tests.
- Three `KnowledgeItemTests` methods pin decorative metric presence/absence or a direct weight projection.
- `WorkspaceCommandTests.testLandingSurfaceIsNamedHome` pins editorial vocabulary. Keep destination uniqueness and usable command metadata.

The same principle does **not** justify deleting protocol constants, migration fixtures, semantic accessibility labels or graph layout invariants. Those can protect machine compatibility, access to functionality or algorithmic correctness.

## Duplication worth consolidating

[ProjectHistoryView.swift](../Flotilla/Features/Projects/ProjectHistoryView.swift) declares `typealias ProjectHistoryViewModel = ProjectGraphViewModel`. Five graph-suite methods overlap history-suite loading, search, grouping and web-link coverage against that same implementation. Merge common cases and keep the unique graph rows/branches, pagination, attribution and unseen-commit behavior.

The two scope suites also overlap on All and project-plus-smart-list filtering. Keep the identity-based examples and the distinct General behavior. Agent column generation is repeated within Kanban. Individual settings/persistence field round trips can become representative records with several non-default values while retaining separate legacy-input cases.

The ten mock-specific tests in `ProcessKitTests` and `GitKitTests` are test-double infrastructure coverage. A compact lifecycle/stream/error contract is useful; a growing CRUD mirror of each mock is not evidence that the real service works. Small input tables for notification IDs and language mappings are also clearer to maintain together. These are maintenance recommendations, not an argument to optimize the test counter.

## High-value coverage to protect

| Area | Representative existing evidence | What it protects |
|---|---|---|
| Session lifecycle | `testReloadRefreshesDataWithoutRestartingProcesses`, `testRestorationDoesNotReplayTheOriginalGoal`, cleanup-failure and crash persistence cases | Duplicate agents, repeated work, inconsistent saved state |
| Handoff | AppStore probation rollback, source preservation, kill-before-start ordering, real tmux pane-command replacement | Conversation loss and attachment to the wrong agent |
| Persistence | v8/v9 incremental upgrades, save-after-upgrade, repository reopen, legacy settings payloads | Existing installations failing or silently resetting data |
| Git/files | Real disposable repositories, stage/unstage/discard, branch/worktree cleanup, parser edge cases, rule/template preservation | Modified/lost files, wrong branch operations and misleading changes |
| PTY/terminal | Large simultaneous stdout/stderr, real SIGWINCH, authoritative renderer size, shared output, coalescing order/cap, stale connection margins | Hangs, dropped input/output, broken terminal dimensions |
| Status/hooks | Structured-hook precedence, split UTF-8, atomic file replacement, repeated-wait gating, malformed user config preservation | Incorrect attention state, notification spam and overwritten configuration |
| Navigation/UI | Back/forward history, scope composition, background launch staying on Home, rename reaching the navigator, overlay hit-testing | Controls that look correct but do the wrong thing |

The real tmux handoff test is particularly valuable: it asks tmux which command actually runs. A mock can verify an intended kill/start sequence but cannot independently prove that `new-session -A` did not reconnect to the source pane.

## Execution and isolation findings

1. **Default UI execution includes documentation and diagnostics.** The ordinary `Flotilla` scheme selects the whole UI target, and [Makefile](../Makefile) uses `-only-testing:FlotillaUITests`. That includes the three screenshot captures and the print-only performance probe. The dedicated screenshot scheme does not exclude those methods from other schemes. Keep screenshots in the serial documentation workflow and separate the probe from regression gating. The screenshot post-action references `Scripts/update-ui-vocabulary-screenshots.sh`, but there is no tracked `Scripts` directory in this checkout; restoring that publisher is a separate prerequisite for the documented publication workflow.
2. **UI workers reset shared fixtures.** `make test-ui` allows three parallel workers. [AppEnvironment](../Flotilla/App/AppEnvironment.swift) deletes/recreates fixed paths including `/tmp/flotilla-uitest-project`, `/tmp/flotilla-uitest-worktrees`, and the fixture worktree on every UI-test launch. Parallel app instances can invalidate each other's edits/deletions. This is a concrete collision risk from source, not a measured flake rate. Use per-worker paths or serialize until isolated; accepting either clean or dirty state is not a substitute.
3. **Useful package tests are outside the selected targets.** [TerminalConnectionMarginsTests](../Packages/TerminalKit/Tests/TerminalKitTests/TerminalConnectionMarginsTests.swift) has two meaningful tests. The package declares its own test target, but the app scheme and [CI workflow](../.github/workflows/build.yml) only invoke app unit/UI targets. Add explicit package execution, such as `rtk swift test --package-path Packages/TerminalKit`, or deliberately relocate/include this coverage. Linking the package product does not run its tests.
4. **“Unit” includes external workloads.** `RealPipelineReproTests` uses hardcoded `/opt/homebrew/bin/tmux` and can launch installed real Claude. Some tmux survival assertions can pass through the direct fallback. `RealHandoffPipelineTests` correctly checks pane identity and locates tmux in multiple places, but still needs reliable readiness and skip-safe cleanup. Keep local shell/tmux integration coverage with explicit dependency setup; make live-provider execution opt-in. CI currently runs both `make test` and `make test-ui`, contrary to the old guide's abbreviated pipeline description.
5. **Isolation is partial.** Transcript codec tests use temporary homes, and tmux uses a process-specific test socket unless overridden; retain those good boundaries. However, `defaultSupportDirectory()` still resolves to Application Support/Flotilla, and several app tests use it. Clipboard tests alter the general pasteboard. UUID settings suites avoid collisions but leave domains behind. Inject these remaining resources and clean up at acquisition time.
6. **Timing and lifetime weaken some useful tests.** Fixed sleeps appear in hooks, metadata, lifecycle and terminal tests. Several negative assertions can pass before the asynchronous work runs; some `for await` loops lack test-level deadlines. Mutable unsynchronized `@unchecked Sendable` fixtures can race. The real SIGWINCH test changes a thread signal mask across async suspension, which may resume on another thread. Preserve the regression scenarios while fixing synchronization and cleanup.

## Where stronger coverage is worth the effort

Repair existing misleading tests before adding volume. After that, prioritize these gaps:

- A real `HookCoordinator` integration case: the current “full pipeline” test assembles the chain itself and therefore cannot catch broken coordinator wiring.
- Output broadcaster ordering/replay/subscriber lifetime and rebind routing, with distinctive old/new process data and bounded waits.
- Save/launch/handoff failures that assert preserved bytes, destination cleanup, user-visible errors and persisted ownership, including recovery after relaunch mid-probation.
- Migration fixtures containing old non-default rows, plus independent native-format fixtures/acceptance checks for transcript codecs. Current schema and round-trip tests are useful but do not prove all historical data or upstream compatibility.
- Selected/unselected-file commit behavior and a local fetch fixture whose remote actually advances. Existing single-file or no-change setups miss wrong-selection and no-op defects.

These are risk-based priorities, not a demand for a test for every branch or property.

## Suggested cleanup sequence

1. Repair the misleading tests in the highest-priority table and isolate parallel UI fixtures. Establish a reliable baseline before cutting coverage.
2. Remove the 21 explicitly low-value methods; consolidate the listed overlaps while preserving unique cases.
3. Separate screenshot/live-provider/performance work and wire the terminal package tests into verification. Keep local Git/PTY/tmux integration coverage.
4. Replace fragile waits and shared resources as their owning suites are touched. Record comparable suite durations and retry/failure history before claiming speed or reliability gains.

This change delivers the audit, inventory and policy only. Test bodies and build selections are unchanged, so the proposed repairs and execution changes remain follow-up work. Documentation links, inventory totals and named test references were checked; the application and suites were not run for this documentation-only change.
