# OpenCode

| | |
| --- | --- |
| Binary | `opencode` (`AgentCatalog.openCode`) |
| Last verified | hook events **2026-08-27** (version not recorded). Installed 2026-10-06: **1.18.34**, not yet re-verified |
| Primary sources | OpenCode plugin and server docs; captured events in `FlotillaUnitTests/ProviderFixtures/opencode/` |
| Code | `HookConfigurationWriter.configureOpenCodeHooks`, `HookEventReceiver` (`.openCode`), `CompanionRuntimeLaunch` (`.openCode`), `OpenCodeCompanionAdapter`, `OpenCodeSessionProvider`, `OpenCodeTranscriptCodec` |

OpenCode is server-backed: the TUI talks to a local HTTP server, and Flotilla
binds that server to a private port so the companion can use the same API.
Status still comes from a small project plugin.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | stable project plugin `<cwd>/.opencode/plugins/flotilla-status.js`, fully overwritten on each launch. Legacy per-session `flotilla-status-*.js` files are deleted | **Verified** (events arrive) |
| Event routing | the plugin reads `process.env.FLOTILLA_HOOK_EVENT_FILE` at event time and is inert without it | **Verified** |
| Server | `--hostname 127.0.0.1 --port <free port>`; env `OPENCODE_SERVER_USERNAME=opencode`, `OPENCODE_SERVER_PASSWORD=<random>`; `OPENCODE_CONFIG_CONTENT` gains `{"autoupdate": false}`. Saved in `<support>/companion-runtimes/<id>.json` (0600) | code |
| Session identity | **discovered** (`.discoverable`); resume `--session <id>` | code |
| Model | `--model <provider>/<model>`; no effort control (`supportsEffortSelection == false`) | **Documented** |
| Plan mode | `--agent plan`, fresh sessions only | code |
| Initial prompt | `--prompt <text>` | code |

The plugin forwards four events as flat `{"event":"<name>"}` lines, with no
payload:

```js
"tool.execute.after": () => append("tool.execute.after"),
event: ({ event }) => { if (["session.idle","permission.asked","question.asked"].includes(event.type)) append(event.type) }
```

## Status: hooks

| Event | Flotilla status | Evidence |
| --- | --- | --- |
| `tool.execute.after` | `working` | **Verified** 2026-08-27 |
| `session.idle` | `readyForReview`. The name is a trap: it means "turn ended, composer free", not "nothing happened" | **Verified** 2026-08-27 |
| `permission.asked` | `waitingForInput` / `permission` | **Verified** 2026-08-27 |
| `question.asked` | `waitingForInput` / `question` | **Assumed**: wired because the sibling names checked out; never observed |

No payload is forwarded, so there is no tool name for *Top permissions* and
no plan signal on the hook path.

## Status: screen

Generic `TerminalScreenHeuristic` only. No OpenCode screen has been
captured; which generic markers OpenCode's TUI actually draws is
**unverified**.

## Dialogs

Companion only, over the private HTTP server (`OpenCodeCompanionAdapter`).
Every request carries Basic auth `opencode:<password>` and
`x-opencode-directory: <cwd>`.

| Need | Call |
| --- | --- |
| Bind to the launched session | `GET /session`: the newest root session (`parentID == nil`) whose `directory` is the cwd, created at least 2 s before launch. After 3 s with none, `POST /session {title}` and `POST /tui/select-session {sessionID}` |
| Sub-agent sessions | children by `parentID`, transitively |
| Pending dialogs | `GET /permission`, `GET /question`, filtered to related sessions |
| Permission card | `permission` (tool), `patterns[]` (summary), `metadata` (detail), `always[]` (pattern) |
| Question card | `questions[].{header,question,options[].{label,description},multiple}` |
| Answer permission | `POST /permission/<id>/reply {"reply": "once"\|"always"\|"reject", "message"?}`. Deny & stop is `reject` followed by `POST /session/<id>/abort` |
| Answer question | `POST /question/<id>/reply {"answers": [[…], …]}` |
| Prompt | `POST /session/<id>/prompt_async {"parts":[{"type":"text","text":…}], "model"?: {providerID, modelID}}` |
| Stop | `POST /session/<id>/abort` |
| Transcript | `GET /session/<id>/message` (`info.role`, `parts[].type` `text`/`tool` with `state.input/output/error`), at most every 5 s |
| Live events | SSE `GET /event`: `message.part.delta` (`field == "text"`), `session.idle`, `session.error`, `session.status` (`status.attempt`), `message.updated`/`removed` |

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Discovery (board titles) | `OpenCodeSessionProvider`: `GET http://127.0.0.1:4096/session` (OpenCode's **default** port, i.e. a user's own server, not Flotilla's private one) with a 1 s timeout, then fall back to SQLite `~/.local/share/opencode/opencode.db` (`session`, `part`) | code |
| Titles | a `title` starting with `New session - ` is a placeholder; otherwise synthesized from the first text `part` | code |
| Transcript read | none: `TranscriptCodecRegistry` has no OpenCode reader (the companion uses HTTP) | code |
| Transcript write | handoff **destination only**, via `opencode import <export file>`. OpenCode cannot delete a session, so it is never a source | `../session-handoff.md` |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `opencode models <provider> --verbose` | per-model JSON blocks (`id`, `providerID`, display name), only when an OpenCode subscription is configured | code |
| `opencode models <provider>` | one slug per line (fallback when `--verbose` fails) | code |
| No subscription | static shortlist (`AgentCatalog.openCode.fallbackModels`) | static |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/opencode/`: `tool.execute.after`,
`permission.asked`, `session.idle`. Missing: `question.asked`, screens,
HTTP/SSE samples.

## Update checklist

1. Plugin API: the `tool.execute.after` hook and the `event` handler still
   exist, with the same `event.type` names (`session.idle`, `permission.asked`,
   `question.asked`).
2. Trigger a question tool and confirm `question.asked` fires (this would
   promote it from **Assumed** to **Verified**).
3. Server: `--hostname/--port` flags, Basic auth env vars,
   `OPENCODE_CONFIG_CONTENT`, and the routes above (`/permission`, `/question`,
   `…/reply` bodies, `prompt_async`, `tui/select-session`).
4. SSE event names and the `message.part.delta` shape.
5. SQLite schema (`session.title/directory/time_updated`, `part.data`).
6. `opencode import` still accepts Flotilla's export format.

## Open items

- `question.asked` has never been observed.
- Session discovery's HTTP path targets port 4096, never the per-session port
  Flotilla starts, so for Flotilla-launched sessions it relies on the SQLite
  fallback, or on a user's own server running.
- No captured screens; the screen fallback's behavior here is untested.
