# Claude Code

| | |
| --- | --- |
| Binary | `claude` (`AgentCatalog.claudeCode`) |
| Last verified | **2.1.291**, 2026-10-06: live probe of every registered hook, trust dialog, interrupt, `/compact`, `/clear`, sub-agents, project-directory naming. Older payloads 2.1.119–2.1.290 |
| Primary sources | [Claude Code hooks reference](https://code.claude.com/docs/en/hooks); `claude --help`; captured payloads in `FlotillaUnitTests/ProviderFixtures/claude-code/` |
| Code | `HookConfigurationWriter.launchArguments(.claudeCode)`, `HookEventReceiver` (`.claudeCode`), `ClaudeCompanionAdapter`, `ClaudePermissionBridge`, `ClaudeSessionProvider`, `ClaudeTranscriptCodec` |

Claude Code is the most structured provider. Flotilla injects hooks for this
process alone, every payload names its own event, and the `PermissionRequest`
hook carries a decision back, which is how the phone answers dialogs.
The screen is consulted for only two things no hook can report: the
workspace-trust dialog and an interrupt.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | `--settings '<json>'`, built per launch; merged additively with the project's `.claude/settings.json`, which Flotilla never edits | **Verified** 2.1.291 |
| Legacy cleanup | `removeLegacyClaudeHookGroups` strips pre-`cf38d57` hook groups that hard-coded an event-file path into `.claude/settings.json` | code |
| Event routing | env `FLOTILLA_HOOK_EVENT_FILE=<support>/hooks/<session UUID>.jsonl`; without it every hook command exits 0. `MessageDisplay` goes to `<event file>.display` | **Verified** 2.1.291 |
| Workspace trust | An untrusted folder (not covered by a trusted parent) shows a trust dialog, and Claude holds back **every** hook, `--settings` included, until it is accepted. Flotilla does **not** pre-trust: Claude rewrites the 1.3 MB `~/.claude.json` from every process with temp-file-and-rename and no lock, so an outside write would race it. The dialog is detected on screen instead (below) | **Verified** 2.1.291: zero events before accepting, `SessionStart` right after |
| Session identity | first launch `--session-id <uuid>`; resume `--resume <uuid>` (`AgentResumeStrategy.assignable`). `/clear` and forks move the process to a new id, which `SessionStart` reports and `AppStore.adoptAgentSessionID` follows | **Verified** 2.1.291 |
| Model / effort | `--model <slug>`, `--effort <low…max>` | Help 2.1.291 |
| Plan mode | `--permission-mode plan`, fresh conversations only (never alongside `--resume`) | code |
| Host instructions | `--append-system-prompt <text>` (`HostAppAwareness`) | code |
| Initial prompt | positional argument (`promptFlag: .bareValue`); later prompts via tmux `send-keys` | **Verified** |
| Multiline newline | `ESC CR` (`multilineNewline`) | code |

The `--settings` payload registers:

| Event | Matcher | Mode | Command |
| --- | --- | --- | --- |
| `SessionStart`, `UserPromptSubmit`, `PostToolUse`, `PostToolUseFailure`, `PermissionDenied`, `Notification`, `Stop`, `StopFailure`, `PreCompact`, `PostCompact`, `SubagentStart` (`HookConfigurationWriter.claudeObservedEvents`) | all | `async` | `printf '%s\n'` stdin into the event file |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | `async` | same |
| `MessageDisplay` | all | `async` | same, into `<event file>.display` |
| `PermissionRequest` | all | **sync**, `timeout: 86400` | append to the event file, then — only if `<support>/companion.sock` exists — hand `event-file-path\njson` to the socket with `nc -U` and print whatever decision comes back |

`async` hooks run in the background and never hold Claude up. Measured on
2.1.291, their lines still land in the order Claude fired them. The line and
its newline are one `printf`, so concurrent hooks can't interleave.
`SubagentStop` and `SessionEnd` are deliberately not registered (see below).

## Status: hooks

Common fields: `hook_event_name`, `session_id`, `transcript_path`, `cwd`,
`scratchpad_dir`, `prompt_id`, `permission_mode`, `effort.level`. Inside a
sub-agent, add `agent_id` and `agent_type`. Claude's own background helpers
(title, recap, notifications) carry `agent_id` with **no** `agent_type`, and
`HookEventReceiver` ignores them. They fire tool events and `SubagentStop`
*after* the turn's `Stop`.

| Event (variant) | Fields read | Flotilla status | Evidence |
| --- | --- | --- | --- |
| `UserPromptSubmit` | — | `working`. Also fires for turns Claude starts itself (a background sub-agent handing back) | **Verified** 2.1.291 — `user-prompt-submit` |
| `PostToolUse` (any tool, main or sub-agent) | `tool_name` | `working` | **Verified** 2.1.291 — `post-tool-use-bash`, `post-tool-use-from-subagent` |
| `PostToolUseFailure` | `tool_name`, `is_interrupt` | `working`; `readyForReview` when `is_interrupt` | **Verified** 2.1.291 (`is_interrupt: false`) — `post-tool-use-failure`; the interrupt branch is **Assumed** |
| `PermissionDenied` (auto mode) | `tool_name` | `working` (the model carries on) | **Documented** — `permission-denied` |
| `PreToolUse` `AskUserQuestion` | `tool_name` | `waitingForInput` / `question` | **Verified** 2.1.291 |
| `PreToolUse` `ExitPlanMode` | `tool_name` | `waitingForInput` / `planApproval` | **Verified** 2.1.290 |
| `PermissionRequest` `AskUserQuestion` / `ExitPlanMode` | `tool_name` | `question` / `planApproval` | **Verified** 2.1.290–2.1.291 |
| `PermissionRequest` (other tool) | `tool_name`, `tool_input` | `waitingForInput` / `permission`; also feeds Home's *Top permissions* | **Verified** 2.1.119 |
| `Notification` `idle_prompt` | `notification_type` | `readyForReview` (arrives ~20 s after `Stop`) | **Verified** 2.1.288–2.1.291 |
| `Notification` `permission_prompt` | `notification_type`, `message` | `waitingForInput` / `permission`, or `planApproval` if `message` contains "plan" | **Verified** 2.1.290 — message `Claude needs your permission` |
| `Notification` `elicitation_dialog`, `elicitation_url_dialog`, `agent_needs_input` | `notification_type` | `waitingForInput` / `question` | **Documented** |
| `Notification` `elicitation_complete`, `elicitation_response`, `quota_auto_resume_fired` | `notification_type` | `working` | **Documented** |
| `Notification` `auth_success`, `agent_completed`, `quota_auto_resume_stale`/`disabled` | — | none | **Documented** |
| `Stop` | — | `readyForReview` | **Verified** 2.1.288–2.1.291 |
| `StopFailure` | `error` (type: `rate_limit`, `overloaded`, …), `error_details` | `readyForReview`, cause `hook: StopFailure <type>`; the companion adds a failed-turn note | **Documented** — `stop-failure-rate-limit` (an invalid `/model` is refused before the turn, so it can't be triggered cheaply) |
| `PreCompact` | `trigger` | `working` | **Verified** 2.1.291 — `pre-compact-manual` |
| `PostCompact` | `trigger` | `manual` → `readyForReview` (`/compact` ends with the composer free); `auto` → `working` (inside a turn) | **Verified** 2.1.291 for `manual` |
| `SubagentStart` | — | `working` | **Verified** 2.1.291 — `subagent-start-explore` |
| `SessionStart` | `session_id`, `source` | no status; `sessionIdentityStream` → `AppStore.adoptAgentSessionID` (never an id another session holds) | **Verified** 2.1.291 — `session-start-startup`, `session-start-clear` |

Sequences observed on 2.1.291:
- **`/compact`**: `PreCompact(manual)`, helper `SubagentStop`, `SessionStart(compact)` with the same id, `PostCompact(manual)`. No `Stop`.
- **`/clear`**: `SessionEnd(clear)`, then `SessionStart(clear)` with a **new** `session_id`.
- **Background sub-agent**: `PreToolUse Agent`, `SubagentStart`, `PostToolUse Agent`, then the main `Stop` *before* the sub-agent finishes. The sub-agent's tool events (with `agent_type`) follow, then `UserPromptSubmit` for the hand-back turn, the reply, and a second `Stop`.
- **Esc mid-turn**: **no hook at all**: no `Stop`, no `StopFailure`.

## Status: screen

What Claude 2.1.291 draws at the bottom of its pane while working:

```text
✻ Wibbling… (8m 27s · ↓ 23.4k tokens · thought for 2s)     ← spinner, verb varies; no interrupt hint
─────────────────────────────────────────────
❯                                                           ← composer, always visible
─────────────────────────────────────────────
  Est. usage: $3.63
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
```

| Marker | Result | Evidence |
| --- | --- | --- |
| `Yes, I trust this folder` (trust dialog; `❯ No, exit` is preselected) | `waitingForInput` / `permission`. The only source: hooks are held until it is accepted | **Verified** 2.1.291 — `screens/trust-dialog.txt` |
| `⎿  Interrupted · What should Claude do instead?` | `readyForReview` with `endsTurn`. The one screen observation that may end a hook-held *working*, because an interrupt fires no hook | **Verified** 2.1.291 — `screens/interrupted.txt` |
| Working hint `esc to interrupt` | **No longer drawn**. The `UserPromptSubmit` hook now carries *working* instead | **Drift** — `screens/working-thinking.txt` (known gap of the screen alone) |
| Composer `❯` above transcript → `readyForReview` | Also matches while working; held back by the arbiter while the last hook said `working`/`waitingForInput` | **Verified** 2.1.291 |
| Numbered choice list with `❯` caret → question; `do you want to`, `(y/n)` … → permission | Generic | code |

## Dialogs

| Dialog | Desktop detection | Phone card | Answer path |
| --- | --- | --- | --- |
| Tool permission | `PermissionRequest` hook | `ClaudePermissionPayload.parse` → permission card (`summary` from `command`/`file_path`/`url`/…) | hook stdout `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"\|"deny",…}}}` |
| Always allow | — | permission card | `updatedPermissions` = the payload's `permission_suggestions` with `destination` forced to `session`, else `addRules` for the tool |
| Deny & stop | — | permission card | `behavior: deny` + `interrupt: true` |
| Question | `AskUserQuestion` hook | question steps from `tool_input.questions[].{header,question,options[].label,multiSelect}` | `behavior: allow` + `updatedInput.answers{question: "a, b"}` |
| Plan | `ExitPlanMode` hook | plan card from `tool_input.plan` (title = first `#` heading) | allow (+ optional `setMode` `acceptEdits`/`default`), or deny with the revision text |

First answer wins. The terminal dialog stays live while the hook is held,
and `PostToolUse`, `PostToolUseFailure` or `PermissionDenied` (`tool_use_id`)
retracts the phone card when the Mac answered first. With no socket, or a
socket that closes without an answer, the hook prints nothing and Claude's
own dialog decides.

Companion live text (`ClaudeCompanionAdapter`) comes from the display file.
`MessageDisplay` carries `message_id`, `index`, `delta` and `final`. Chunks
are placed by `index`, because async hooks may land out of order. A message
ends on `final`, `Stop`, `StopFailure` or `UserPromptSubmit`, and late
chunks of a finished message are ignored. A short reply arrives as a single
chunk with `final: true`. `StopFailure` adds the note
`Claude stopped (<type>): <error_details>`.

Phone prompts (`ClaudeCompanionAdapter.sendPrompt`) are refused while the
screen contains `Esc to cancel`, `Enter to select` or `Would you like to`
(an open terminal dialog). Otherwise the prompt is sent as `Ctrl-S` (which
stashes a real Mac draft) + bracketed paste + `CR`. Stop is `Esc`, unless a
held request can be denied with `interrupt`.

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Storage | `~/.claude/projects/<slug>/<session UUID>.jsonl` | **Verified** |
| Slug | The cwd with every UTF-16 unit outside `[A-Za-z0-9]` turned into `-`. Longer than 200 units: cut at 200, then `-` + the path's 32-bit djb2 hash (`h = h*31 + unit`) in base 36. Older releases (≤ 2.1.119) kept spaces | **Verified** 2.1.291 — `…-Slug-Tes-5lsqn4` reproduced exactly (`ClaudeTranscriptCodecTests`) |
| Discovery | `ClaudeSessionProvider`: project folders matching the slug variants (and, for long paths, the 200-unit prefix), or the cwd's last component; newest `.jsonl` by mtime | code |
| Title | latest `custom-title`.`customTitle` (also searched in the last 32 KB), else `ai-title`.`aiTitle`, else the first user message (≤ 60 chars), from the first 256 KB | code |
| ID | the filename. Flotilla assigns it via `--session-id` and follows `SessionStart` after `/clear` and forks | **Verified** 2.1.291 |
| Transcript codec | `ClaudeTranscriptCodec`: reads `user`/`assistant` records of the `uuid`/`parentUuid` chain, ignores sidecar records (`mode`, `cost-state`, `file-history-snapshot`, …); writes a chain for handoff into the directory Claude itself uses. Details in `../session-handoff.md` | tests |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `claude --print "/model"` | the list after `Available: `; drops `[1m]` variants, `default`, and "or a full model ID" | code; output format **Assumed** current |
| `claude --print "/effort"` | `Usage: /effort <low\|medium\|high\|xhigh\|max\|auto>`; `auto` dropped | code |
| Fallback | `sonnet, opus, haiku, fable, best, opusplan` | static |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/claude-code/`:
- **Hooks:** `SessionStart` startup/clear, `UserPromptSubmit`, `PreToolUse` and
  `PermissionRequest` for `AskUserQuestion`/`ExitPlanMode`/`Bash`, a helper
  `PreToolUse` (ignored), `PostToolUse` (main and sub-agent),
  `PostToolUseFailure`, `PermissionDenied`*, `Notification`
  idle/permission, `Stop`, `StopFailure`*, `PreCompact`/`PostCompact` manual,
  `SubagentStart`, helper `SubagentStop`, `MessageDisplay`.
  (* = docs example, not yet captured live.)
- **Screens:** `working-thinking` (screen-only gap), `trust-dialog`,
  `interrupted`.

## Update checklist

1. `ProviderFixtureTests` passes.
2. Re-run the probe: a scratch folder, a `--settings` that registers every
   event `async`, then: trust dialog → prompt with a failing tool → Explore
   sub-agent → `/compact` → `/clear` → Esc mid-turn. Compare the sequences
   above.
3. Trust: are hooks still held until the dialog is accepted? Is the
   button text still `Yes, I trust this folder`?
4. Interrupt: still no hook? (If `Stop` or an `Interrupt` event appears, drop
   the screen marker.) Is the line still `Interrupted · What should Claude
   do instead?`?
5. `PreToolUse` still fires for `AskUserQuestion`/`ExitPlanMode`, and the
   `tool_input` shapes (`questions[]`, `plan`) are unchanged. The phone cards
   depend on them.
6. `PermissionRequest` stdout contract: `hookSpecificOutput.decision` with
   `behavior`, `updatedInput`, `updatedPermissions`, `interrupt`.
7. `MessageDisplay` fields (`message_id`, `index`, `delta`, `final`).
8. Background helpers still marked by `agent_id` without `agent_type`.
9. Project directory naming: create a folder whose path is > 200 characters
   and contains a space, run `claude -p`, and compare the directory name with
   `ClaudeTranscriptCodec.projectSlug`.
10. `claude --print "/model"` and `"/effort"` output formats.

## Open items

- `StopFailure` and `PermissionDenied` have only docs fixtures. Capture them
  when one occurs naturally: grep `"StopFailure"` / `"PermissionDenied"` in
  `~/Library/Application Support/Flotilla/hooks/*.jsonl`.
- `PostToolUseFailure` with `is_interrupt: true` has not been observed. On
  2.1.291, Claude moved a long `sleep` to the background, so Esc interrupted
  generation instead of a tool.
- `Notification` subtypes other than `idle_prompt`/`permission_prompt` are
  mapped from the docs only.
