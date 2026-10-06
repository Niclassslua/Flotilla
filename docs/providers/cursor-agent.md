# Cursor Agent

| | |
| --- | --- |
| Binary | `agent` (`AgentCatalog.cursorAgent`; also installed as `cursor-agent`) |
| Last verified | **2026.10.01-e373342**, 2026-10-06 (hook payloads, idle screen, dialog screens) |
| Primary sources | [`../probe-cursor-companion.md`](../probe-cursor-companion.md) (live probe, keys and dialogs); captured payloads and screens in `FlotillaUnitTests/ProviderFixtures/cursor-agent/` and `CursorCompanionAdapterTests` |
| Code | `HookConfigurationWriter.configureCursorHooks`, `HookEventReceiver` (`.cursorAgent`), `CursorCompanionAdapter`, `ProcessTmuxGoalDeliverer`, `CursorSessionProvider`, `CursorTranscriptCodec` |

Cursor's hooks are record-only. A hook `allow` does not skip Cursor's own
approval dialog, and nothing on the Mac answers a held hook, so every
decision stays in the TUI. The phone reads the dialog off the screen and
answers it with the keys a person would press. The probe doc has the full
measurements behind that choice.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | merged into project `<cwd>/.cursor/hooks.json` (`version: 1`): for each of `beforeSubmitPrompt`, `preToolUse`, `beforeShellExecution`, `beforeMCPExecution`, `postToolUse`, `afterShellExecution`, `afterFileEdit`, `afterAgentResponse`, `sessionEnd`, `stop`, any entry whose command contains `flotilla-cursor.sh` is replaced by `{"command": "<support>/hooks/flotilla-cursor.sh", "timeout": 30}`. Other tools' entries (CodeIsland, …) are kept. Locked like Antigravity's file | **Verified** |
| Wrapper | reads `hook_event_name` from stdin with `/usr/bin/python3` (falls back to `argv[1]`), writes `{"flotilla_provider":"cursor","hook_event_name":…,"payload":<stdin>}`, prints **nothing** (no decision) | **Verified** |
| Event routing | env `FLOTILLA_HOOK_EVENT_FILE`; without it the wrapper exits 0 | **Verified** |
| Trust | `--trust` on every launch, so the TUI never stops at a workspace-trust dialog in the pane | **Verified** |
| Session identity | **assigned**: Flotilla mints a UUID and launches `--resume <uuid>`; Cursor treats an unknown id as a new chat | **Verified** |
| Model / effort | `--model <slug>`; effort baked into the slug (`grok-4.7-high`); `fast` is not offered | code |
| Plan mode | `--plan`, fresh sessions only | code |
| Initial prompt | positional | code |
| Later prompts | tmux `send-keys -l <text>`, then `Enter` **250 ms later**. Back-to-back leaves the text in the composer, and the next prompt is appended to it (measured: ≥ 50 ms clears it) | **Verified** |

## Status: hooks

Payload: `payload.{hook_event_name, conversation_id, session_id,
generation_id, model, cursor_version, workspace_roots[], user_email,
transcript_path}`; tool events add `tool_name` (`Shell`, `Read`, `Write`,
`Grep`, …), `tool_input`, `tool_use_id`, `cwd`, plus `tool_output` and
`duration` after the call; shell events have `command`, `sandbox`, `output`;
`stop` has `status` (`completed`, `error`), `loop_count`, and token counts.

| Event | Flotilla status | Evidence |
| --- | --- | --- |
| `preToolUse`, `beforeShellExecution`, `beforeMCPExecution` | `working`; `waitingForInput` / `question` if the tool is `askquestion`/`ask_question`/`request_user_input` | **Verified** for `preToolUse`/`beforeShellExecution`; question branch **Assumed** (the probe found no question tool in the CLI) |
| `postToolUse`, `afterShellExecution` | `working` | **Verified** |
| `beforeSubmitPrompt` | `working` — the turn was accepted, before any tool hook | **Verified** 2026.10.01 — fixture `before-submit-prompt` |
| `afterFileEdit` | `working` | code |
| `stop` | `readyForReview`, whatever `status` says (`error` too) | **Verified** |
| `sessionEnd` | `readyForReview` | **Assumed**; not observed |
| `afterAgentResponse` | `readyForReview` — fires at turn end with the whole reply, right before `stop` | **Verified** 2026.10.01 — fixture `after-agent-response` |

Cursor waits for permission on screen only. No hook says "a dialog is open".

## Status: screen

| Signal | Where | Evidence |
| --- | --- | --- |
| Working | `ctrl+c to stop` beside the composer: a generic working marker, and `CursorCompanionAdapter.isWorking` | **Verified** |
| Idle composer | `→ Add a follow-up` / `→ Plan, search, build anything`. Not a generic composer marker (`❯`, `> `, `› `), so an idle pane gives **no** screen observation; *Ready for Review* comes from `stop` | **Verified** — fixture `screens/idle.txt` |
| Web-fetch approval | `Allow this web fetch?` contains the generic `allow this` marker → `waitingForInput` / `permission` | **Verified** — fixture `screens/web-fetch-approval.txt` |
| Shell approval | `Run this command?` … `(y)` … `(esc or n)` matches **no** generic marker → no observation; the board stays *Working* | **Verified** gap — fixture `screens/shell-approval.txt` |

## Dialogs

`CursorCompanionAdapter.dialog(in:)` reads the bottom 60 lines, with box
characters `│┃` trimmed:

| Dialog | Recognized by | Card | Keys |
| --- | --- | --- | --- |
| Approval ("Run this command?", "Allow this web fetch?") | last line ending `(y)`, a later line ending `(esc or n)`, and the nearest line above ending `?` (the question). The subject is the text between the last `──` rule and the question. `(tab)` present means always-allow is offered | `$ …` → Shell (trailing ` in <dir>` dropped); `Web Fetch: <url>` → WebFetch | `y` allow · `Tab` always · `n` skip, then the reason prompt (`CR` for an empty reason, or the note) · deny & stop = `Ctrl-C`, wait for working, `Ctrl-C` |
| Plan ("Ready to build?") | line `Ready to build?` with a later line ending `(b)`; plan path from `Saved to <path>.plan.md` (wrapped over several lines, leading `/` missing), else the newest `~/.cursor/plans/*.md` | plan card (frontmatter and `<!-- -->` id stripped) | `b` approve · `p`, wait for `Describe how to revise the plan`, then the text |
| Mac user typing | `→ Tell the agent what to do instead` or `→ Describe how to revise the plan` | none (no card) | — |

Prompts from the phone are refused while a dialog is open, or while the
composer holds a draft (Cursor has no draft stash: `Ctrl-S` types `s`). Stop
sends `Ctrl-C`, only mid-turn (on an idle composer it arms "Press Ctrl+C again
to exit"), then clears the restored prompt with `Ctrl-U` + `Backspace`, **one
key per write**.

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Chat state | `~/.cursor/chats/<md5(realpath(cwd))>/<chat id>/meta.json` (`title`, `cwd`, `createdAtMs`, `updatedAtMs`) + `store.db` (opaque, encrypted blob DAG) | **Verified** |
| Display transcript | `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`; slug = path with `/` → `-` (sometimes with a `private-` prefix); falls back to scanning all projects | **Verified** |
| Transcript semantics | user record written when its turn starts; assistant text only after that step's tool calls; a trailing `turn_ended` record is **removed** (the file is rewritten) when the next turn starts; steered follow-ups are sometimes never written | **Verified** (probe) |
| Plans | `~/.cursor/plans/<name>.plan.md` | **Verified** |
| Allowlist | `Tab` adds `Shell(<cmd>)` to the **global** `~/.cursor/cli-config.json` | **Verified** |
| Handoff | source: reads the JSONL. Destination: writes JSONL + meta, then seeds `store.db` with `agent --print --resume` | `CursorTranscriptCodec` |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `agent --list-models` | one exploded variant per line, `grok-4.7-high - Grok 4.7  High`; `ModelCatalog.groupCursorModels` folds variants into `/model` families and the effort picker resolves the slug | code |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/cursor-agent/`: `preToolUse` (Shell),
`beforeShellExecution`, `postToolUse` (Write), `afterShellExecution`,
`stop` (completed), `beforeSubmitPrompt`, `afterAgentResponse`; screens `idle.txt`,
`shell-approval.txt` (known gap), `web-fetch-approval.txt`. The companion's
dialog screens (plan, skip prompt, working) live in
`CursorCompanionAdapterTests`, copied from the same CLI version.

## Update checklist

1. Hook names and `hooks.json` schema (`version`, `hooks.<event>[].command`).
   Does a hook `allow` still not skip the dialog? (If it now does, hooks could
   decide like Claude's.)
2. Dialog text: `Run this command?`, `Allow this web fetch?`, `(y)`, `(tab)`,
   `(esc or n)`, `Ready to build?`, `(b)`, `Saved to …plan.md`,
   `→ Tell the agent what to do instead`, `→ Describe how to revise the plan`,
   the composer placeholders, and `ctrl+c to stop`.
3. Keys: `y`/`Tab`/`n`/`b`/`p`, `Ctrl-C` behavior, one-key-per-write
   editing.
4. `Enter` timing after `send-keys` (the 250 ms settle).
5. `meta.json` fields; the `md5(realpath(cwd))` bucket; transcript path and
   `turn_ended` behavior.
6. `agent --list-models` line format.
7. `--trust`, `--plan`, `--resume <unknown uuid>` still start a fresh chat.

## Open items

- **Gap (fixture-backed):** the board shows Cursor's *shell* approval as
  *Working*. No hook reports it, and the generic screen markers don't match
  `Run this command?`/`(y)`/`(esc or n)`. The web-fetch dialog is caught only
  because its text happens to contain `allow this`. The companion recognizes
  both (`dialog(in:)`); reusing that recognizer in the status path would close
  the gap.
- `HookConfigurationWriter.supportsHooks` still carries a "Temporary: Cursor
  hooks land next" comment, although they have landed.
- Events dropped from `cursorHookEvents` are never removed from existing
  `.cursor/hooks.json` files, and entries written by test runs point at
  deleted `flotilla-test-*` support directories.
- `sessionEnd` never observed.
