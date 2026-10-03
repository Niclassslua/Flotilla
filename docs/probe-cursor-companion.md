# Cursor Agent companion — probe notes

How the iPhone companion shares one interactive Cursor Agent TUI session with
the Mac, without ACP or the SDK as the Mac runtime.

**CLI:** `agent` / `cursor-agent` (2026.10.01 probed)  
**Pattern:** Antigravity-style — the TUI owns every decision. Hooks only
record; the phone mirrors the dialog Cursor shows and answers it with the keys
a person would press.

## Why not blocking hooks

The first version held `preToolUse` / `beforeShellExecution` on the companion
socket until someone answered. Measured end to end, that did not work:

- A hook `allow` does **not** skip Cursor's own "Run this command?" dialog, so
  with Run Everything off every shell command was approved twice.
- Nothing on the Mac answers a held hook. With no phone answering, the bridge
  withdrew the card once the session didn't read as waiting (~3 s), and the
  shim treated the empty answer as allow — so phone approval never gated
  anything, and every shell command (two hooks) stalled ~7 s.
- The phone showed each card twice (adapter and bridge both listed it).

## Verified locally (Cursor Agent 2026.10.01)

| Claim | Result |
|---|---|
| Interactive TUI is one process (`agent --resume <id> --trust`) | Yes |
| Reads and in-workspace edits ask for approval | No, even with Run Everything off |
| Shell: "Run this command?" | `y` runs once · Tab runs and adds `Shell(<cmd>)` to the **global** allowlist (`~/.cursor/cli-config.json`) · `n` asks "Tell the agent what to do instead" (empty Enter just skips) |
| Web fetch: "Allow this web fetch?" | `y` · Tab always allows the domain · `n` skips at once, no reason prompt |
| Plans | No hook fires. The plan is saved to `~/.cursor/plans/<name>.plan.md` and "Ready to build?" offers `b` (build), `c` (cloud), `p` (revise: then text + Enter) |
| Questions | The CLI has no AskQuestion tool, even in Plan mode; questions are plain assistant text |
| Escape | Does **not** interrupt a turn; in a dialog it toggles to the skip-reason prompt |
| Ctrl-C | Interrupts the turn (`turn_ended: aborted`) and puts the interrupted prompt back in the composer. On an idle composer it arms "Press Ctrl+C again to exit" |
| Ctrl-S | Types a literal `s` — there is no draft stash |
| Editing keys | Must arrive one per write; a burst (e.g. Ctrl-U Backspace Ctrl-U) is ignored. Ctrl-U empties a line, Backspace joins the one above |
| Enter right behind typed text | Submits, but leaves the text in the composer; the next prompt is appended and both go out as one. 50 ms or more between them clears it |
| `beforeSubmitPrompt` | Fires with the exact prompt and its own `generation_id` the moment Cursor accepts it, also for a queued follow-up |
| Transcript JSONL | Under `~/.cursor/projects/…/agent-transcripts/<id>/`. A user record is written when its turn starts; assistant text only once that step's tool calls finish. The trailing `turn_ended` record is removed when the next turn starts (the file is rewritten). A follow-up steered into a running turn is sometimes never written |
| `afterAgentResponse` | Fires at turn end with the whole reply — no earlier than the JSONL |
| Backend errors | `WritableIterable is closed` ends turns intermittently; `stop` reports `status: error` |
| Resume memory lives in `~/.cursor/chats/<md5(cwd)>/<id>/store.db` | Opaque blob DAG; handoff destination seeds via `agent --print --resume` preamble |
| Release source | Delete chat dir + transcript folder (no delete CLI) |

## Capability alignment

- One process / one session; status via hooks and the screen
- Approve, always allow (Cursor's own allowlist), deny, deny with note, deny
  and stop — while Cursor shows a dialog; Run Everything means no dialogs, so
  no cards (same as at the Mac)
- Plans: approve or revise from the phone; no question cards (Cursor asks in
  text)
- Prompts through tmux `send-keys` (text, then Enter 250 ms later). Refused
  while a dialog is open or the Mac composer holds unsent text
- Stop: one Ctrl-C, only mid-turn, then the restored prompt is cleared
- A turn that ends in an error shows as a note until the next turn starts.
  Prompts still waiting in Cursor's follow-up queue (also after such an
  error) stay "Queued" on the phone, matching Cursor's own queue
- First answer wins: an answer re-checks the screen and types nothing if the
  dialog is gone

## Flotilla wiring

| Piece | Location |
|---|---|
| `AgentKind.cursorAgent` + descriptor | SessionKit / AgentKit |
| Hook install + `flotilla-cursor.sh` (record only) | HooksKit `HookConfigurationWriter` |
| Dialog mirroring, prompts, Stop | `CursorCompanionAdapter` |
| Transcript codec | `CursorTranscriptCodec`; rewrite-safe reading in `CompanionTranscriptReader` |

Unit coverage: `CursorCompanionAdapterTests` (screens captured from the CLI),
`CursorHookTests`, `CursorTranscriptCodecTests`,
`testCursorTranscriptRewriteKeepsTheNextUserMessage`.
