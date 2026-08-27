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
  └─ maps structured events                 └─ classifies terminal UI
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
| Claude Code | Per-process `--settings <json>` | `Notification` | `waitingForInput` | Provider payload already contains `hook_event_name`. |
| Claude Code | Per-process `--settings <json>` | `Stop` | `ready` | Project settings remain additive and untouched. |
| Codex CLI | Per-process inline `--config` hooks | `PostToolUse` | `working` | The stable support wrapper copies Codex's self-describing JSON stdin; no project file is changed. |
| Codex CLI | Per-process inline `--config` hooks | `PermissionRequest` | `waitingForInput` | Wrapper exits 0 with no stdout, so the normal approval UI remains authoritative. |
| Codex CLI | Per-process inline `--config` hooks | `Stop` | `ready` | Hook execution is enabled for the launch with `features.hooks=true`. |
| OpenCode | Stable `.opencode/plugins/flotilla-status.js` | `tool.execute.after` | `working` | Legacy per-session Flotilla plugins are removed on configuration. |
| OpenCode | Stable project plugin | `permission.asked`, `question.asked` | `waitingForInput` | The event handler is observational and supplies no decision. |
| OpenCode | Stable project plugin | `session.idle` | `ready` | OpenCode's `idle` means the turn ended and the composer is available. |
| Antigravity | Stable `.agents/hooks.json` `flotilla-status` group | `PreToolUse` | `working` | `ask_question` is mapped to `waitingForInput` instead. |
| Antigravity | Stable shared hook group | `PostToolUse` | `working` | Wrapper adds the event name because the provider payload omits it. |
| Antigravity | Stable shared hook group | `Stop` with `fullyIdle: true` | `ready` | `fullyIdle: false` is ignored while asynchronous work remains. |

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
names. Unknown events, malformed lines, missing files, and provider payloads
without required fields produce no status. `start()` and `stop()` are
idempotent and lock-protected; deinitialization cancels polling and finishes
the stream.

### `HookCoordinator`

Runs one `HookEventReceiver` and one `SessionScreenMonitor` for each live
process. Both sources use the same status funnel and `SessionStatusMachine`,
so illegal terminal-state transitions are rejected centrally. A
`WaitingNotificationGate` sends one notification per waiting episode rather
than one per poll or hook event.

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
- Competing status source: all changes still pass through
  `SessionStatusMachine`; unchanged and illegal transitions are no-ops.

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
the three Flotilla event groups are active.

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
