# Cursor Agent

| | |
| --- | --- |
| Binary | `agent` (`AgentCatalog.cursorAgent`; also installed as `cursor-agent`) |
| Last verified | **2026.10.01-e373342**, 2026-10-06: live probe of every hook event (with `approvalMode: allowlist`), skip/interrupt/follow-up behavior, user-level hooks, `create-chat`, parameterized models |
| Primary sources | [Cursor hooks](https://cursor.com/docs/agent/hooks), [CLI parameters](https://cursor.com/docs/cli/reference/parameters), [`../probe-cursor-companion.md`](../probe-cursor-companion.md) (keys and dialogs); captured payloads and screens in `FlotillaUnitTests/ProviderFixtures/cursor-agent/` and `CursorCompanionAdapterTests` |
| Code | `HookConfigurationWriter.configureCursorHooks`, `HookEventReceiver` (`.cursorAgent`), `CursorDialog` (HooksKit), `TerminalScreenHeuristic`, `CursorCompanionAdapter`, `ProcessTmuxGoalDeliverer`, `CursorSessionProvider`, `CursorTranscriptCodec` |

Cursor's hooks record and never decide. A hook `allow` does not skip
Cursor's own approval dialog, and nothing on the Mac answers a held hook, so
every decision stays in the TUI. No hook reports an open dialog either; a
skipped approval even arrives as an ordinary empty run. Dialogs are
therefore read off the screen by `CursorDialog`, both for the board's status
and for the phone, which answers with the keys a person would press.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | One Flotilla entry per event in the **user-level** `~/.cursor/hooks.json` (`version: 1`), for `beforeSubmitPrompt`, `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `postToolUse`, `postToolUseFailure`, `afterShellExecution`, `afterFileEdit`, `afterAgentThought`, `afterAgentResponse`, `subagentStart`, `preCompact`, `sessionEnd`, `stop` (`timeout: 30`). Other tools' entries (CodeIsland, …) are kept. Flotilla entries for events no longer registered are removed, and so are the entries older releases wrote into `<cwd>/.cursor/hooks.json` (the file too, if nothing else is left). Locked and fail-closed like Antigravity's | **Verified** 2026.10.01: user-level hooks fire in the interactive CLI; `--print` runs project hooks only |
| Hook command | Constant: `event_file="${FLOTILLA_HOOK_EVENT_FILE:-}"; [ -n "$event_file" ] \|\| exit 0; wrapper="$(dirname "$event_file")/flotilla-cursor.sh"; [ -x "$wrapper" ] \|\| exit 0; exec "$wrapper"`. Inert outside Flotilla; its `flotilla-cursor.sh` substring is how rewrites recognise their own entries | **Verified** |
| Wrapper | Reads `hook_event_name` and `status` from stdin with `/usr/bin/python3` (falls back to `argv[1]`), writes `{"flotilla_provider":"cursor","hook_event_name":…,"payload":<stdin>}`. Prints nothing, except on a `stop` with `status: completed` while `<event file>.followup` holds queued phone prompts: it prints `{"followup_message": "<prompts>"}` and consumes the queue | **Verified** 2026.10.01: Cursor submits the follow-up as the next turn (`loop_count: 1`) |
| Trust | `--trust` on every launch, so the TUI never stops at a workspace-trust dialog in the pane | **Verified** |
| Session identity | **assigned**: Flotilla mints a UUID and launches `--resume <uuid>`; Cursor treats an unknown id as a new chat | **Verified** 2026.10.01 |
| Model / effort | `--model <slug>`; effort baked into the slug (`gpt-5.3-codex-high`), as listed by `--list-models` | **Verified** 2026.10.01 |
| Plan mode | `--plan`, fresh sessions only | code |
| Initial prompt | positional | code |
| Later prompts | tmux `send-keys -l <text>`, then `Enter` **250 ms later**. Back-to-back leaves the text in the composer, and the next prompt is appended to it (measured: ≥ 50 ms clears it). While Cursor works, phone prompts go to the follow-up queue instead (see Dialogs) | **Verified** |

### Evaluated and not adopted (2026.10.01)

| Option | Why not |
| --- | --- |
| `agent create-chat` for a real chat id | Prints a UUID that `--resume` opens. But it takes **~2.3 s** per call (three runs: 2.31, 2.36, 2.26 s), and a launch can't wait on that on the main actor. The minted-UUID launch above is verified to start a fresh chat. Switch only if Cursor stops accepting unknown ids |
| Parameterized models `slug[param=value,…]` | Accepted only with the model's own parameter id: `gpt-5.3-codex[reasoning=high,fast=false]` works, `[effort=high]` is refused. Ids differ by family (`reasoning`, `reasoning_effort`, `effort`, `fast`, `context`; see `modelParameters` in `~/.cursor/cli-config.json`), and `--list-models` doesn't expose them. The exploded slugs cover the same choices and are validated by Cursor |
| `afterAgentResponse.text` as companion text | 2026.10.01 sent the reply twice in one string (`Hello there friend!Hello there friend!`). The transcript JSONL stays the source |
| `sessionStart` | Never fired in the CLI: not on `create-chat`, launch, or first prompt (the docs list it for the IDE) |

## Status: hooks

Payload: `payload.{hook_event_name, conversation_id, session_id,
generation_id, model, cursor_version, workspace_roots[], user_email,
transcript_path}`.
- Tool events add `tool_name` (`Shell`, `Read`, `Write`, `Grep`, `Task`, …),
  `tool_input`, `tool_use_id` and `cwd`; after the call, `tool_output` and
  `duration`.
- Shell events have `command`, `sandbox` and `output`.
- `stop` has `status` (`completed`, `aborted`, `error`), `loop_count`, and
  token counts.
- `sessionEnd` has `reason`, `final_status`, `duration_ms` and
  `is_background_agent`.

| Event | Flotilla status | Evidence |
| --- | --- | --- |
| `beforeSubmitPrompt` | `working`: the turn was accepted, before any tool hook | **Verified** 2026.10.01 — `before-submit-prompt` |
| `afterAgentThought` | `working`: the first sign of a turn submitted as a `followup_message`, which fires no `beforeSubmitPrompt` | **Verified** 2026.10.01 — `after-agent-thought` |
| `preToolUse`, `beforeShellExecution`, `beforeMCPExecution` | `working`; `waitingForInput` / `question` if the tool is `askquestion`/`ask_question`/`request_user_input` | **Verified** for `preToolUse`/`beforeShellExecution`; question branch **Assumed** (the CLI has no question tool) |
| `postToolUse`, `afterShellExecution`, `afterFileEdit` | `working`. `afterShellExecution` also closes an approval dialog: a **skipped** command arrives as `exitCode: 0`, empty output, and a `duration` that includes the wait | **Verified** 2026.10.01 — `after-shell-execution-skipped` |
| `postToolUseFailure` | `working`; `readyForReview` when `is_interrupt` | **Documented**: did **not** fire for a skip or a Ctrl-C in 2026.10.01 |
| `subagentStart`, `preCompact` | `working` | **Documented**: not fired by the Task tool or `/compact` in 2026.10.01 |
| `afterAgentResponse` | `readyForReview`: fires at turn end with the whole reply, right before `stop` (sometimes after it) | **Verified** 2026.10.01 — `after-agent-response` |
| `stop` | `readyForReview` for any `status`: `completed`, `aborted` (Ctrl-C mid-turn, followed by a second `stop` with `error`), `error` | **Verified** 2026.10.01 — `stop-completed`, `stop-aborted`, `stop-error`, `stop-after-followup` |
| `sessionEnd` | `readyForReview` (on exit: `reason: completed`, `final_status: completed`) | **Verified** 2026.10.01 — `session-end` |

## Status: screen

`TerminalScreenHeuristic(agent: .cursorAgent)` reads `CursorDialog` before
any generic marker.

| Signal | Where | Evidence |
| --- | --- | --- |
| Approval (`Run this command?`, `Allow this web fetch?`) | `CursorDialog` → `waitingForInput` / `permission` | **Verified** — `screens/shell-approval.txt`, `web-fetch-approval.txt` |
| Plan (`Ready to build?` … `(b)`) | `CursorDialog` → `waitingForInput` / `planApproval` (plans fire no hook) | **Verified** — `screens/plan-ready.txt` |
| Mac user typing a skip reason or revision | `CursorDialog.typing` → no observation | code |
| Working | `ctrl+c to stop` beside the composer: a generic working marker, and `CursorCompanionAdapter.isWorking` | **Verified** |
| Idle composer | `→ Add a follow-up` / `→ Plan, search, build anything`. Not a generic composer marker, so an idle pane gives **no** screen observation; *Ready for Review* comes from `stop` | **Verified** — `screens/idle.txt` |

## Dialogs

`CursorDialog.parse` reads the bottom 60 lines, with box characters `│┃`
trimmed:

| Dialog | Recognized by | Card | Keys |
| --- | --- | --- | --- |
| Approval ("Run this command?", "Allow this web fetch?") | The last line ending `(y)`, a later line ending `(esc or n)`, and the nearest line above ending `?` (the question). The subject is the text between the last `──` rule and the question. `(tab)` present means always-allow is offered | `$ …` → Shell (trailing ` in <dir>` dropped); `Web Fetch: <url>` → WebFetch | `y` allow · `Tab` always · `n` skip, then the reason prompt (`CR` for an empty reason, or the note) · deny & stop = `Ctrl-C`, wait for working, `Ctrl-C` |
| Plan ("Ready to build?") | line `Ready to build?` with a later line ending `(b)`; plan path from `Saved to <path>.plan.md` (wrapped over several lines, leading `/` missing), else the newest `~/.cursor/plans/*.md` | plan card (frontmatter and `<!-- -->` id stripped) | `b` approve · `p`, wait for `Describe how to revise the plan`, then the text |
| Mac user typing | `→ Tell the agent what to do instead` or `→ Describe how to revise the plan` | none (no card) | — |

Phone prompts:
- **Refused** while a dialog is open.
- **While Cursor works:** appended to `<event file>.followup` (one prompt per
  block, separated by a blank line). Nothing is typed. The next completed
  `stop` hands them to Cursor as `followup_message`, so a Mac draft in the
  composer is never touched.
- **Stranded prompts:** if the turn ended another way (aborted, error, or
  just before the prompt was queued), the next companion refresh that finds
  the pane idle (no dialog, no draft) takes the queue (an atomic rename that
  races the hook's `mv`) and types it.
- **While idle with a Mac draft:** refused. Cursor has no draft stash
  (`Ctrl-S` types `s`).

Stop sends `Ctrl-C`, only mid-turn (on an idle composer it arms "Press Ctrl+C
again to exit"), then clears the restored prompt with `Ctrl-U` + `Backspace`,
**one key per write**.

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Chat state | `~/.cursor/chats/<md5(realpath(cwd))>/<chat id>/meta.json` (`title`, `cwd`, `createdAtMs`, `updatedAtMs`) + `store.db` (opaque, encrypted blob DAG) | **Verified** |
| Display transcript | `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`; slug = path with `/` → `-` (sometimes with a `private-` prefix); falls back to scanning all projects | **Verified** |
| Transcript semantics | A user record is written when its turn starts; assistant text only after that step's tool calls. A trailing `turn_ended` record is **removed** (the file is rewritten) when the next turn starts. Steered follow-ups are sometimes never written | **Verified** (probe) |
| Plans | `~/.cursor/plans/<name>.plan.md` | **Verified** |
| Allowlist | `Tab` adds `Shell(<cmd>)` to the **global** `~/.cursor/cli-config.json` | **Verified** |
| Handoff | Source: reads the JSONL. Destination: writes JSONL + meta, then seeds `store.db` with `agent --print --resume` | `CursorTranscriptCodec` |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `agent --list-models` (= `agent models`) | One exploded variant per line, `gpt-5.3-codex-high-fast - Codex 5.3 High Fast`. `ModelCatalog.groupCursorModels` folds effort, `-fast` and `-thinking` variants into `/model` families, and the effort picker resolves the slug | **Verified** 2026.10.01 |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/cursor-agent/`:
- **Hooks:** `beforeSubmitPrompt`, `afterAgentThought`, `preToolUse` (Shell),
  `beforeShellExecution`, `postToolUse` (Write), `afterShellExecution`
  (ordinary and skipped), `afterAgentResponse`, `stop` (completed, aborted,
  error, after a follow-up), `sessionEnd`.
- **Screens:** idle, shell approval, web-fetch approval, plan.

Further companion screens (skip prompt, working) live in
`CursorCompanionAdapterTests`.

## Update checklist

1. Probe with `approvalMode: "allowlist"` in `~/.cursor/cli-config.json`
   (back it up and restore it byte-identical; your setting is
   `unrestricted`), with every event registered in the probe workspace's
   `.cursor/hooks.json`.
2. User-level `~/.cursor/hooks.json` still read by the interactive CLI?
3. Does a hook `allow` still not skip the dialog? Does anything report an open
   dialog, or a skip (`postToolUseFailure` with `permission_denied`)? If so,
   the screen reading can go.
4. `stop.followup_message` still submitted, and still only once per
   `loop_limit`?
5. `sessionStart`, `subagentStart`, `preCompact` firing now?
6. Dialog text: `Run this command?`, `Allow this web fetch?`, `(y)`, `(tab)`,
   `(esc or n)`, `Ready to build?`, `(b)`, `Saved to …plan.md`,
   `→ Tell the agent what to do instead`, `→ Describe how to revise the plan`,
   the composer placeholders, and `ctrl+c to stop`.
7. Keys: `y`/`Tab`/`n`/`b`/`p`, `Ctrl-C` behavior, one-key-per-write editing.
8. `Enter` timing after `send-keys` (the 250 ms settle).
9. `meta.json` fields; the `md5(realpath(cwd))` bucket; transcript path and
   `turn_ended` behavior.
10. `agent --list-models` format; `--resume <unknown uuid>` still starts a
    fresh chat; `create-chat` latency.
11. `afterAgentResponse.text` duplication fixed?

## Open items

- `postToolUseFailure`, `subagentStart` and `preCompact` are registered from
  the docs but weren't observed in the CLI.
