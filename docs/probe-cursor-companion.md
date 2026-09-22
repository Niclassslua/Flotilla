# Cursor Agent companion — probe notes

Evidence that Cursor Agent CLI can share one interactive TUI session with the
iPhone companion via **blocking hooks**, without ACP or the SDK as the Mac
runtime.

**CLI:** `agent` / `cursor-agent` (2026.09.18 probed)  
**Pattern:** Happy/Claude-style — hooks hold on a Flotilla Unix socket until
phone or Mac answers; hook stdout is only `allow` or `deny`.

## Verified locally

| Claim | Result |
|---|---|
| Interactive TUI is one process (`agent --resume <id> --trust`) | Yes |
| `agent create-chat` mints a UUID; `--resume` continues it | Yes |
| Hooks can block for seconds (Happy reports minutes) | Yes |
| Hook `deny` beats `--force` | Yes |
| No bridge / no Flotilla session → hook allows (fail-open) | Yes — do not brick IDE Cursor |
| Never return `ask` on `preToolUse` | Required — Cursor treats `ask` as allow |
| Dual-fire `preToolUse` then `beforeShellExecution` | Same `tool_use_id`; one card, both connections wait |
| Session always-allow | Flotilla bridge memory (`tool:pattern`); no Cursor `addRules` |
| Transcript JSONL under `~/.cursor/projects/…/agent-transcripts/<id>/` | Readable for companion cold-load |
| Resume memory lives in `~/.cursor/chats/<md5(cwd)>/<id>/store.db` | Opaque blob DAG; handoff destination seeds via `agent --print --resume` preamble |
| Release source | Delete chat dir + transcript folder (no delete CLI) |

## Capability alignment

Matches the summary bar the other four hit (see
`Ideas/mobile-companion/capability-matrix.md`):

- One process / one session; live text (`.lines`); status via hooks
- Approve / deny; always allow (**this session**); deny with note; deny and stop
- Questions / plan when tool names map (`AskQuestion`, `CreatePlan`, …); else
  permission card or “Needs the terminal”
- Prompt idle/busy + Mac draft (Ctrl-S stash + bracketed paste); interrupt Esc
- Create / reattach; errors on phone; first-answer-wins on Mac + phone while the
  hook holds

**Not claimed:** ACP or SDK dual-client; pixel-perfect Cursor TUI approval
chrome while the hook holds (Flotilla cards are the dual-surface UI).

## Flotilla wiring

| Piece | Location |
|---|---|
| `AgentKind.cursorAgent` + descriptor | SessionKit / AgentKit |
| Hook install + `flotilla-cursor.sh` | HooksKit `HookConfigurationWriter` |
| Payload + bridge | `CursorPermissionPayload`, `ClaudePermissionBridge` |
| Adapter | `CursorCompanionAdapter` |
| Transcript codec | `CursorTranscriptCodec` |

Unit coverage: `CursorPermissionPayloadTests`, `CursorBridgeHookTests`,
`CursorTranscriptCodecTests`.
