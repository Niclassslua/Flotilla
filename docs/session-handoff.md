# Session handoff

A running session can be moved from one coding agent to another without losing
its conversation. The session keeps its identity, its worktree and its place on
the board; only the agent behind it changes.

The move is a **transcode, not a summary**. The current agent's native
transcript is parsed into an agent-neutral in-memory model and re-emitted in the
destination's own format, so the destination resumes what it takes to be its own
prior session. No model is involved and nothing is paraphrased — the cost is one
file read and one file write, and a handoff completes in well under a second
before the destination's own startup time.

This document covers how that works, what it can and cannot carry, and what is
involved in adding a fifth agent.

## Not to be confused with `moveSessionToAgent`

`AppStore.moveSessionToAgent(sessionID:agent:)` already existed and is a
different operation: it changes `session.agent` and calls `restartSession`,
which clears `agentSessionID` and starts a **fresh** conversation. That is the
Kanban agent-lane gesture, and its reset is deliberate.

Handoff is `AppStore.handoffSession(sessionID:to:)`. Keep the two visibly
distinct in the UI and in code; they differ only in whether the conversation
survives, which is invisible until someone loses one.

## Data flow

```text
AppStore.handoffSession(sessionID:to:)
  │
  ├─ HandoffService.plan(for:to:)            ── read-only, no side effects
  │    ├─ resolve source transcript          (session.nativeTranscriptPath)
  │    ├─ verify embedded session id         (refuse a foreign transcript)
  │    ├─ reader.readNative                  → [CanonicalEntry]
  │    ├─ append handoffMarker
  │    └─ ToolCallPairing.pair               → synthesised / dropped counts
  │
  ├─ HandoffService.perform(_:)              ── the transaction
  │    ├─ writer.sanitize                    drop what the target cannot carry
  │    ├─ writer.writeNative                 → ResumeHandle(nativeSessionID, url)
  │    ├─ processManager.terminate           kill the PTY
  │    ├─ processManager.killServerSideSession   kill the tmux session
  │    ├─ session.agent / agentSessionID / nativeTranscriptPath ← destination
  │    ├─ session.pendingHandoff ← PendingHandoff(source…)      probation opens
  │    └─ processManager.startSession        launches the destination
  │
  ├─ repository.save                         persisted before probation ends
  ├─ AppStore.onAgentChanged → HookCoordinator.resync
  └─ scheduleHandoffSettlement               probation timer

probation window (default 6s)
  ├─ destination still alive  → HandoffService.finalize   source released
  └─ destination exited != 0  → HandoffService.rollback   source restored
```

The launch layer needs no changes. `ResumeHandle.nativeSessionID` is written
straight into `Session.agentSessionID`, and `SessionProcessManager.start`
(`SessionProcessManager.swift:172`) already turns that into
`ResumeIntent.resume(_:)` and renders it through the destination's
`AgentResumeStrategy`. A handoff is, from the process layer's point of view, an
ordinary resume of an ordinary session.

## Move, not copy

Exactly one agent owns a conversation at any moment. If both the source and the
destination transcripts survive, both agents will happily append to what they
each believe is the same history, and it forks silently — the user notices days
later when two divergent versions of the same session exist.

So a completed handoff **deletes the source**. What makes that safe is that the
deletion does not happen at the moment of the move.

### Probation

`perform` writes the destination and relaunches, but leaves the source
transcript exactly where it was and records a `PendingHandoff` on the session:
the source agent, its native session id, the path to its transcript, and a
timestamp. The session is now on probation.

- The destination survives the window → `HandoffService.finalize(_:)`
  (`HandoffService.swift:218`) releases the source: deletes its transcript and
  its sidecar state, clears `pendingHandoff`.
- The destination exits non-zero inside the window → `rollback(_:)`
  (`HandoffService.swift:236`) restores `agent`, `agentSessionID` and
  `nativeTranscriptPath` from the probation record, deletes the unused
  destination transcript, and relaunches the original agent — which still has
  its conversation, because nothing was deleted.

Six seconds is chosen because the failures this protects against — a missing
binary, an expired login, a refused sandbox — happen immediately. An agent still
running after six seconds has read the transcript and started work. The window
is `HandoffService.probationWindow`.

A clean exit (code 0) inside the window is treated as a session that finished,
not a move that failed: the source is released and the status lands on
`readyForReview`.

## The canonical model

`TranscriptKit.CanonicalEntry` is the hub format. Translating *N* agents
pairwise would need *N²* codecs; every agent instead reads *into* this and
writes *out of* it, and every pair works.

```swift
public enum CanonicalEntry: Sendable, Equatable {
    case userMessage(text: String, timestamp: Date)
    case assistantMessage(text: String, timestamp: Date)
    case toolUse(id: String, tool: String, input: Data, timestamp: Date)
    case toolResult(toolUseID: String, output: String, isError: Bool, timestamp: Date)
    case image(mimeType: String, base64: String, timestamp: Date)
    case handoffMarker(from: AgentKind, to: AgentKind, reason: String, timestamp: Date)
    case systemNote(text: String, timestamp: Date)
}
```

Entries are ordered oldest-first and each carries its own timestamp, because the
formats disagree about where time lives — Claude stamps every record, Codex
stamps the envelope around it.

`toolUse.input` holds the tool's arguments as **raw JSON bytes** rather than a
decoded structure, because the ends disagree about the encoding: Claude nests an
object, Codex stores a JSON *string*. Neither the hub nor any codec needs to
understand what is inside.

There is deliberately **no reasoning case**. A provider's reasoning trace is
bound to the turn and the provider that produced it and cannot be replayed
elsewhere; modelling it would imply a fidelity the mechanism cannot deliver.

`handoffMarker` is more than a record of the seam. Its presence tells a codec
that the transcript is being written for an agent that did not witness the
conversation, which for some destinations means writing extra records so their
UI can replay a history it never saw arrive.

## Two protocols, deliberately separate

```swift
public protocol TranscriptReading: Sendable {
    var agent: AgentKind { get }
    func transcriptURL(sessionID: String, workingDirectory: URL) throws -> URL?
    func embeddedSessionID(at url: URL) throws -> String?
    func readNative(at url: URL) throws -> [CanonicalEntry]
}

public protocol TranscriptWriting: Sendable {
    var agent: AgentKind { get }
    func sanitize(_ entries: [CanonicalEntry]) -> [CanonicalEntry]
    func writeNative(_ entries: [CanonicalEntry],
                     workingDirectory: URL,
                     sessionID: String) async throws -> ResumeHandle
    func removeNativeState(sessionID: String, workingDirectory: URL) throws
}
```

An agent can be a **source without being a destination**, or the reverse. This is
not hypothetical — two of the four shipped agents are one-directional — and it is
why the halves are separate protocols rather than one adapter with holes in it.

`ResumeHandle` is not a `URL`, because the agents resume by different things: a
file path, a UUID embedded in a filename, a server-assigned id. It carries
`nativeSessionID` (what the launch layer needs) and an optional `transcriptURL`
(what cleanup needs, `nil` for agents whose state is not a file).

`writeNative` is `async` because one destination is written by handing a
prepared file to its own CLI. The file-backed codecs never suspend.

### Capability matrix

| agent | source | destination | why |
|---|:-:|:-:|---|
| Claude Code | yes | yes | JSONL transcript, readable and writable |
| Codex CLI | yes | yes | rollout file; no catalog row required |
| Antigravity | yes | **no** | resume state is undocumented protobuf |
| OpenCode | **no** | yes | no supported way to release a session |

These differences are expressed **only** by which protocol each codec conforms
to. `TranscriptCodecRegistry.handoffTargets(from:)` derives the destination list
from the registered writers, so the picker cannot offer an impossible move and
there is no rule for anyone to remember. Adding a codec that conforms to one
protocol automatically produces the right UI.

The shipping registry is assembled in
`Flotilla/Services/TranscriptCodecRegistry+Flotilla.swift`, not inside
`TranscriptKit`, because one destination needs to run a CLI — and shelling out
belongs to `ProcessKit` in the app layer. `TranscriptKit` itself has one
dependency, `SessionKit`, and stays testable as pure encoding.

## Tool-call pairing

`ToolCallPairing.pair(_:)` runs on every handoff and is not tidying. Providers
reject a conversation containing a `tool_use` with no answering `tool_result`,
and the rejection arrives as an opaque failure on the receiving agent's *first*
turn — long after the move looked successful.

It is the normal case, not an edge case: a session is usually handed over
precisely because its agent is stuck or slow, which means it is often sitting
mid-tool-call.

The pass:

1. Reorders so every `toolUse` is immediately followed by its matching
   `toolResult`, with results gathered behind a whole assistant run rather than
   interleaved into it.
2. **Synthesises** a placeholder for any call with no result:
   `[flotilla: tool result missing — session ended before the tool returned]`,
   `isError: true`.
3. **Drops** results whose call is not in the transcript.

The counts surface on `HandoffService.Plan` (`synthesizedToolResults`,
`droppedOrphanResults`) so the UI can say what a move will cost before it
happens.

## Persistence

Migrations `v8`–`v10` add the columns below to `session`, all nullable and
flattened from the domain model the way `WorktreeInfo` already is.

They are three migrations rather than one for a reason worth remembering: a
migrator records each migration by name and skips what it has already applied,
so **editing a migration that has run anywhere adds the change for nobody** —
new installs get it, existing ones silently do not. `MigrationUpgradePathTests`
guards this by migrating a database only part of the way and then forward; a
fresh database structurally cannot catch it.

| column | domain |
|---|---|
| `nativeTranscriptPath` | `Session.nativeTranscriptPath` |
| `handoffSourceAgent` | `PendingHandoff.sourceAgent` |
| `handoffSourceSessionID` | `PendingHandoff.sourceSessionID` |
| `handoffSourceTranscriptPath` | `PendingHandoff.sourceTranscriptPath` |
| `handoffSourceModel` | `PendingHandoff.sourceModel` |
| `handoffSourceEffort` | `PendingHandoff.sourceEffort` |
| `handoffStartedAt` | `PendingHandoff.startedAt` |

`PendingHandoff` is reassembled in `SessionRecord.toDomain()` only when all
parts are present; a row carrying some but not others is a half-written
probation record and reads as no handoff in flight.

`nativeTranscriptPath` exists so the source is never rediscovered by recency.
Several sessions can share a working directory, and "the newest transcript here"
resolves to a different conversation.

---

# Agent formats

These formats are undocumented by their vendors and change between releases.
Every codec therefore **skips record types it does not recognise** rather than
failing, and never assumes a field is present. A strict parser would break on
every upstream version bump.

## Claude Code

**Location** `~/.claude/projects/<cwd-slug>/<session-uuid>.jsonl`

`<cwd-slug>` is the absolute working directory with every `/` replaced by `-`.

> The slug is derived from the **raw** path, never `standardizedFileURL`. That
> API resolves symlinks only for paths that *exist*, so `/private/tmp/x` becomes
> `/tmp/x` once the directory is created and stays `/private/tmp/x` before it —
> which would silently relocate a session's transcript the first time its
> worktree was created. The raw path is also what Flotilla hands the process as
> its working directory, so the slug and the agent's own view of its cwd stay in
> step.

Because the mapping is ambiguous (a path component containing a dash is
indistinguishable from a separator), `transcriptURL` treats the slug as a hint
and falls back to matching the file by name across project directories — which
is exact, because the filename *is* the session id.

**Structure** Records form a linked list through `uuid` / `parentUuid`. Claude
will not load a transcript whose chain is broken.

Conversation records:

```text
{"type":"user",     "uuid","parentUuid","timestamp","message":{"role":"user","content": …}}
{"type":"assistant","uuid","parentUuid","timestamp","message":{"role":"assistant","content":[…]}}
```

`content` is a bare string for simple user text, otherwise an array of typed
blocks: `text`, `tool_use` (`id`, `name`, `input` as a nested object),
`tool_result` (`tool_use_id`, `content`, `is_error`), `image`
(`source.media_type`, `source.data`), `thinking`.

Every record also carries a shared envelope: `cwd`, `sessionId`, `version`,
`userType: "external"`, `entrypoint: "cli"`, `permissionMode`, `gitBranch`,
`isSidechain`.

The file interleaves a dozen sidecar record types that are not conversation and
are skipped on read: `mode`, `permission-mode`, `atis-latch`, `last-prompt`,
`bridge-session`, `cost-state`, `file-history-snapshot`, `file-history-delta`,
`ai-title`, `attachment`.

**Reading** Filters to `type == "user" | "assistant"`. Records with
`isSidechain: true` are excluded — those are a subagent's own conversation with
its own parent chain, and splicing them into the main thread would interleave
two histories into one unreadable list. `thinking` blocks are dropped.

**Writing**

- A leading `{"type":"permission-mode", …}` record.
- Consecutive assistant text and tool calls **coalesce into one** `assistant`
  record whose `content` is a mixed block array. One agent turn is one record.
- Consecutive tool results coalesce into one `user` record — and a user message
  that immediately follows is folded into that *same* record as a trailing
  `text` block, because the results and the reply are one user turn.
- `systemNote` → `{"type":"system","subtype":"local_command"}`, which does **not**
  participate in the parent chain.
- `handoffMarker` is not written; Claude renders the conversation from the same
  records the model reads, so it needs no replay hint.
- Directory mode `0o700`, written atomically.

**Sidecar state released on move-out** (all best-effort; a missing sidecar is
not a failure):

```text
~/.claude/projects/<slug>/<id>.jsonl   ~/.claude/tasks/<id>/
~/.claude/todos/<id>-agent-<id>.json   ~/.claude/file-history/<id>/
~/.claude/debug/<id>.txt               ~/.claude/telemetry/1p_failed_events.<id>.*
~/.claude/session-env/<id>/
```

## Codex CLI

**Location** `~/.codex/sessions/YYYY/MM/DD/rollout-<UTC timestamp>-<uuid>.jsonl`

Note the date-nested directories. The UUID in the filename **is** the session id
Codex resumes by, which is what lets a handoff pin identity: write the file
under an id we chose, then launch `codex resume <that id>`.

Codex also keeps a catalog at `~/.codex/state_5.sqlite` (table `threads`) that
drives its picker. **It is not required.** A rollout written with no
corresponding row resumes cleanly — verified — so the codec is pure file I/O
with no SQLite dependency and no schema-drift guard. Codex writes its own row
when it runs.

**Structure** Every line is `{timestamp, type, payload}`. Codex's own files also
carry an `ordinal`; it is not required to load one and is not written.

Exactly two header records, both minimal:

```text
session_meta  { id, timestamp, cwd, originator:"codex-tui",
                cli_version, source:"cli", model_provider }
turn_context  { turn_id, model, cwd }
```

Body mapping:

| canonical | record |
|---|---|
| `userMessage` | `response_item` / `message`, role `user`, `content:[{type:"input_text"}]` |
| `assistantMessage` | `response_item` / `message`, role `assistant`, `content:[{type:"output_text"}]` |
| `toolUse` | `response_item` / `function_call` — `{call_id, name, arguments}`, arguments a **JSON string** |
| `toolResult` | `response_item` / `function_call_output` — `{call_id, output}` |
| `systemNote` | `compacted` — `{message}` |
| `image`, `handoffMarker` | not written |

**The two audiences.** Codex builds the model's context from `response_item`
records but draws its scrollback from `event_msg` records. A file with only the
former resumes into a session where the model knows everything and the user
stares at an empty screen. So when the transcript carries a handoff marker,
every human-visible turn is written **twice**:

```text
event_msg { type:"user_message",  message, images:[], local_images:[],
            audio:[], local_audio:[], text_elements:[] }
event_msg { type:"agent_message", message, phase:"final_answer",
            memory_citation:null }
```

Tool activity is mirrored as `event_msg` commentary (`phase:"commentary"`)
rather than as the `item_completed` / `CommandExecution` items Codex itself
writes. Those are built from live process state — `process_id`, a `file://` cwd,
a `parsed_cmd` breakdown — that a transcode does not have, and a malformed one
risks a record Codex cannot parse, costing the resume entirely. The commentary
carries the tool name and a readable rendering of its arguments; nothing
invented reaches the model, which reads the real `function_call` records.

**Never emit `reasoning`.** `encrypted_content` is bound to the turn and the
provider that produced it. Reasoning items are also skipped on read.

**Fallback constants** `cli_version` ← `codex --version` (fallback `0.125.0`),
`model_provider` ← `openai`, model ← `gpt-5-codex`. All injectable.

**Known lossiness** `function_call_output` has no error field, so a failed tool
reads back as an ordinary result. Inventing a key is worse than losing the flag
— an unrecognised key is at best ignored and at worst makes the record
unparseable — and the failure is still legible to the model because it is in the
output text, which is where a real tool puts it too.

## OpenCode

**Destination only.** OpenCode keeps conversations in a SQLite database
(`~/.local/share/opencode/opencode.db`, tables `session` / `message` / `part`)
held open by a running server, so there is no transcript file to read or delete.
Its CLI offers `export` and `import` but **no way to remove a session**, which
means a move *out of* OpenCode could not release OpenCode's copy and two agents
would claim one conversation. Rather than write into a live server's database
behind its back, the codec only ever adds.

**Written through the CLI.** `writeNative` prepares an export file and hands it
to `opencode import <file>` via an injected closure
(`OpenCodeTranscriptCodec.SessionImporting`), supplied in the app layer by a
`ProcessKit` command runner. The session is therefore created by OpenCode
itself, through a supported interface.

**Structure**

```text
{ "info":     { id, slug, projectID, directory, path, title, agent,
                model:{id,providerID,variant}, version, summary, cost,
                tokens, time:{created,updated} },
  "messages": [ { "info": …, "parts": [ … ] } ] }
```

Two shapes must be exact or the import fails with `Missing key at ["id"]`:

- **Every part** needs its own `id`, `sessionID` and `messageID` — not just
  `type` and `text`.
- **User and assistant messages use different `info` schemas.** A user message
  carries `time:{created}`, `model:{providerID,modelID}` and `summary:{diffs}`.
  An assistant message carries `parentID`, `mode`, `path:{cwd,root}`, `cost`,
  `tokens`, flat `modelID` / `providerID`, `time:{created,completed}` and
  `finish`.

**Sanitising** OpenCode's message model is text parts, so tool activity is
folded into readable text rather than dropped — `[ran <tool> <args>]`,
`[tool result] …`, `[tool failed] …`. The next agent still knows what ran; it
does not inherit structured tool records. Images are dropped.

**Model inheritance** A handed-off session comes up on whatever model OpenCode
defaults to, which may be a free-tier model that queues for a long time and
makes a perfectly good handoff look broken. `providerID` / `modelID` are
initializer parameters if you want Flotilla to pin the destination model instead.

## Antigravity

**Source only, permanently.** The file the codec reads —
`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl` —
is a *log*, not the state Antigravity resumes from. Its real state is one SQLite
database per conversation (`conversations/<id>.db`, table `steps`) whose every
payload is an opaque protobuf blob with no published schema. Synthesising one
would mean reverse-engineering wire format field by field, and it would break
silently on each release.

**Structure** One JSON object per line:

```text
{ step_index, source, type, status, created_at, content }
```

Mapping by `source`:

| source | canonical |
|---|---|
| `USER_EXPLICIT` | `userMessage` |
| `MODEL` | `assistantMessage` |
| `SYSTEM` | `systemNote` |

`type` values seen include `USER_INPUT`, `PLANNER_RESPONSE`, `GENERIC` and
`CHECKPOINT`; anything with an unrecognised `source` is skipped.

User steps arrive wrapped in a `<USER_REQUEST>` element, which is stripped — the
next agent should read the request, not Antigravity's framing of it.

**No identity to verify.** The log records no session id of its own; the
conversation id is the directory it sits in. `embeddedSessionID` returns `nil`,
which says "cannot verify" rather than asserting a match, and the transaction
skips ownership verification rather than failing it.

**Tool activity is not distinguished.** It arrives as `GENERIC` model text, so
this codec carries the conversation, not the tool-call structure. That is a
limit of the log, not a shortcut.

## What does not survive a move

- **Reasoning traces.** Structurally impossible across providers.
- **Tool-result error flags into Codex.** No field exists; the failure survives
  in the text.
- **Structured tool calls into OpenCode.** Folded into readable text.
- **Tool-call structure out of Antigravity.** Never in the log to begin with.
- **Images into Codex or OpenCode.**
- **Subagent (sidechain) conversations out of Claude.**
- **The session's model and effort.** Both name one vendor's options —
  `opusplan` means nothing to Codex, `gpt-6-astra` nothing to Claude, and
  `.minimal` / `.ultra` are Codex-only effort levels. A handoff resets both to
  the destination's own defaults rather than handing it a model it will refuse
  to start on. `PendingHandoff` remembers them so a rollback restores what the
  session was running.

`HandoffService.Plan` reports the countable part of this before the move.

---

# Integrating another agent

The work is one file plus a registry entry. Nothing in the transaction, the UI
or the launch pipeline needs to change.

### 1. Decide which halves are possible

Ask two questions about the agent's storage, in this order:

1. **Can its conversation be read?** Is there a file, an export command, or a
   readable database? If yes it can be a **source**.
2. **Can a conversation be written *and* released?** Writing alone is not
   enough. If the agent has no supported way to delete a session, it cannot be a
   source (the move could not release it), and if its state is opaque it cannot
   be a destination. Only implement `TranscriptWriting` when both writing and
   removal are supported through an interface the vendor offers.

Conform to whichever protocols the answers permit. Do not implement a half you
cannot honour — the registry derives the UI from conformance, and a codec that
throws `unimplemented` is worse than one that is simply absent.

### 2. Write the codec

Add `Packages/TranscriptKit/Sources/TranscriptKit/Codecs/<Agent>TranscriptCodec.swift`.

Rules that apply to every codec:

- **Locate by session id, never by recency or by scanning a directory for the
  newest file.** Sessions share working directories.
- **Never standardize paths.** See the Claude slug note above.
- **Skip unknown record types.** Do not fail a whole file on one bad line.
- **Inject anything that is not pure file I/O** — CLI versions, model
  identifiers, subprocess invocations — through the initializer, so the codec
  stays deterministic under test and `TranscriptKit` stays free of `ProcessKit`.
- **`sanitize` must never throw.** A destination that cannot carry an image
  drops the image; it does not fail the move.
- Take a `homeDirectory` (or equivalent root) initializer parameter defaulting
  to the real one, so tests can build a transcript tree in a temporary
  directory.

### 3. Register it

Add it to `TranscriptCodecRegistry.flotilla(commandRunner:locator:)` in
`Flotilla/Services/TranscriptCodecRegistry+Flotilla.swift` — to `readers`,
`writers`, or both. If the codec needs to run a CLI, build the closure here with
the injected `CommandRunning`; that is the layer that is allowed to shell out.

The session bar menu and the command palette section pick it up with no further
change.

### 4. Confirm the launch side

The agent needs an `AgentDescriptor` with a usable `AgentResumeStrategy`
(`Packages/AgentKit/Sources/AgentKit/AgentDescriptor.swift`). `.assignable` lets
Flotilla pin the identity at launch; `.discoverable` means the agent chooses its
own id and the codec must return the id the agent will actually resume by.
`.unsupported` means handoff cannot work regardless of the codec.

### 5. Tests

Unit tests live in `FlotillaUnitTests/`, not in the package — no local package
has its own `Tests/` directory. Follow the existing convention: no checked-in
fixtures, synthesise transcript content as inline string literals into
`FileManager.default.temporaryDirectory`.

Cover at least: locating by id, reading a realistic record mix, skipping unknown
records and malformed lines, round-tripping the codec's own output, and — for a
destination — that the file's required shapes are present.

---

# Verifying a codec against the real CLI

Unit tests prove a codec is self-consistent. They cannot prove the agent will
accept what it produces, and that is the failure mode that actually occurs: a
file that round-trips perfectly and the agent silently refuses, or loads with an
empty screen, or loads without giving the model the history.

Three checks, in order of what they catch.

### 1. Does the agent load it at all?

Write a transcript with the codec into the agent's real storage, then resume it.
A small executable that links `TranscriptKit` is enough:

```swift
let entries: [CanonicalEntry] = [ /* a short conversation with a tool call */ ]
let paired = ToolCallPairing.pair(
    entries.appendingHandoffMarker(from: .claudeCode, to: .codexCLI)
)
let handle = try await codec.writeNative(
    codec.sanitize(paired.entries),
    workingDirectory: scratchProject,
    sessionID: UUID().uuidString
)
print(handle.nativeSessionID)
```

Then resume with the agent's own resume invocation. A "session not found" here
usually means the location or the identity is wrong, not the content.

### 2. Does the user see the conversation?

Resume interactively and look at the scrollback. This is the check that found
the Codex `event_msg` requirement: the model had full context while the screen
was blank, and no automated assertion would have noticed. Include a tool call in
the fixture — tool activity is rendered by a different mechanism than messages
in at least one agent.

### 3. Does the *model* have the history?

The one that matters, and the one most easily assumed. Ask a question only the
transcript can answer, and forbid tools:

```text
Answer only from our existing conversation, run no tools.
Which file were you about to read, and what exactly did the ls command output?
```

A correct answer proves messages, tool calls **and** tool results crossed. Most
agents have a non-interactive mode that makes this scriptable
(`claude -p --resume <id> …`, `codex exec resume <id> …`,
`opencode run --session <id> …`).

Run this against **real** source transcripts, not only hand-built fixtures. A
real transcript exposes record types and shapes that a fixture will not — a
session whose assistant turns are pure `thinking` and tool calls with no prose,
for instance, or ten `attachment` records interleaved with the conversation.

### 4. The process pipeline

`FlotillaUnitTests/RealHandoffPipelineTests.swift` drives a handoff through real
`SystemPTYProcess` and the real tmux binary with `/bin/sh` standing in for the
agents, then asks tmux what it is actually running via `pane_start_command`.

This exists because `SessionProcessManager.start` short-circuits when a tmux
session already exists (`SessionProcessManager.swift:181`): `new-session -A`
reattaches to the live pane and never runs the command after `--`. A handoff
that failed to destroy the server-side session would look entirely successful —
no error, a PTY attaches, the terminal renders — while the old agent kept
running against the new transcript. Only tmux can tell you.

Extend that test if a new agent's launch path differs.

---

# Invariants

Things that will bite whoever changes this area.

**The handoff branch must stay ahead of the resume self-heal.**
`AppStore.handleProcessEvent` retries a failed resume by clearing
`agentSessionID` and relaunching with a blank context. That is right for a stale
resume and catastrophic after a handoff — it would discard the transcript the
move just wrote while the source sits waiting to be released. The
`handoffProbation` check is at `AppStore.swift:1198` and must remain the first
thing the `.terminated` case does.

**A relaunch onto a different binary requires both kills.**
`terminate(sessionID:)` *and* `killServerSideSession(sessionID:)`, in that order,
before `startSession`. See the tmux note above.

**Hook observation must be rebuilt after the agent changes.**
`HookEventReceiver` branches its entire JSON schema on the `AgentKind` captured
at construction, and `HookCoordinator.observe` is idempotent by design — it
returns early when a monitor exists. `HookCoordinator.resync(sessionID:)`
(`HookCoordinator.swift:113`) tears down and rebuilds; `AppStore.onAgentChanged`
fires it on both the success and rollback paths. `observeAll()`'s own teardown
cannot cover this, because it keys off `store.process(for:) == nil` and
`terminate` deliberately leaves the process entry in place until the exit
handler fires.

**Never rediscover the source by recency**, and never derive a transcript
location with `standardizedFileURL`.

**`session.workingDirectory` can change under a running process.** For
agent-managed worktrees, `createSession` launches with the project root and
`applySelfReport` later rewrites `workingDirectory` to the discovered worktree
*without restarting the agent*. Locate by session id; stamp a written
transcript's cwd with the session's current `workingDirectory`, which is what
the relaunch will use.

**Status changes go through `AppStore.transition(_:to:origin:)`.** Handoff uses
`SessionStatusOrigin.handoff(from:to:)` and `.handoffRollback`
(`Flotilla/Services/SessionStatusTrace.swift`).
