# Claude Code

| | |
| --- | --- |
| Binary | `claude` (`AgentCatalog.claudeCode`) |
| Last verified | **2.1.291**, 2026-10-06 (hook payloads 2.1.288–2.1.291, working screen 2.1.291) |
| Primary sources | Claude Code hooks reference; captured payloads in `FlotillaUnitTests/ProviderFixtures/claude-code/` |
| Code | `HookConfigurationWriter.launchArguments(.claudeCode)`, `HookEventReceiver` (`.claudeCode`), `ClaudeCompanionAdapter`, `ClaudePermissionBridge`, `ClaudeSessionProvider`, `ClaudeTranscriptCodec` |

Claude Code is the most structured provider: Flotilla injects hooks for this
process alone, the payload names its own event, and the `PermissionRequest`
hook can carry a decision back, which is how the phone answers dialogs.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | `--settings '<json>'`, built per launch; merged additively with the project's `.claude/settings.json`, which Flotilla never edits | **Verified** (payloads arrive, 2.1.291) |
| Legacy cleanup | `removeLegacyClaudeHookGroups` strips pre-`cf38d57` hook groups that hard-coded an event-file path into `.claude/settings.json` | code |
| Event routing | env `FLOTILLA_HOOK_EVENT_FILE=<support>/hooks/<session UUID>.jsonl`; without it the hook command exits 0 | **Verified** |
| Session identity | first launch `--session-id <uuid>`; resume `--resume <uuid>` (`AgentResumeStrategy.assignable`) | **Verified** |
| Model / effort | `--model <slug>`, `--effort <low…max>` | **Documented** |
| Plan mode | `--permission-mode plan`, fresh conversations only (never alongside `--resume`) | code |
| Host instructions | `--append-system-prompt <text>` (`HostAppAwareness`) | code |
| Initial prompt | positional argument (`promptFlag: .bareValue`); later prompts via tmux `send-keys` | **Verified** |
| Multiline newline | `ESC CR` (`multilineNewline`) | code |

The `--settings` payload registers:

| Event | Matcher | Command |
| --- | --- | --- |
| `Notification`, `Stop`, `PostToolUse` | none (all) | append stdin + `\n` to the event file |
| `PreToolUse` | `AskUserQuestion\|ExitPlanMode` | same |
| `PermissionRequest` | none (all), `timeout: 86400` | append to the event file, then — only if `<support>/companion.sock` exists — hand `event-file-path\njson` to the socket with `nc -U` and print whatever decision comes back |

`PreToolUse` is deliberately narrow: other tools' `PreToolUse` would add
nothing that `PostToolUse` doesn't already say. The receiver's branch
mapping any other `PreToolUse` to `working` is therefore unreachable today.

## Status: hooks

Payload shape (2.1.291): flat object. Fields present on every event include
`hook_event_name`, `session_id`, `transcript_path`, `cwd`,
`scratchpad_dir`, `prompt_id`; tool events add `tool_name`, `tool_input`,
`tool_use_id`, `permission_mode`, `effort.level`; `Stop` adds
`last_assistant_message`, `stop_hook_active`, `background_tasks`,
`session_crons`.

| Event (variant) | Fields read | Flotilla status | Evidence |
| --- | --- | --- | --- |
| `PostToolUse` (any tool) | `tool_name` | `working` | **Verified** 2.1.291 — fixture `post-tool-use-bash` |
| `PreToolUse` `AskUserQuestion` | `tool_name` | `waitingForInput` / `question` | **Verified** 2.1.291 |
| `PreToolUse` `ExitPlanMode` | `tool_name` | `waitingForInput` / `planApproval` | **Verified** 2.1.290 |
| `PermissionRequest` `AskUserQuestion` / `ExitPlanMode` | `tool_name` | `question` / `planApproval` | **Verified** 2.1.290–2.1.291 |
| `PermissionRequest` (other tool) | `tool_name`, `tool_input` | `waitingForInput` / `permission`; also feeds Home's *Top permissions* (`permissionRequestEvent`) | **Verified** 2.1.119 |
| `Notification` `idle_prompt` | `notification_type` | `readyForReview` | **Verified** 2.1.288 — message `Claude is waiting for your input` |
| `Notification` `permission_prompt` | `notification_type`, `message` | `waitingForInput` / `permission`, or `planApproval` if `message` contains "plan" | **Verified** 2.1.290 — message `Claude needs your permission` (see Open items) |
| `Notification` `elicitation_dialog` | `notification_type` | `waitingForInput` / `question` | **Documented**; not yet observed |
| `Stop` | — | `readyForReview` | **Verified** 2.1.288 |

Events the companion adapter reads from the same file but which are **not
registered** by `--settings`: `MessageDisplay`, `StopFailure`,
`UserPromptSubmit`, `PostToolUseFailure` (see Open items).

## Status: screen

Only the generic `TerminalScreenHeuristic` applies; nothing is
Claude-specific. What Claude 2.1.291 draws at the bottom of its pane:

```text
✻ Wibbling… (8m 27s · ↓ 23.4k tokens · thought for 2s)     ← working spinner, verb varies
─────────────────────────────────────────────
❯                                                           ← composer
─────────────────────────────────────────────
  Est. usage: $3.63
  ⏵⏵ auto mode on (shift+tab to cycle) · ← for agents
```

| Generic marker | Applies? | Evidence |
| --- | --- | --- |
| Working hint `esc to interrupt` | **No longer drawn** in 2.1.291 (see Open items) | **Drift** — fixture `screens/working-thinking.txt` |
| Composer `❯` above transcript → `readyForReview` | Yes; also fires while working | **Verified** 2.1.291 |
| Numbered choice list with `❯` caret → question | Yes (permission and question pickers) | code |
| `do you want to`, `(y/n)` … → permission | Yes | code |

## Dialogs

| Dialog | Desktop detection | Phone card | Answer path |
| --- | --- | --- | --- |
| Tool permission | `PermissionRequest` hook | `ClaudePermissionPayload.parse` → permission card (`summary` from `command`/`file_path`/`url`/…) | hook stdout `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"\|"deny",…}}}` |
| Always allow | — | permission card | `updatedPermissions` = the payload's `permission_suggestions` with `destination` forced to `session`, else `addRules` for the tool |
| Deny & stop | — | permission card | `behavior: deny` + `interrupt: true` |
| Question | `AskUserQuestion` hook | question steps from `tool_input.questions[].{header,question,options[].label,multiSelect}` | `behavior: allow` + `updatedInput.answers{question: "a, b"}` |
| Plan | `ExitPlanMode` hook | plan card from `tool_input.plan` (title = first `#` heading) | allow (+ optional `setMode` `acceptEdits`/`default`), or deny with the revision text |

First answer wins: the terminal dialog stays live while the hook is held, and
`PostToolUse`/`PostToolUseFailure` (`tool_use_id`) retracts the phone card
when the Mac answered first. With no socket, or a socket that closes without
an answer, the hook prints nothing and Claude's own dialog decides.

Phone prompts (`ClaudeCompanionAdapter.sendPrompt`) are refused while the
screen contains `Esc to cancel`, `Enter to select` or `Would you like to`
(an open terminal dialog). Otherwise the prompt is sent as `Ctrl-S` (stashes
a real Mac draft) + bracketed paste + `CR`. Stop is `Esc` unless a held
request can be denied with `interrupt`.

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Storage | `~/.claude/projects/<slug>/<session UUID>.jsonl` | **Verified** |
| Slug | Absolute cwd with `/` → `-`. **Since ≤ 2.1.288, spaces → `-` too** (`Application-Support`); 2.1.119 kept spaces | **Drift**, see Open items |
| Discovery | `ClaudeSessionProvider`: scan project folders matching slug variants or the cwd's last component; newest `.jsonl` by mtime | code |
| Title | latest `custom-title`.`customTitle` (also searched in the last 32 KB), else `ai-title`.`aiTitle`, else the first user message (≤ 60 chars), from the first 256 KB | code |
| ID | the filename; Flotilla assigns it via `--session-id`, so discovery is only for titles | **Verified** |
| Transcript codec | `ClaudeTranscriptCodec`: reads `user`/`assistant` records of the `uuid`/`parentUuid` chain, ignores sidecar records (`mode`, `cost-state`, `file-history-snapshot`, …); writes a chain for handoff. Details in `../session-handoff.md` | tests |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `claude --print "/model"` | the list after `Available: `; drops `[1m]` variants, `default`, and "or a full model ID" | code; output format **Assumed** current |
| `claude --print "/effort"` | `Usage: /effort <low\|medium\|high\|xhigh\|max\|auto>`; `auto` dropped | code |
| Fallback | `sonnet, opus, haiku, fable, best, opusplan` | static |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/claude-code/`: nine hook payloads
(`Notification` idle/permission, `PreToolUse` and `PermissionRequest` for
`AskUserQuestion`/`ExitPlanMode`/`Bash`, `PostToolUse`, `Stop`) and one
working screen (`screens/working-thinking.txt`, a known gap).

## Update checklist

1. `ProviderFixtureTests` passes; the `working-thinking` gap is still a gap,
   or has become an unexpected pass because the hint is back.
2. `PreToolUse` still fires for `AskUserQuestion`/`ExitPlanMode` with the
   matcher `AskUserQuestion|ExitPlanMode`, and `tool_input` shapes
   (`questions[]`, `plan`) are unchanged. The phone cards depend on them.
3. `PermissionRequest` stdout contract unchanged: `hookSpecificOutput.decision`
   with `behavior`, `updatedInput`, `updatedPermissions`, `interrupt`.
4. `Notification` subtypes and `message` text (the plan heuristic reads
   it).
5. The working screen: is there an interrupt hint again, or a new
   stable working marker?
6. Project directory slug rule (spaces, dots, `/private`).
7. `claude --print "/model"` and `"/effort"` output formats.

## Open items

- **Drift: no working marker on screen (2.1.291).** The spinner line no
  longer contains `esc to interrupt`, so a working Claude reads as *Ready for
  Review* on screen. The arbiter hides this while the last hook observation
  was `working`/`waitingForInput`, but a turn with no tool call yet (pure
  thinking or writing) has no hook to hold it. Candidate marker: the spinner
  line `✻ … (` with an elapsed time (unverified across verbs and glyphs).
- **Drift: project slug.** `ClaudeTranscriptCodec.projectSlug` replaces only
  `/`. Current Claude also replaces spaces, and every Flotilla worktree lives
  under `Application Support`. Reads survive because `transcriptURL` falls back
  to matching the filename. A handoff **into** Claude writes into the
  space-style directory; whether `claude --resume <id>` still finds it there
  is **unverified**.
- `Notification`/`permission_prompt` for a plan now says `Claude needs your
  permission` (2.1.290); the "message contains *plan*" branch no longer fires.
  Harmless today because `PermissionRequest`/`PreToolUse ExitPlanMode` already
  report `planApproval`.
- `ClaudeCompanionAdapter` handles `MessageDisplay`, `StopFailure` and
  `UserPromptSubmit` events (streaming text, failed-turn notes), but the
  `--settings` payload does not register them, so these branches never run.
  Either register them or remove the handling.
- `elicitation_dialog` has never been observed.
