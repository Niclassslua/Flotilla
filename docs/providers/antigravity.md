# Antigravity

| | |
| --- | --- |
| Binary | `agy` (`AgentCatalog.antigravity`) |
| Valid through | **1.3.0**, verified 2026-10-06: live probe of every hook event, the `PreToolUse` decision matrix, the confirmation picker, `PreInvocation` injection, interrupt, `--effort`, the user-level hooks file and the `--log-file` markers. Older payloads 2026-09-11 |
| Primary sources | [Antigravity hooks](https://antigravity.google/docs/hooks/); `agy --help`; captured payloads in `FlotillaUnitTests/ProviderFixtures/antigravity/`; [`Antigravity/FORMAT.md`](../../Packages/TranscriptKit/Sources/TranscriptKit/Codecs/Antigravity/FORMAT.md) |
| Code | `HookConfigurationWriter.configureAntigravityHooks`, `HookEventReceiver` (`.antigravity`), `TerminalScreenHeuristic` (permission picker, interrupt), `AntigravityCompanionAdapter`, `AntigravityWorkspaceTrust`, `ProcessAgentConversationOwnershipChecker`, `ExperimentalAntigravitySessionProvider`, `AntigravityTranscriptCodec` |

Antigravity is the most screen-dependent provider. Its hooks report turn
start, tool calls, questions and turn end, but **tool and file approval
dialogs are invisible to every hook it exposes, and a hook cannot answer
them**. Permission waits therefore come from the screen. The companion
combines three sources: hook payloads (what was asked), the `--log-file`
(whether it is still open), and the screen (which keys answer it).

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | One `flotilla-status` group in the **user-level** `~/.gemini/config/hooks.json`: `PreToolUse` and `PostToolUse` (matcher `*`), `PreInvocation`, `Stop`, each `timeout: 10`. Nothing is written into projects; the group older releases put into `<cwd>/.agents/hooks.json` is removed on launch (and the file too, if that group was all it held). The merge is locked in-process and with `lockf` on `<support>/hooks/shared-config.lock`, fails closed on unfamiliar JSON, and keeps other keys | **Verified** 1.3.0 (agy reads the user-level file) |
| Hook command | Constant for every session and install: `event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] \|\| exit 0; wrapper="$(dirname "$event_file")/flotilla-antigravity.sh"; [ -x "$wrapper" ] \|\| exit 0; exec "$wrapper" <Event>`. It is inert in every agy process Flotilla didn't launch | **Verified** 1.3.0 (env-gated global hook fires only with the variable) |
| Wrapper | Writes `{"event":"<argv1>","payload":<stdin>}` (the payload names no event). Prints **nothing** for `PreToolUse`, since 1.3.0 treats a silent hook exactly like no hook. On `PreInvocation` it prints and consumes `<event file>.queue` (prompts the phone sent mid-turn, as `injectSteps`) | **Verified** 1.3.0 |
| Workspace trust | Before launch, `AntigravityWorkspaceTrust.ensureTrusted` adds the raw, standardized and symlink-resolved cwd to `trustedWorkspaces` in `~/.gemini/antigravity-cli/settings.json`, 0600, `lockf` on `.flotilla-trust.lock`. Throws if `trustedWorkspaces` is not an array | code; prompt text **Verified** 1.3.0 |
| Ownership guard | Resuming a conversation that `ps -axo command=` shows running elsewhere is refused (`conversationAlreadyActive`), unless Flotilla's own tmux session holds it | code |
| Companion log | `--log-file <support>/companion-runtimes/<id>.agy.log` | **Verified** 1.3.0 |
| Session identity | **discovered**; resume `--conversation <id>` | code |
| Model / effort | `--model <slug>`, with effort baked into the slug (`gemini-3.8-flash-low`); the slug resolves once agy has fetched its model list (`Propagating selected model override … "Gemini 3.8 Flash (Low)"`). 1.3.0 also has `--effort low\|medium\|high\|xhigh\|max`, but only with a bare family name: `--model gemini-3.8-flash --effort high` = `gemini-3.8-flash-high`. With an effort slug it errors (`conflicts with --effort`), and models without levels reject it (`claude-sonnet-4-6`). Flotilla keeps the slug | **Verified** 1.3.0 |
| Plan mode | `--mode plan`, fresh sessions only. 1.3.0's default mode is `accept-edits` | code; Help 1.3.0 |
| Initial prompt | `--prompt-interactive <text>` | code |

The trust prompt that `AntigravityWorkspaceTrust` pre-empts (screen fixture
`trust-prompt.txt`):

```text
Accessing workspace:
<path>
Do you trust the contents of this project?
Antigravity CLI requires permission to read, edit, and execute files here.
> Yes, I trust this folder
  No, exit
```

### `PreToolUse` decisions (1.3.0 probe, `toolPermission: request-review`)

| Hook stdout | Confirmation picker | Tool runs |
| --- | --- | --- |
| nothing | shown | as the user answers |
| `{"decision":"allow"}` | **shown** | as the user answers |
| `{"decision":"allow","permissionOverrides":["command(rm x)"]}` | **shown** | as the user answers |
| `{"decision":"deny","reason":"…"}` | not shown | no ("denied by a pre-tool hook: …"), and no `PostToolUse` |

A hook can refuse but never approve, so the phone answers approvals with
key presses (below). With the user's usual `toolPermission:
"always-proceed"`, no picker appears at all.

## Status: hooks

Common payload fields: `artifactDirectoryPath`, `conversationId`,
`modelName`, `transcriptPath`, `workspacePaths[]`.
- Tool events add `stepIdx` and `toolCall.{name,args}` (`args` include
  `toolAction`/`toolSummary`); `PostToolUse` adds `error`.
- `PreInvocation`/`PostInvocation` carry `invocationNum` and `initialNumSteps`.
- `Stop` carries `fullyIdle`, `executionNum`, `terminationReason` and `error`.

| Event (variant) | Fields read | Flotilla status | Evidence |
| --- | --- | --- | --- |
| `PreInvocation` | `invocationNum` | `working`: before every model call, the first of a turn included | **Verified** 1.3.0 — `pre-invocation` |
| `PreToolUse` (any tool) | `toolCall.name` | `working` | **Verified** — `run_command` (1.3.0), `view_file`, `grep_search`, `replace_file_content`, `write_to_file` |
| `PreToolUse` `ask_question` | `toolCall.name` | `waitingForInput` / `question` | **Verified** — `args.questions[].{question, options[string], is_multi_select}` |
| `PostToolUse` | `toolCall.name` | `working` | **Verified** |
| `PostToolUse` `write_to_file` with `args.ArtifactMetadata.RequestFeedback == true` | args | `waitingForInput` / `planApproval` | **Assumed** from a live plan run; no captured fixture |
| `Stop` `fullyIdle: true` | `fullyIdle`, `terminationReason` | `readyForReview`, cause `hook: Stop fullyIdle=true <reason>`. Observed reason: `NO_TOOL_CALL` | **Verified** 1.3.0 — `stop-no-tool-call-1-3-0` |
| `Stop` `fullyIdle: false` | `fullyIdle` | none: async work is still outstanding | **Verified** |
| `PostInvocation` | — | not registered | — |
| **Esc mid-turn** | — | **no hook fires** (no `Stop`); the screen marker below ends the turn | **Verified** 1.3.0 |

## Status: screen

| Rule | Window | Status | Evidence |
| --- | --- | --- | --- |
| `requesting permission for:` **and** a live numbered choice list (≥ 2 options, one with a `›`/`❯`/`>` caret) | bottom **24** non-empty lines (long commands repeated across choices push the heading up at narrow widths) | `waitingForInput` / `permission` | **Verified** 1.3.0 — `permission-picker.txt` |
| `⎿  Interrupted · What should Antigravity CLI do instead?` | bottom 8 | `readyForReview` with `endsTurn` (ends `PreInvocation`'s working) | **Verified** 1.3.0 — `interrupted.txt` |
| `Do you trust the contents of this project?` | bottom 8 | `waitingForInput` / `permission` | **Verified** 1.3.0 — `trust-prompt.txt` |
| Other generic markers | bottom 8 | per [screen-detection.md](screen-detection.md) | code |

The 1.3.0 picker for a command:

```text
Requesting permission for:
   rm probe-d.txt
Run this command?
> 1. Yes, run command
  2. Yes, and always allow in this conversation for commands that start with 'rm probe-d.txt'
  3. Yes, and always allow for commands that start with 'rm probe-d.txt' (Persist to settings.json)
  4. No, cancel
  5. No, and always deny for commands that start with … in this conversation     ← after an earlier deny
  6. No, and always deny for commands that start with … (Persist to settings.json)
  ↑/↓ Navigate · tab Amend · ctrl+g edit/expand command
```

## Dialogs

`AntigravityCompanionAdapter`. Which dialogs are open comes from the hook file
plus the log; how to answer them comes from the screen.

| Step | Source | Strings / fields |
| --- | --- | --- |
| Candidate request | event file, last 64 KB | `PreToolUse` lines with `stepIdx`, `conversationId`, `toolCall`; `PostToolUse` `write_to_file` + `RequestFeedback` → plan card (`TargetFile` title, `CodeContent` body) |
| Is it open? | `--log-file` | The last line containing `Surfacing` + `step <n>` + (`tool confirmation` or `ask_question`), not followed by `stepIdx=<n>,` + `convID=<conv>`, `AskQuestion response` + `step <n> `, or `Interrupt cleared pending tool confirmation`. Re-checked after 300 ms, since grants can surface and resolve within one tick. 1.3.0 lines: `Surfacing tool confirmation: "RunCommand" at step 2` and `Responding to tool confirmation: convID=…, stepIdx=2, approved=false, …` |
| Permission card | hook args | summary `CommandLine` or `TargetFile`; detail `CodeContent` |
| Question card | hook args | `questions[].question`/`prompt`, `options[]` (strings or `{label\|text, description}`), `header`, multi-select from `is_multi_select` (older keys `multiple`/`multiSelect` as fallbacks) |
| Option keys | screen | regex `^\s*([›❯>])?\s*([1-9])(?:[.)]\|\s+\[[ x]\])\s+(.+)$`, last block from `1` |
| Allow / always / deny | screen labels | The first option starting `Yes` without "always" / containing "always" + "conversation" but not "persist" / starting `No`. The answer types the option's digit |
| With a note | keys | arrow keys from the highlighted option to the chosen one, then `Tab`, bracketed paste, `CR` |
| Question write-in | screen | the option containing `write-in`, then the text pasted + `CR`; multi-select ends with `CR` |
| Deny & stop / Stop | keys | `Esc` |
| Plan approve / revise | prompt | sends `[Approved] <title>` or the revision as a prompt |
| Prompt while idle | keys | `Ctrl-A Ctrl-K` (kill the draft), bracketed paste, `CR`, `Ctrl-Y` (yank the draft back). Refused while the screen shows `Write-in...` or `Persist` |
| Prompt while working | file | appended to `<event file>.queue` as `{"injectSteps":[{"userMessage":…}]}`. Delivered by the next `PreInvocation`, and shown in agy's transcript as a user message (**Verified** 1.3.0) |
| Failed turn | event file | A `Stop` whose `error` is non-empty, or whose `terminationReason` names a step limit, becomes a note `Antigravity stopped: …` (once per `Stop` line) |
| Retry count | log | last line containing "retry"; its last number |

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Conversation index | `~/.gemini/antigravity-cli/conversation_summaries.db`: `conversation_summaries(conversation_id, title, workspace_uris JSON, last_modified_time)` | code |
| Per-conversation dir | `~/.gemini/antigravity-cli/brain/<id>/`; display log `.system_generated/logs/transcript.jsonl` (`transcript_full.jsonl` also seen in hook payloads) | **Verified** (paths in payloads) |
| Discovery | newest brain folders (≥ launch − 60 s), title from the `USER Objective:` line (agy's own generated title, nil until written) or the DB, cwd from the DB or the log (`" -> /path"`, `"Cwd":`). A folder without a cwd matches only Flotilla's general session | code |
| Fallback discovery | `AntigravityTranscriptCodec.discoverSession` (brain dir by creation date) | code |
| Transcript codec | `~/.gemini/antigravity-cli/conversations/<id>.db`, table `steps`, unencrypted protobuf with no published schema. Reading decodes user/assistant/tool/system steps; handoff writes one synthetic user step. Details in `FORMAT.md` | **Verified** by probe (see `FORMAT.md`) |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `agy models` | one model per line, `<slug>\t<display name>`, e.g. `gemini-3.8-flash-low\tGemini 3.8 Flash (Low)`; skips `usage`, `available`, `name`, `agy…`, `#`, `-` lines | **Verified** 1.3.0 |
| `agy --help` | the `--effort … (low\|medium\|high\|xhigh\|max)` line. CLI-wide, not per model; fetched but unused | Help 1.3.0 |
| Grouping | `ModelCatalog.groupAntigravityModels`: one picker row per family; effort picks the `-low/-medium/-high` slug | code |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/antigravity/`:
- **Hooks:** `PreInvocation`, `PreToolUse` (`run_command` 1.3.0 and older,
  `ask_question`), `PostToolUse` (`view_file`, `write_to_file` without
  feedback), `Stop` (`fullyIdle` true on 1.3.0, true and false older).
- **Screens:** permission picker, interrupt, trust prompt.

Still missing: plan `RequestFeedback`, and a `Stop` with an `error`.

## Update checklist

1. Probe in a scratch workspace, with hooks for every event in the
   workspace's `.agents/hooks.json`. To see pickers, set `toolPermission:
   "request-review"` in `~/.gemini/antigravity-cli/settings.json`: back it
   up first and restore it byte-identical after. `JETSKI_APP_DATA_DIR` is
   **not** honoured by 1.3.0.
2. Still read `~/.gemini/config/hooks.json`, with named groups and the same
   grouped (`PreToolUse`/`PostToolUse`) vs flat (`PreInvocation`/`Stop`)
   shapes?
3. `PreToolUse` decision matrix (above): can a hook approve now? If yes, the
   phone could answer through the hook, as with Claude.
4. Payload: does it name its own event now? (Then the `argv` workaround can
   go.) `toolCall.name`/`args`, `stepIdx`, `conversationId`, `fullyIdle`,
   `terminationReason` values.
5. Interrupt: still no `Stop`? Still `Interrupted · What should Antigravity
   CLI do instead?`?
6. The picker heading and labels (`Requesting permission for:`,
   `Yes`/`…always…conversation…`/`…Persist…`/`No`), `Write-in...`.
7. `--log-file` markers: `Surfacing tool confirmation`, `stepIdx=<n>,`,
   `convID=`, `AskQuestion response`,
   `Interrupt cleared pending tool confirmation`. These strings are the
   companion's source of truth for dialog lifetime, and the most fragile
   contract on this page.
8. `PreInvocation` `injectSteps` still delivered as a user message.
9. `--effort` rules; `agy models` format; `trustedWorkspaces`; the
   `conversations/<id>.db` protobuf (re-run the `FORMAT.md` probes).

## Open items

- Plan feedback (`RequestFeedback`) and a failing `Stop` have no captured
  fixtures.
- `AntigravityWorkspaceTrust` honours `JETSKI_APP_DATA_DIR`, but agy 1.3.0
  ignored it in the probe and read `~/.gemini/antigravity-cli` anyway. This
  is harmless unless a user sets the variable.
- Approvals can't move to a hook: only `deny` takes effect (see the decision
  matrix).
