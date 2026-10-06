# OpenCode

| | |
| --- | --- |
| Binary | `opencode` (`AgentCatalog.openCode`) |
| Valid through | OpenCode **1.18.34**, verified 2026-10-06 |
| Primary sources | OpenCode plugin and server docs; captured events in `FlotillaUnitTests/ProviderFixtures/opencode/` |
| Code | `HookConfigurationWriter.configureOpenCodeHooks`, `HookEventReceiver` (`.openCode`), `CompanionRuntimeLaunch` (`.openCode`), `OpenCodeCompanionAdapter`, `OpenCodeSessionProvider`, `OpenCodeTranscriptCodec` |

OpenCode is server-backed: each Flotilla launch binds its own local HTTP
server to a private port. Flotilla uses a global, environment-gated plugin for
lifecycle events, and the server API for dialogs, status, transcript reads,
and safe prompt delivery.

## Launch & configuration

| What | How | Evidence |
| --- | --- | --- |
| Hooks | user-level `$XDG_CONFIG_HOME/opencode/plugins/flotilla-status.js` (default `~/.config/opencode/plugins/`); legacy project copies are removed | **Verified** 1.18.34 |
| Event routing | the plugin reads `process.env.FLOTILLA_HOOK_EVENT_FILE` at event time and is inert without it | **Verified** |
| Server | `--hostname 127.0.0.1 --port <free port>`; env `OPENCODE_SERVER_USERNAME=opencode`, `OPENCODE_SERVER_PASSWORD=<random>`; `OPENCODE_CONFIG_CONTENT` gains `{"autoupdate": false}`. Saved in `<support>/companion-runtimes/<id>.json` (0600) | code |
| Session identity | `session.created` pins the id; CLI discovery is fallback (`.discoverable`); resume `--session <id>` | **Verified** 1.18.34 |
| Model | `--model <provider>/<model>`; no effort control (`supportsEffortSelection == false`) | **Documented** |
| Plan mode | `--agent plan`, fresh sessions only | code |
| Initial prompt | `--prompt <text>` | code |

The plugin forwards lifecycle and dialog events as flat JSONL records, with
the native session id, status, tool, and dialog metadata when available:

```js
"tool.execute.before": input => append("tool.execute.before", {sessionID: input.sessionID, tool: input.tool}),
event: ({ event }) => append(event.type, event.properties)
```

## Status: hooks

| Event | Flotilla status | Evidence |
| --- | --- | --- |
| `tool.execute.before` / `tool.execute.after` | `working` | **Verified** 1.18.34 |
| `session.status` busy / retry / idle | working / working / readyForReview | **Verified** 1.18.34 |
| `session.idle` | `readyForReview`; turn ended and composer free | **Verified** 1.18.34 |
| `permission.asked` and `question.asked` | waitingForInput / permission or question | **Verified**, including a live question event, 1.18.34 |
| `session.error` | error is reported in transcript; following idle ends the turn | **Verified** 1.18.34 |
| `session.created` | pins the native session id | **Verified** 1.18.34 |

Tool names are available for activity attribution. OpenCode has no distinct
plan approval status hook; its question and permission events remain separate.

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
| Prompt | `POST /tui/append-prompt {"text":…}`, then `POST /tui/submit-prompt` on the per-session private server |
| Stop | `POST /session/<id>/abort` |
| Transcript | `GET /session/<id>/message` (`info.role`, `parts[].type` `text`/`tool` with `state.input/output/error`), at most every 5 s |
| Live events | SSE `GET /event`: `message.part.delta` (`field == "text"`), `session.idle`, `session.error`, `session.status` (`status.attempt`), `message.updated`/`removed` |

## Sessions & transcripts

| What | Where / how | Evidence |
| --- | --- | --- |
| Discovery (board titles) | `opencode session list --format json`; SQLite (`session`, `part`) is a compatibility fallback | **Verified** 1.18.34 |
| Titles | a `title` starting with `New session - ` is a placeholder; otherwise synthesized from the first text `part` | code |
| Transcript read | `opencode export <session-id>` to a private temporary staging file; companion uses the authenticated server API | **Verified** 1.18.34 |
| Transcript write | handoff destination via `opencode import <export file>` | **Verified** 1.18.34 |
| Source cleanup | after destination probation, `opencode session delete <session-id>` relinquishes the source | **Verified** 1.18.34 |

## Models & effort

| Query | Parsed as | Evidence |
| --- | --- | --- |
| `opencode models <provider> --verbose` | per-model JSON blocks (`id`, `providerID`, display name), only when an OpenCode subscription is configured | code |
| `opencode models <provider>` | one slug per line (fallback when `--verbose` fails) | code |
| No subscription | static shortlist (`AgentCatalog.openCode.fallbackModels`) | static |

## Fixtures

`FlotillaUnitTests/ProviderFixtures/opencode/`: tool lifecycle, status, and
permission/question hooks. The API and export formats are exercised by
provider integration probes; screen captures are not used for these states.

## Update checklist

1. Plugin API: the `tool.execute.after` hook and the `event` handler still
   exist, with the same `event.type` names (`session.idle`, `permission.asked`,
   `question.asked`).
2. Server: private `--hostname/--port`, Basic auth env vars,
   `OPENCODE_CONFIG_CONTENT`, `/session/status`, dialog routes, and the TUI
   append/submit prompt endpoints.
3. Plugin event names, properties, and sub-agent filtering.
4. SSE event names and `message.part.delta` shape.
5. `session list --format json`, `export`, `import`, and `session delete`.
6. SQLite fallback schema (`session.title/directory/time_updated`, `part.data`).

## Open items

- No captured screens; the generic fallback's behavior for OpenCode remains
  unverified. Hook and private-server feeds cover the documented states.
