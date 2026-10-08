# Testing for value in Flotilla

A test earns its place by catching a plausible regression that matters to a user, with a failure that tells us what broke. Test count and coverage percentage are diagnostic information, not goals. A small test can protect a critical contract; a long test can prove nothing.

The [test suite audit](test-suite-audit.md) records the existing suite's dispositions. This document is the policy for new and changed tests.

## The admission rule

Before writing a test, finish this sentence:

> If **this behavior breaks**, the user will **experience this consequence**; **this assertion** will detect it.

For example: if restoring a session sends its original goal again, an agent can repeat destructive work; assert that the resumed process receives neither that prompt argument nor initial input. “This file needs tests” is not a justification.

Choose the smallest test that crosses the boundary responsible for the failure. An additional layer needs an additional reason to exist. Do not add tests for reversible styling changes, stored-property assignment, or framework behavior we do not implement.

## Paradigms to use

### Behavior over implementation

Drive a production entry point and observe its result. Prefer persisted state, emitted bytes, selected session identity, file contents, or an external command's effect over private helper calls.

Never copy the production algorithm into the test and assert on the copy. The filtering tests at the start of `ProjectOverviewTests` filter their own arrays; changing the app cannot make them fail. Exercise the real scope or navigation policy instead.

Interaction assertions are useful when the interaction is the contract: killing the old tmux pane before starting the destination, refusing to call checkout on a dirty tree, or avoiding a second process during reload. Internal call counts without such a consequence are incidental.

### Risk determines depth

Spend the most attention on lost or modified user work, conversation ownership, session/process lifetime, compatibility with saved data, and terminal input/output correctness.

| Boundary | Preferred test | Flotilla example |
|---|---|---|
| Pure decision or transformation | Small XCTest with explicit inputs and expected outputs | Status transition matrix, diff parsing, scope intersection, tool-call pairing |
| App command and collaborators | Real store/domain code with controlled external services | Failed worktree creation leaves no session; failed handoff preserves history |
| Persistence or filesystem | Real temporary database/files; read back independently | Upgrade an old schema; reopen a saved repository; verify saved rule text |
| Git or PTY semantics | Real local integration using disposable resources | Unstage retains edits; SIGWINCH reaches the child; restart replaces the tmux pane |
| UI wiring | Targeted XCUITest of an interaction and its observable consequence | Background launch stays on Home; rename reaches the navigator; shortcut selects the right workspace |
| Appearance | Manual visual inspection and documentation captures | Palette, spacing, icons, truncation, visual hierarchy |

Unit and integration coverage can complement each other. A command-argument test localizes a provider-launch defect; a real subprocess test verifies that those arguments and environment reach the child. Keep both when they catch different mistakes.

### Explicit examples plus invariants

Use examples for protocol edge cases and known regressions. Use invariants for families of valid inputs: graph edges join across rows, legal status transitions update timestamps, an unrelated session survives cleanup, and a transcode preserves supported conversation entries in order.

For parsers and mappings, group equivalent cases in a small table with descriptive assertion messages. Keep distinct failure scenarios separate when that improves diagnosis. The goal is fewer repeated fixtures, not fewer test method names at any cost.

Use an independent expected result where correctness depends on an external format. Writer/reader round trips can agree on the same mistake. Pair round trips with explicit native records, structural assertions, and, where needed, versioned sanitized fixtures captured from the provider. Do not compute expected output by calling the same production helper as the subject.

### Regression tests reproduce the failure

For a bug fix, make the relevant test fail with the old behavior before accepting the fix, when practical. For a new behavior, reason through a small deliberate defect: remove the action, invert the guard, drop the final chunk, or substitute the wrong session ID. The test should fail for the stated reason.

This is a focused counterexample check, not a requirement to run repository-wide mutation tooling. A green test that would also be green after deleting the behavior provides false confidence.

## Assertion rules

1. **Establish the precondition.** A test of blank commit-message validation needs staged changes, otherwise the “nothing staged” guard explains the result. A test of moving status must start in a different status.
2. **Assert after the action.** Typing into Settings is setup; observing the changed setting after reopening or in a subsequent launch is the result. Typing a unique terminal probe requires observing that probe in terminal output.
3. **Required steps must be required.** Do not put the feature's only assertion inside `if button.exists`. Wait, assert that the control exists, then interact. Use `XCTUnwrap` or a failing guard when later steps cannot run meaningfully.
4. **A test's name must match its evidence.** “Persists” requires a repository/disk read, “failure” requires injected failure, “lossy UTF-8” requires malformed bytes, and “order” requires observing order. Rename a useful narrower test or strengthen it.
5. **Check preservation as well as change.** A delete test should show the target is gone and an unrelated item remains. A failed save should preserve the draft. A handoff rollback should preserve source bytes and restore identity.
6. **Use distinguishing data.** Different old/new values, two different sessions, unique edit markers, and distinct head/tail bytes reveal wrong-target and stale-result bugs that counts or generic strings miss.
7. **No non-optional non-nil checks.** Constructing a SwiftUI struct and asserting that it exists tests the language. A resource lookup returning an optional image can be a useful packaging smoke test; constructor success alone cannot.
8. **Do not freeze aesthetics.** Avoid exact RGB, opacity, padding, symbol choice, and ordinary copy assertions. Preserve meaningful accessibility labels, machine-readable keys, provider flags, and protocol values. Graph topology and palette index bounds are algorithmic correctness, not screenshot styling.

## Determinism and isolation

- Inject time for debounce, retry, probation, and date grouping where practical. Advance controlled time instead of sleeping through production delays. For real asynchronous boundaries, wait for a bounded observable condition; a timeout must fail explicitly.
- For negative asynchronous assertions, first prove the worker reached the relevant point. “Nothing happened after 80 ms” can pass because the task never ran.
- Bound stream collection and subprocess execution. Register cleanup immediately after acquiring a process, file, directory, or task. Make it work if a later `XCTUnwrap` throws.
- Give every test or worker its own fixture root, settings domain, and external-process namespace. Inject the support directory and fake provider home as well as the database. `UI_TESTING=1` does not make manually constructed services or the filesystem automatically isolated.
- Parallelize only independent resources. Current UI fixture paths are shared across app launches; until those are unique, run the affected UI tests serially. Restore or inject clipboard state instead of leaving `NSPasteboard.general` changed.
- Tests using Git must configure local author identity and disable unwanted inherited hooks/signing/config as needed in the disposable fixture. Setup commands must verify exit status; the command runner intentionally returns nonzero exits.
- A missing optional binary can cause an explicit `XCTSkip` in an optional integration lane. A required CI lane must install/check that dependency and treat its absence as failure. Never silently fall back to a different backend in a test claiming to exercise tmux.
- Real agent CLIs belong in an explicit compatibility workflow with isolated homes/configuration and recorded versions. An installed CLI is not, by itself, a reason for an ordinary unit run to launch it.

## Mocks and external contracts

Use mocks at boundaries to control failures and scheduling. Exercise real decision code inside that boundary. Prefer the existing `CommandRunning`, `PTYProcessCreating`, repository, git, transcript, and metadata seams.

Keep a compact contract suite for complicated test doubles used by many tests, especially stream delivery and termination. Do not grow a parallel CRUD suite merely proving each mock returns the value assigned to it. Such tests do not verify Git, GitHub, or the real PTY.

For emitted scripts/plugins, checking for a substring establishes only that the text is present. When event routing is the risk, invoke the generated handler with a fixture payload and inspect the intended event file. Retain external acceptance checks separately from offline format checks.

## UI tests and diagnostic artifacts

UI tests should verify wiring that lower layers cannot establish. Retain a small set of journeys for session creation, focus, filtering, deletion, rename, shortcuts, and editing. Test the actual resulting session or content rather than the presence of a generic toolbar.

Do not combine unrelated journeys merely to reduce app launches: an early failure hides later coverage. Share reliable setup, and combine steps only when they form one meaningful user journey.

Print-only diagnostics such as `ZZPerfProbeUITests` do not belong in a pass/fail regression suite. Performance checks need a defined workload, a completion condition, a justified threshold or baseline, and output that identifies the regression. Prefer a deterministic work bound where possible; measure wall-clock regressions in a controlled performance lane when machine load affects the verdict.

## Choosing verification

These are selection rules, not newly implemented build targets. Existing entry points remain `make test`, `make test-ui`, and targeted `xcodebuild -only-testing` selections.

- **Documentation-only:** validate links, claims, and diffs; an app build does not validate prose.
- **Behavior change:** run focused tests covering the changed contract, build when code changed, and run the unit suite as the repository's normal completion check.
- **UI/lifecycle/terminal wiring:** add the smallest relevant UI selection when it can exercise the changed behavior, following the UI-test scope rules in `AGENTS.md`.
- **External integration:** run the relevant local Git/PTY/tmux checks with explicit dependencies and isolation. Ensure package test targets are actually selected; the app's unit target does not include `Packages/TerminalKit/Tests`.
- **Broader execution:** CI should retain a dependable regression baseline, including a curated UI lane. Keep documentation capture, live-provider compatibility, and performance diagnostics separate. Do not claim runtime savings without comparable before/after results.

## Test review checklist

- What user consequence does this prevent?
- Which production behavior does it exercise, and would a plausible defect make it fail?
- Does the fixture reach the named condition and distinguish the expected outcome from a no-op?
- Is this already covered against the same implementation with the same boundary and failure sensitivity?
- Can it run independently, fail promptly, and clean up after failure?
- Is its execution lane appropriate, and is that lane actually selected?

If those answers are weak, improve or omit the test. A code change does not owe us a test that cannot answer them.
