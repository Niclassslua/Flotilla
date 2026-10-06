# Codex CLI

| | |
| --- | --- |
| Binary | `codex` (`AgentCatalog.codexCLI`) |
| Valid through | **0.160.1**, checked 2026-10-06; hook payloads verified through 0.155.0, protocol schema generated and `thread/list` response shape live-probed on 0.160.1 |
| Primary sources | [Codex hooks guide](https://developers.openai.com/codex/hooks), [config reference](https://developers.openai.com/codex/config-reference), [app-server guide](https://developers.openai.com/codex/app-server); captured payloads in `FlotillaUnitTests/ProviderFixtures/codex-cli/` and the 0.160.1 protocol snapshot |
| Code | `HookConfigurationWriter` (`configureCodexHooks`, `launchArguments(.codexCLI)`), `HookEventReceiver` (`.codexCLI`), `CompanionRuntimeLaunch` (`.codexCLI`), `CodexCompanionAdapter`, `CodexSessionProvider`, `CodexTranscriptCodec` |

Codex has two structured channels. Lifecycle **hooks** (inline `--config`)
drive status; a private **app-server** (JSON-RPC over a Unix socket, which
the TUI attaches to with `--remote`) gives the companion live approvals,
questions, plans and streaming text. Flotilla also subscribes directly to
app-server thread status for the board, whether or not the phone companion is
enabled.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | `--config features.hooks=true` plus per-process groups for `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, `UserPromptSubmit`, `SessionStart`, `Interrupt`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`. `PermissionRequest` uses `timeout=86400`. No project file is written | Existing events **Verified** through 0.155.0; additional event names **Documented** in 0.160.1 schema, not live-probed |
| Hook feature flag | `features.hooks` reported disabled by default in 0.149.1, so it is enabled per launch | **Documented** + observed 0.149.1 |
| Hook review | Codex hashes non-managed hook definitions for review. The definition is stable across sessions, so a user approves one shape once (`/hooks` shows it) | **Documented** |
| Event routing | env `FLOTILLA_HOOK_EVENT_FILE` | **Verified** |
| Companion runtime | the session is launched through `<support>/companion-runtimes/<id>.codex.sh`: it starts `codex app-server --listen unix:///tmp/flotilla-cx-<uid>/<id>.sock <copied -c/--config/--enable/--disable args>`, waits for the socket, then runs the TUI with `--remote unix://…`. Env `FLOTILLA_CODEX_REMOTE=1` | code; 0.154 behavior noted in source |
| Session identity | **discovered** after launch (`AgentResumeStrategy.discoverable`); resume is `codex resume <id> …` (leading subcommand) | **Verified** |
| Model / effort | `--model <slug>`; `--config model_reasoning_effort="<level>"` | **Documented** |
| Plan mode | no flag: the goal is withheld from argv and typed as `/plan <goal>\n` (`initialInput`), fresh sessions only | code |
| Host instructions | `--config developer_instructions=<toml string>` (overrides a user's own; Codex has no append form) | code |
| Initial prompt | positional | **Verified** |

The wrapper (`flotilla-codex.sh`) appends Codex's stdin JSON verbatim to the
event file. For `PermissionRequest` only, and only when the session is **not**
on the app-server (`FLOTILLA_CODEX_REMOTE` unset) and `<support>/companion.sock`
exists, it forwards `{"flotilla_provider":"codex","request":<json>}` to the
companion bridge and prints the decision. In every other case it prints
nothing, so Codex's own approval UI stays in charge.

## Status: hooks

Payload shape: flat object with `hook_event_name`, `session_id`, `turn_id`,
`transcript_path`, `cwd`, `model`, `permission_mode`; tool events add
`tool_name`, `tool_input`, `tool_use_id`; `PostToolUse` adds
`tool_response`; `Stop` adds `last_assistant_message`, `stop_hook_active`.
`turn_id` is what distinguishes a Codex payload from a Claude one when reading
raw event files.

| Event (variant) | Fields read | Flotilla status | Evidence |
| --- | --- | --- | --- |
| `PreToolUse` (any tool) | `tool_name` | `working` | **Verified** 0.125.0 (`Bash`), 0.153.4 (`apply_patch`, MCP tools) |
| `PreToolUse` `request_user_input` (or `AskUserQuestion`) | `tool_name` | `waitingForInput` / `question` | **Verified** 0.153.4 — `tool_input.questions[].{id,header,question,options[].{label,description}}` |
| `PermissionRequest` | `tool_name`, `tool_input` | `waitingForInput` / `permission`; also feeds *Top permissions* | **Verified** 0.125.0 (`Bash`), 0.153.4 (`apply_patch`; `tool_input.command` holds the patch) |
| `PostToolUse` | `tool_name` | `working` | **Verified** |
| `UserPromptSubmit` | — | `working` | **Documented** in 0.160.1 schema; registered, not live-probed |
| `Interrupt` | — | `readyForReview` | **Documented** in 0.160.1 schema; registered, not live-probed |
| `Stop`, `last_assistant_message` is a string | — | `readyForReview` | **Verified** 0.125.0 |
| `Stop`, `last_assistant_message: null` | — | `waitingForInput` / `planApproval` (a finished Plan-mode turn) | **Assumed** from an earlier live run; no captured fixture |

Tool names seen: `Bash`, `apply_patch`, `request_user_input`, `webrun`,
`mcp__<server>__<tool>`.

Codex 0.160.1's generated app-server schema includes these lifecycle event
names. Flotilla registers the listed events except `SessionEnd` (process
termination is not a turn status). Compaction and subagent events are logged
without changing the parent status. Payloads and ordering still need live
probes.

## Status: app-server

Flotilla connects a status observer to the same private Unix socket as the
Codex TUI, calls `thread/resume` to subscribe to the native session, then
consumes `thread/status/changed`. It does not send turn-control requests and
runs independently of the phone companion. Hooks and screen observations
remain enabled as fallbacks.

| App-server status | Active flags | Flotilla status | Notes |
| --- | --- | --- | --- |
| `active` | none | `working` | Exact provider runtime state |
| `active` | `waitingOnApproval` | `waitingForInput` / `permission` | |
| `active` | `waitingOnUserInput` | `waitingForInput` / `question` | |
| `idle` | — | `readyForReview` | An initial idle on a new session is ignored |
| `systemError` | — | `readyForReview` | Session remains live so the user can inspect/retry |
| `notLoaded` | — | no change | |

The notification carries `threadId` and `status`. Child-thread notifications
are ignored; only the thread Flotilla launched can change its board card.
Evidence: Codex CLI 0.160.1 generated schema; the `thread/list` response shape
was smoke-tested against an isolated 0.160.1 app-server.

## Status: screen

The generic `TerminalScreenHeuristic` remains as a fallback. Codex draws model, path
and usage footers *below* its `›` composer, which is why
`hasComposerWithTranscript` searches the whole tail and doesn't require the
composer to be the last line. Plan-mode output can contain `<proposed_plan>` /
`proposed plan`, which are plan-approval markers. Working hint: `esc to
interrupt` (**Assumed** current; not recaptured for 0.160.1).

## Dialogs

Companion only. `CodexCompanionAdapter` is a JSON-RPC peer on the app-server
socket.

| Server message | Card | Reply |
| --- | --- | --- |
| `item/commandExecution/requestApproval` | permission "Command" (`params.command`) | `{"decision": "accept"\|"acceptForSession"\|"decline"\|"cancel"}` |
| `item/fileChange/requestApproval` | permission "Edit"; diff from the matching `item/started` `fileChange` item | same |
| `applyPatchApproval`, `execCommandApproval` (legacy v1) | permission | `{"decision": "approved"\|"approved_for_session"\|{"denied":{"rejection":…}}\|"abort"}` |
| `item/tool/requestUserInput` | question steps (`questions[].{id,header,question,options,isMultiple,isOther}`) | `{"answers": {<id>: {"answers": [...]}}}` |
| other `*requestApproval` | `needsTerminal` (answer at the Mac) | — |
| `item/completed` `agentMessage` with `delivery: "async"` + `questions` | question; the answer is sent as the next user message (`turn/steer` or `turn/start`) | — |
| `item/completed` `plan` | plan card "Implement this plan?" | `turn/start` with "Implement the plan." + `collaborationMode: default`, or the revision text |

Approving a plan from the phone first dismisses the TUI's local selection
view with `Esc`. It does this only when the screen contains all of
`Implement this plan?`, `Yes, implement this plan`, `No, stay in Plan mode`
and `esc to go back`, and no turn is running. Other notifications used:
`turn/started`, `turn/completed` (with `error`), `item/agentMessage/delta`,
`serverRequest/resolved`, `thread/settings/updated`, `error` (`willRetry`).
Thread binding uses `thread/loaded/list` + `thread/read` (match `cwd`, skip
sub-agent `source`), then `thread/resume` with `excludeTurns`.

Note from source: *Codex 0.154 accepts and caches `acceptForSession` even
when `availableDecisions` only advertises its TUI's policy choices.*

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Index | `~/.codex/session_index.jsonl` (append-only; latest `thread_name`/`name` wins; `title` is the prompt) | code |
| State DB | `~/.codex/state_5.sqlite`, table `threads(id, name, title, cwd, created_at[_ms], updated_at)`; `created_at_ms` is newer and is used when the column exists | code; the `_5` suffix is a schema version to watch |
| Discovery | `thread/list` with exact `cwd` filtering and cursor pagination; select the earliest thread created after launch. `CodexSessionProvider`'s SQLite/index lookup remains a compatibility fallback if the app-server is unavailable | Response shape **live-probed** on 0.160.1; thread field mapping from generated schema; see `CodexAppServerAccess` |
| Transcript | `~/.codex/sessions/YYYY/MM/DD/rollout-<UTC>-<uuid>.jsonl`, lines `{timestamp,type,payload}`; header `session_meta` carries `cli_version`. The model reads `response_item`; the TUI replays `event_msg`. Handoff writes both | tests; see `../session-handoff.md` |
| Companion transcript | filtered to visible records (`isVisibleCodexRecord`) | code |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `codex debug models` (JSON) | `models[]` with `visibility == "list"`, sorted by `priority`; per-model `supportedReasoningLevels[].effort/description` and `defaultReasoningLevel`; unknown levels dropped | code |
| App-server `model/list` | Structured catalog candidate for replacing the debug command | **Documented** in the 0.160.1 schema; not wired into the pre-session picker |
| Fallback | `gpt-5.6-sol, gpt-5.6-terra, gpt-5.6-luna, gpt-5.5, gpt-5.4, gpt-5.4-mini` | static |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/codex-cli/`: `PreToolUse` (`Bash`,
`request_user_input`), `PermissionRequest` (`Bash`, `apply_patch`),
`PostToolUse` (`apply_patch`), `Stop`. Missing: `Stop` with a `null`
message (Plan mode), and any screen.

## Update checklist

1. `codex --version`; `codex features list` (or equivalent): is `hooks` still
   a feature flag, now on by default, or renamed?
2. `/hooks` in a session shows the four Flotilla groups as active.
3. Run a Plan-mode turn and capture the `Stop` payload. Is
   `last_assistant_message` still `null`? This is the only plan signal on
   the hook path.
4. App-server: `codex app-server --listen unix://…` still exists, and the TUI
   still accepts `--remote`. Approval method names and reply schemas are
   unchanged (`item/*/requestApproval`, decisions `accept…`).
5. `state_5.sqlite` still exists (or `state_6`?), with the `threads` columns
   above.
6. `codex debug models` JSON keys.
7. Capture a working screen and confirm the interrupt hint.

## Open items

- **Observed, cause not investigated:** in one 0.155.0 session (2026-09-18)
  the event file contains Codex payloads wrapped in Antigravity's
  `{"event":…,"payload":…}` envelope, and no native lines. So Codex ran
  `flotilla-antigravity.sh` from the project's `.agents/hooks.json`. The
  0.160.1 binary has external-agent migration code that reads `.agents` and
  `hooks.json`. If Codex now loads `.agents/hooks.json`, its sessions in
  projects where Antigravity ran get a second hook path that
  `HookEventReceiver(.codexCLI)` silently ignores (no top-level
  `hook_event_name`). The PreToolUse wrapper also prints
  `{"decision":"allow"}`, which Codex may interpret.
- The `Stop`-null-means-plan rule has no captured fixture.
- `thread/name/set` and `thread/name/updated` can provide two-way title sync;
  currently unused.
- `turn/completed` carries completed/interrupted/failed, and
  `turn/plan/updated` carries structured plan changes. The companion handles
  failures and plan cards; board-specific failure details and live plan
  updates remain unused.
- `model/list` is a candidate replacement for `codex debug models`, but the
  model picker runs before a session app-server exists; compare catalog shape
  and authentication before switching.
- `codex queue --thread --message` duplicates delivery through the attached
  app-server's `turn/start`/`turn/steer`; add only if a concrete use case needs
  a separate path.
- `codex archive` is a safer handoff cleanup candidate than deleting the
  rollout file; source cleanup currently removes transcript files only.
