# Provider integration reference

Flotilla drives five third-party agent CLIs it does not control. Everything it
knows about them — what state a session is in, which dialog is open, where the
conversation lives on disk, which flags launch it — comes from one of a handful
of techniques, each pinned to the behavior of a specific CLI release. This
directory records, per provider, **what Flotilla relies on, how, and against
which version it was last verified**, so a provider update can be reviewed by
diffing behavior against this baseline instead of rediscovering it.

| Provider | Binary | Reference | Valid through |
| --- | --- | --- | --- |
| Claude Code | `claude` | [claude-code.md](claude-code.md) | valid through 2.1.291 · 2026-10-06 (full live probe) |
| Codex CLI | `codex` | [codex-cli.md](codex-cli.md) | valid through 0.160.1 · 2026-10-06 (schema/help inspected; hook probes through 0.155.0) |
| OpenCode | `opencode` | [opencode.md](opencode.md) | valid through 1.18.34 · 2026-10-06 (live probe; snapshot captured 1.18.32) |
| Antigravity | `agy` | [antigravity.md](antigravity.md) | valid through 1.3.0 · 2026-10-06 (full live probe) |
| Cursor Agent | `agent` | [cursor-agent.md](cursor-agent.md) | valid through 2026.10.01-e373342 · 2026-10-06 (full live probe) |

Cross-cutting references:

- [CHANGES.md](CHANGES.md) — provider version bumps and integration changes.
- [`snapshots/`](snapshots/) — CLI help, configured event names, and provider
  protocol snapshots captured by `Scripts/provider-snapshot.sh`.

- [screen-detection.md](screen-detection.md) — every string Flotilla matches
  on a rendered terminal, in one inventory. Screen text is the most fragile
  surface; start here when a provider redesigns its TUI.
- [`../provider-hooks.md`](../provider-hooks.md) — the status pipeline itself
  (`HookEventReceiver`, `SessionScreenMonitor`, the arbiter, the status
  machine, debugging with `log stream`). The provider pages describe *inputs*
  to that pipeline; that page describes the pipeline.
- [`../session-handoff.md`](../session-handoff.md) and
  [`Antigravity/FORMAT.md`](../../Packages/TranscriptKit/Sources/TranscriptKit/Codecs/Antigravity/FORMAT.md)
  — transcript codec internals in full.
- [`../companion.md`](../companion.md) — the iPhone companion protocol that
  the per-provider dialog adapters serve.

## Techniques at a glance

| Technique | Claude Code | Codex CLI | OpenCode | Antigravity | Cursor Agent |
| --- | --- | --- | --- | --- | --- |
| Hook install | `--settings <json>` per process | `--config hooks.*` per process | user-level `~/.config/opencode/plugins/flotilla-status.js` (env-gated) | user-level `~/.gemini/config/hooks.json` (env-gated) | user-level `~/.cursor/hooks.json` (env-gated) |
| Hook transport | stdin JSON → event file | stdin JSON → event file | global plugin → event file | wrapper → `{"event","payload"}` | wrapper → `{"flotilla_provider","hook_event_name","payload"}` |
| Hook decides anything? | Yes — `PermissionRequest` via companion socket | Yes — `PermissionRequest` via companion socket (local TUI only) | No | No (a hook can only deny in 1.3.0) | No; `stop` hands queued phone prompts over as `followup_message` |
| Status from screen | trust dialog and interrupt only | fallback | fallback | fallback; **only** source for approval dialogs | fallback |
| Dialog source for the phone | hook (`PermissionRequest`) | app-server JSON-RPC | private HTTP API + SSE | hook payload + `--log-file` + screen | screen only (`CursorDialog`, also used for board status) |
| Answering a dialog | hook stdout | JSON-RPC reply | private HTTP `POST …/reply` | keystrokes | keystrokes |
| Session ID | assigned (`--session-id`) | discovered (SQLite + index) | plugin identity; CLI list fallback | discovered (brain dir + SQLite) | assigned (`--resume <uuid>`) |
| Transcript read | JSONL | rollout JSONL | CLI export (handoff) + private HTTP (companion) | SQLite + protobuf | JSONL |
| Model list | `claude --print /model` | `codex debug models` | `opencode models <provider>` (with a subscription; else static) | `agy models`, `agy --help` | `agent --list-models` |

## Evidence levels

Every claim on a provider page carries one of these markers. They are the
point of the exercise: when a provider updates, the **Verified** rows are what
to re-check, and the **Assumed** rows are where a silent break is most likely.

| Marker | Meaning |
| --- | --- |
| **Verified** *(version, date)* | Observed against a real CLI run: a live probe, a captured payload/screen in `FlotillaUnitTests/ProviderFixtures`, or an on-disk artifact. |
| **Documented** | Taken from the provider's own documentation; not independently observed. |
| **Assumed** | Wired by analogy (e.g. "the sibling event names checked out") or inferred from code. No direct observation. |
| **Drift** | Observed behavior that differs from what the code or an older note assumes. Each one is listed under the page's *Open items*. |

## Captured fixtures

`FlotillaUnitTests/ProviderFixtures/<provider>/` holds sanitized hook payloads
(`hooks/*.json`) and terminal captures (`screens/*.txt`), each listed in that
provider's `manifest.json` with its capture date, CLI version, and the
observation it must produce. `ProviderFixtureTests` replays all of them through
`HookEventReceiver` and `TerminalScreenHeuristic`:

```bash
xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -configuration Debug \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test \
  -only-testing:FlotillaUnitTests/ProviderFixtureTests
```

A manifest entry with `knownGap` documents something Flotilla currently gets
wrong. `currentlyObserved` pins today's result, and the desired `expect` runs
under `XCTExpectFailure`, so a fix shows up as an unexpected pass, prompting
you to delete the `knownGap` entry.

### Capturing a new fixture

Real payloads are already on disk. Every session's hook stream is in
`~/Library/Application Support/Flotilla/hooks/<session UUID>.jsonl`, one
object per line, exactly as the provider (or Flotilla's wrapper) wrote it.

1. Find the newest line for the event you care about, e.g.
   `grep -h '"hook_event_name":"Stop"' ~/Library/Application\ Support/Flotilla/hooks/*.jsonl | tail -1`.
2. Recover the CLI version where the payload allows it. Cursor carries
   `cursor_version`. For Claude Code, the transcript at `transcript_path` has a
   `version` field. For Codex, the rollout at `transcript_path` has
   `cli_version` in its `session_meta` header. For OpenCode and Antigravity,
   record the installed `--version` at capture time.
3. Sanitize before committing. Keep every key and every value the
   classifiers read (event names, tool names, `notification_type`,
   `fullyIdle`, `status`, `permission_mode`, enum-like fields). Replace
   identifiers with `00000000-0000-4000-8000-…`, home paths with
   `/Users/dev/…`, and free text (commands, prompts, assistant messages, tool
   output, e-mail addresses) with neutral placeholders. No user content may
   reach the repository.
4. For screens, use
   `tmux -L flotilla capture-pane -p -t flotilla-<session UUID>` while the
   provider shows the state. Keep the bottom ~20 lines, which is what the
   classifiers read, and replace conversation text above the status area.
5. Add the file and a manifest entry. Set `expect` to the observation
   Flotilla *should* produce (`null` for none). If that differs from what it
   produces today, add `currentlyObserved` and `knownGap`.

### Capturing a provider release snapshot

Run `Scripts/provider-snapshot.sh` after installing provider updates, or pass
one provider key (`claude-code`, `codex-cli`, `antigravity`, `opencode`, or
`cursor-agent`). It stores the CLI version, help output, and Flotilla's
configured hook event names under `docs/providers/snapshots/<provider>/<version>/`.
Codex also gets the generated app-server JSON schema. OpenCode starts a local
`opencode serve` process briefly and saves its `/doc` OpenAPI response. Review
the resulting diff with the provider page and upstream release notes before
updating the validity stamp.

## When a provider updates

Work through the provider's page top to bottom; each section ends with the
concrete checks for that surface. The fast path:

1. `<binary> --version`. Note it in the page header once you're done.
2. Run `ProviderFixtureTests`. A failure is a format or classification change
   in something already captured.
3. Run one real session through each status: working, a permission prompt, a
   question, a plan (where supported), and turn end. Watch
   `log stream --predicate 'subsystem == "com.niclassslua.flotilla" AND category == "SessionStatus"' --level debug`.
   Every transition should cite a `hook:` cause. Screen causes for states a
   hook should have reported mean a hook stopped firing or changed shape.
4. Capture any new or changed payload or screen as a fixture (above).
5. Re-run the model listing command from the page and compare.
6. Update the page: the version in the header, the evidence markers you
   re-verified, and *Open items*.

## Adding a provider

Copy an existing page as the template. Every provider page has these
sections, in this order, so pages can be compared side by side:

1. **Header**: binary, verified version and date, primary sources.
2. **Launch & configuration**: argv, environment, files Flotilla writes,
   plan mode, effort, prompt delivery.
3. **Status: hooks**: registered events, payload fields read, resulting
   status.
4. **Status: screen**: which generic markers apply and which strings are
   specific to this provider.
5. **Dialogs**: how permission, question, and plan prompts are detected and
   answered (desktop and companion).
6. **Sessions & transcripts**: storage, ID assignment or discovery, resume,
   titles, transcript codec.
7. **Models & effort**: discovery commands and how their output is parsed.
8. **Fixtures**: what is captured.
9. **Update checklist**: provider-specific checks.
10. **Open items**: drift, gaps, unverified assumptions.

Then follow [`../provider-hooks.md`](../provider-hooks.md) → "Adding or
changing a provider", and add at least one fixture per mapped hook event.
`testEveryAgentHasCapturedFixtures` fails until the new `AgentKind` has some.
