# Provider status hooks

Flotilla combines provider-native lifecycle events with terminal-screen
classification to keep each session's status accurate. Native hooks supply
structured edge events such as a completed tool call or approval request;
the screen monitor remains active as a resilient fallback for provider UI
states that hooks cannot expose.

This feature supports Claude Code, Codex CLI, OpenCode, and Antigravity.

## Data flow

```text
SessionProcessManager.start
  ├─ HookConfigurationWriter.configureHooks
  │    ├─ truncates <support>/hooks/<session UUID>.jsonl
  │    └─ prepares provider-specific hook configuration
  ├─ exports FLOTILLA_HOOK_EVENT_FILE to the provider process
  └─ adds per-launch hook arguments when the provider supports them

Provider hook/plugin
  └─ appends one self-describing JSON object per line

HookEventReceiver                       SessionScreenMonitor
  └─ maps status + waiting reason            └─ classifies terminal UI
                    └──────────┬───────────┘
                         HookCoordinator
                              ├─ AppStore.applyObservedStatus
                              ├─ agent-title synchronization
                              └─ waiting notification gate
```

The event file is a transport boundary, not durable application state. It is
truncated before every launch. `HookEventReceiver` tracks file identity as
well as byte offset, so an atomically replaced file cannot cause events at the
start of a new launch to be skipped. Incomplete UTF-8 and JSONL records remain
buffered until their terminating newline arrives.

## Session isolation

Project-local hook configuration is shared by every provider process launched
from the same working directory. A hook entry per session therefore does not
provide isolation: each process runs every entry, and each OpenCode process
loads every project plugin.

Flotilla instead installs one stable shared hook per provider and exports this
process-scoped value:

```text
FLOTILLA_HOOK_EVENT_FILE=<support>/hooks/<session UUID>.jsonl
```

The stable shell wrapper or plugin reads the variable at event time. An event
from process A can consequently write only to process A's event file even when
several sessions share a project. If the variable is absent, generated hooks
are inert. This also keeps shared configuration bounded as sessions are
created and deleted.

## Provider behavior

| Provider | Installation | Structured event | Flotilla status | Notes |
| --- | --- | --- | --- | --- |
| Claude Code | Per-process `--settings <json>` | `PostToolUse` | `working` | Does not modify `.claude/settings.json`. |
| Claude Code | Per-process `--settings <json>` | `PreToolUse` for `AskUserQuestion` / `ExitPlanMode` | `waitingForInput` (`question` / `planApproval`) | Exact interactive-tool signal. |
| Claude Code | Per-process `--settings <json>` | `PermissionRequest` | `waitingForInput` (`permission`, or the interactive-tool reason) | Exact approval signal. |
| Claude Code | Per-process `--settings <json>` | `Notification` | `readyForReview` for `idle_prompt`; waiting for `permission_prompt` / `elicitation_dialog` | Notification subtype is retained instead of treating every notification as blocked. |
| Claude Code | Per-process `--settings <json>` | `Stop` | `readyForReview` | Project settings remain additive and untouched. |
| Codex CLI | Per-process inline `--config` hooks | `PreToolUse` | `working`, or `waitingForInput` (`question`) for `request_user_input` | Gives questions a structured reason before the answer arrives. |
| Codex CLI | Per-process inline `--config` hooks | `PostToolUse` | `working` | The stable support wrapper copies Codex's self-describing JSON stdin; no project file is changed. |
| Codex CLI | Per-process inline `--config` hooks | `PermissionRequest` | `waitingForInput` (`permission`) | Wrapper exits 0 with no stdout, so the normal approval UI remains authoritative. |
| Codex CLI | Per-process inline `--config` hooks | `Stop` | `readyForReview`, or `waitingForInput` (`planApproval`) when Plan mode reports a null normal assistant message | Hook execution is enabled for the launch with `features.hooks=true`. |
| OpenCode | Stable `.opencode/plugins/flotilla-status.js` | `tool.execute.after` | `working` | Legacy per-session Flotilla plugins are removed on configuration. |
| OpenCode | Stable project plugin | `permission.asked`, `question.asked` | `waitingForInput` (`permission` / `question`) | The event handler is observational and supplies no decision. |
| OpenCode | Stable project plugin | `session.idle` | `readyForReview` | OpenCode's `idle` means the turn ended and the composer is available. |
| Antigravity | Stable `.agents/hooks.json` `flotilla-status` group | `PreToolUse` | `working` | `ask_question` maps to `waitingForInput` (`question`) instead. |
| Antigravity | Stable shared hook group | `PostToolUse` | `working`, or `waitingForInput` (`planApproval`) when an artifact requests plan feedback | Wrapper adds the event name because the provider payload omits it. |
| Antigravity | Stable shared hook group | `Stop` with `fullyIdle: true` | `readyForReview` | `fullyIdle: false` is ignored while asynchronous work remains. |

`SessionStatus` is the broad board/filter state and has four values:
`working`, `waitingForInput`, `readyForReview`, and `crashed`. A session
that has produced no signal yet — created, but not yet observed doing or
finishing anything — has **no** status (`Session.status` is `nil`); it sits
in the board's "Unstarted" column and shows no status badge. Once set, a
status never returns to `nil`. `readyForReview` folds in what were two
separate states — `idle` (a quiet end-of-turn) and `finished` (a clean
process exit) — and is not terminal. `crashed` is: it reopens only through
`working`, where an explicit restart lands.

When the status is `waitingForInput`, `SessionWaitingReason` supplies the
action shown in the UI: `permission` → **Needs Permission**, `question` →
**Needs Answer**, and `planApproval` → **Plan Ready**. The reason is
persisted with the session and cleared whenever the session leaves
`waitingForInput`.

Antigravity interprets `PreToolUse` stdout as a live decision. Every generated
wrapper therefore returns `{"decision":"allow"}` for that event after
recording it. Tool and file approval dialogs are not visible to Antigravity's
hook surface and continue to depend on `TerminalScreenHeuristic`.

Codex's lifecycle schema and the no-output success behavior are documented in
the official [Codex Hooks guide](https://developers.openai.com/codex/hooks) and
[configuration reference](https://developers.openai.com/codex/config-reference).
Codex 0.149.1 reports the stable `hooks` feature as disabled by default, so
Flotilla enables it only for the launched session. Codex hashes non-managed
hook definitions for review. Because Flotilla's
definition is stable rather than session-specific, a user reviews one hook
shape instead of a new machine-path entry for every session.

## Reaching each status

Two independent sources move a session between states: the provider hook
stream (`HookEventReceiver`) and the rendered terminal
(`SessionScreenMonitor` / `TerminalScreenHeuristic`). Either can reach any
state below. `SessionStatusObservationArbiter` lets structured hook-reported
work or waiting survive a contradictory screen fallback until the provider
reports the terminal state. Every accepted observation must still be a legal
`SessionStatusMachine` transition.

Each cell lists the hook event(s) that map to that status for that provider.
The **Terminal-screen fallback** row is shared by every provider and stays
active even when hooks are wired; its general markers inspect only the bottom
`inspectedTailLines` (8) non-empty lines, case-insensitively. Antigravity's
long permission picker additionally uses a 24-line window, but only when its
exact `Requesting permission for:` heading and a live choice list both appear.
A dash means no hook event of that provider produces the status — it is reachable only
through the screen fallback (or, for `crashed`, only through an
authoritative process exit). In the **Waiting** column, `→ reason` is the
`SessionWaitingReason` persisted with the status: `permission` → **Needs
Permission**, `question` → **Needs Answer**, `planApproval` → **Plan Ready**.

There is no column for the absence of a status (`nil`, "Unstarted"): no hook
or screen observation produces it. It is only ever the value a session is
created with, before its process has been observed doing anything.

| Source | Working | Waiting (`waitingForInput`) | Ready for Review | Crashed |
| --- | --- | --- | --- | --- |
| **Claude Code** | `PostToolUse`; `PreToolUse` for any tool other than `AskUserQuestion` / `ExitPlanMode` | `PreToolUse` or `PermissionRequest` for `AskUserQuestion` → `question`, for `ExitPlanMode` → `planApproval`; any other `PermissionRequest` → `permission`; `Notification`/`permission_prompt` → `permission` (`planApproval` if the message mentions a plan); `Notification`/`elicitation_dialog` → `question` | `Stop`; `Notification`/`idle_prompt` | — |
| **Codex CLI** | `PostToolUse`; `PreToolUse` for any tool other than `request_user_input` / `AskUserQuestion` | `PreToolUse` for `request_user_input` / `AskUserQuestion` → `question`; `PermissionRequest` → `permission`; `Stop` with `last_assistant_message: null` → `planApproval` (Plan mode) | `Stop` with a non-null `last_assistant_message` | — |
| **OpenCode** | `tool.execute.after` | `permission.asked` → `permission`; `question.asked` → `question` | `session.idle` | — |
| **Antigravity** | `PostToolUse` with no plan-feedback artifact; `PreToolUse` for any tool other than `ask_question` | `PreToolUse` for `ask_question` → `question`; `PostToolUse` whose `write_to_file` args carry `ArtifactMetadata.RequestFeedback = true` → `planApproval` | `Stop` with `fullyIdle: true` (`fullyIdle: false` yields no observation) | — |
| **Terminal-screen fallback** (every provider) | an interrupt/cancel hint — `esc to interrupt`, `esc to cancel`, `ctrl+c to stop`, and close variants — in the inspected tail | the inspected tail matches a plan-approval, permission, or question marker; shows a numbered choice list with a selection caret; matches Antigravity's extended permission-picker signature; or the prompt heuristic reads the prompt as waiting | anything else: a composer prompt with transcript above it, a dead-pane marker (`agent exited`, `pane is dead`, `process finished`), or an otherwise unremarkable screen | — |
| **Process exit** | — | — | exit status code 0 (also fires `onSessionFinished`) | any non-zero exit code, or a launch/relaunch failure |

`SessionStatusMachine` shapes which of these are reachable when:

- `working`, `waitingForInput`, and `readyForReview` interchange freely, so a
  session that looked review-ready and then resumes work simply moves back.
- `crashed` is near-terminal: it reopens only via `working`, which is where
  an explicit restart lands. No screen- or hook-derived status can leave it.
- A session with no status yet (`nil`) accepts any first value.

A screen `readyForReview` is dropped by `SessionStatusObservationArbiter`
while the most recent hook observation was `working` or `waitingForInput`, so
an in-flight tool sequence or recognised Plan Ready / permission event is not
undone by an intermediate, unrecognised redraw. A provider hook reporting the
terminal state ends that hold; visible screen work also starts a new episode
after a prior hook-reported waiting state.

## Components

### `HookConfiguring`

The injected service boundary used by `SessionProcessManager`. Its concrete
implementation prepares hook files and returns any provider launch arguments.
Configuration is deliberately best-effort: `false` means “launch without the
native hook path,” never “fail the session.”

### `HookConfigurationWriter`

Owns provider configuration and generated support files. The shared
Antigravity JSON update has three safeguards:

1. An in-process lock serializes concurrent launches.
2. A support-directory advisory lock serializes multiple Flotilla processes.
3. Existing JSON must parse with the expected object/array shape. Malformed or
   unfamiliar structure fails closed and is left byte-for-byte untouched.

Writes use atomic replacement and preserve unrelated top-level keys. Flotilla
owns the Antigravity `flotilla-status` namespace. Claude and Codex use
per-launch configuration and never modify their project settings.

Generated files are:

```text
<support>/hooks/<session UUID>.jsonl
<support>/hooks/flotilla-antigravity.sh
<support>/hooks/flotilla-codex.sh
<support>/hooks/shared-config.lock
<working directory>/.agents/hooks.json
<working directory>/.opencode/plugins/flotilla-status.js
```

The project-local files remain safe after Flotilla exits because their hooks
do nothing without `FLOTILLA_HOOK_EVENT_FILE`.

### `HookEventReceiver`

Tails one session's JSONL file at a 400 ms interval and maps only known event
names into `SessionStatusObservation` values. Unknown events, malformed lines,
missing files, and provider payloads without required fields produce no
observation. `start()` and `stop()` are
idempotent and lock-protected; deinitialization cancels polling and finishes
the stream.

### `HookCoordinator`

Runs one `HookEventReceiver` and one `SessionScreenMonitor` for each live
process. Both sources use the same observation funnel and
`SessionStatusMachine`, so an illegal `crashed → …` transition is rejected
centrally. A structured `waitingForInput` hook observation outranks an
ambiguous screen `readyForReview` fallback, preventing the fallback poller
from immediately undoing an exact event. A
`WaitingNotificationGate` sends one notification per waiting episode rather
than one per poll or hook event.

## Debugging a status change

Every status a session takes is traced to the unified log under subsystem
`com.niclassslua.flotilla`, category `SessionStatus` (`SessionStatusTrace` in
`Flotilla/Services/`). Watch it live:

```
log stream --style compact \
  --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionStatus"'
```

Add `--level debug` for the full picture, or read the recent past with
`log show --last 30m` and the same predicate.

Three line shapes, in increasing granularity:

| Level | Line | Means |
|-------|------|-------|
| `notice` | `1f3c9a20 Fix parser working → readyForReview — hook: Stop` | the change landed, and what caused it |
| `info` | `1f3c9a20 Fix parser stayed crashed, asked for readyForReview — SessionStatusMachine refused the transition (screen: …)` | something asked for a status and did not get it |
| `debug` | `1f3c9a20 Fix parser [Claude Code] observed hook waitingForInput/question ← hook: PreToolUse AskUserQuestion \| question=Which approach? (was working) → accepted` | every observation, with session context, payload content, and arbiter verdict |

The `debug` line is self-contained: session title, agent kind, observation
source and status, the payload summary (after `|`), the session's current
status (after `was`), and the arbiter verdict (`accepted` or
`suppressed — <reason>`). A suppressed observation looks the same except for
the verdict:

```
1f3c9a20 Fix parser [Claude Code] observed screen readyForReview ← screen: prompt heuristic (was waitingForInput/question) → suppressed — screen readyForReview outranked by pending hook waitingForInput/question
```

The text after `—` on an applied line is the origin (`SessionStatusOrigin`),
which distinguishes the mechanisms that are indistinguishable in the UI: a
provider hook event by name, the exact screen marker `TerminalScreenHeuristic`
matched, a process exit and its code, a user dragging a card on the board, and
the launch/restart/restore paths. So "why is this Ready for Review?" is
answered by one line — `hook: Stop`, `screen: composer prompt above a
non-empty transcript`, `screen: no marker matched — default`, or
`process exit code 0`.

Session IDs are abbreviated to their first eight characters; grep for that
prefix to follow one session end to end.

## Failure behavior

- Event-file creation failure: provider configuration is skipped; the session
  still launches and screen monitoring continues.
- Read-only project configuration: shared hook setup returns `false`; existing
  provider configuration is unchanged.
- Malformed or unexpected user JSON: setup returns `false` and never replaces
  the file.
- Missing or malformed JSONL records: receiver ignores them and continues.
- Event file replaced on restart: receiver resets its generation and reads
  from byte zero.
- Unknown provider event: no status transition.
- Competing status source: a structured `waitingForInput` observation
  suppresses a weaker screen `readyForReview` fallback; accepted changes
  still pass through `SessionStatusMachine`, where unchanged and illegal
  transitions are no-ops.

## Testing

The focused unit coverage lives in `FlotillaUnitTests/HooksKitTests.swift` and
`FlotillaUnitTests/AppLayerTests.swift`. It covers:

- event-to-status mappings for all providers;
- malformed/unknown payload handling;
- split UTF-8 records and atomic event-file replacement;
- stable script/plugin generation and executable permissions;
- repeated-launch idempotence and legacy OpenCode cleanup;
- preservation of unrelated and malformed user configuration;
- process environment and Claude launch-argument wiring.

Run the focused tests with:

```bash
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData test \
  -only-testing:FlotillaUnitTests/HookEventReceiverTests \
  -only-testing:FlotillaUnitTests/HookConfigurationWriterTests
```

Use provider CLIs for end-to-end validation because unit tests verify the
generated contracts, not whether a third-party release fires every documented
event. For Codex, open `/hooks` to review the session hook source and confirm
the four Flotilla event groups are active.

## Adding or changing a provider

1. Confirm the provider's event input and output contract from primary
   documentation and, where decisions are involved, a live CLI run.
2. Prefer per-process launch configuration. If only project configuration is
   available, install one stable hook and route via
   `FLOTILLA_HOOK_EVENT_FILE`.
3. Treat decision-bearing hooks as safety-critical. Never emit an allow/deny
   response unless the provider contract is known.
4. Preserve existing configuration and fail closed on an unknown schema.
5. Add the event mapping in `HookEventReceiver.status(forLine:agent:)`.
6. Keep terminal monitoring enabled for states the hook surface cannot see.
7. Add configuration, mapping, isolation, relaunch, and malformed-input tests.
8. Live-verify shared-project behavior with two simultaneous sessions, not
   only two installed hook files.
