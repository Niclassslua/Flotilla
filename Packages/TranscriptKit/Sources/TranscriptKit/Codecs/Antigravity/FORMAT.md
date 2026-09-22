# Antigravity CLI (`agy`) wire format — reverse-engineered notes

This is not documentation Google publishes. Everything below was derived by
running controlled, single-action probes against a real local `agy` install
(`~/.gemini/antigravity-cli/`) and diffing the resulting SQLite/protobuf bytes
with `protoc --decode_raw`. It is the map `AntigravityWireFormat` and
`AntigravityTranscriptCodec` are built against — keep this file in sync with
the code, and update it the day an `agy` release makes something here wrong.

## Where the state lives

`~/.gemini/antigravity-cli/conversations/<conversation-uuid>.db` — one SQLite
database per conversation. The table that matters:

```sql
CREATE TABLE `steps` (
  `idx` integer,                 -- step order; PRIMARY KEY
  `step_type` integer,           -- 14=user, 15=assistant, 101=system notice, 132=tool call
  `status` integer,
  `has_subtrajectory` numeric,
  `metadata` blob,               -- == the envelope embedded at step_payload field 5, byte for byte
  `error_details` blob,
  `permissions` blob,
  `task_details` blob,
  `render_info` blob,
  `step_payload` blob,           -- the protobuf described below
  `step_format` integer
);
```

Unlike the Antigravity **IDE**'s conversation store (`.pb` files wrapped in
Electron's `safeStorage`, Keychain-bound, effectively opaque without breaking
out of the sandbox), the CLI's blobs are **plain, unencrypted protobuf**.
`protoc --decode_raw` parses them directly.

`~/.gemini/antigravity-cli/brain/<id>/.system_generated/logs/transcript.jsonl`
is a separate, lossy *display* log — useful for session discovery (see
`AntigravityTranscriptCodec.discoverSession`) but not what `agy` resumes from.
Editing or omitting it does not affect resume correctness (proven — see
"What's proven" below).

## `step_payload` — the fields this codec reads and writes

Field numbers below are on the wire; nothing here is named by Google.

### Top level

| # | meaning |
|---|---|
| 1 | `step_type` (mirrors the `steps.step_type` column) |
| 4 | status |
| 5 | **envelope** — see below; identical to the `metadata` column |
| 19 | user-step content (present when `step_type == 14`) |
| 20 | assistant-step content (present when `step_type == 15`) |
| 114 | system-notice content (present when `step_type == 101`) |

Tool-call steps (`step_type == 132`) carry their content in the **envelope's**
field 4, not a dedicated top-level field — see below.

### Envelope (field 5, and byte-identical to the `metadata` column)

| # | meaning |
|---|---|
| 1 | `Timestamp {1: seconds, 2: nanos}` |
| 3 | small role/status enum: `4`=user, `2`=assistant, `5`=system-notice |
| 4 | **tool call** (only on `step_type == 132` steps): `{1: call_id, 2: tool_name, 3: arguments_json (plaintext JSON string)}`. A separate nested block (unmapped field numbers, not needed for reading) carries the human-facing result in the clear — literal stdout for shell commands — and a top-level field `7` on the step, when present, is a `file://…/steps/<idx>/output.txt` pointer for results too large to inline. |
| 12 | **round/invocation id** — a UUID shared by every step produced within one `agy` CLI invocation. *Not* a per-step id (two adjacent steps from the same invocation carry the same value). |
| 20 | `SessionContext {1: session_uuid (constant per conversation), 2: step index (equals steps.idx, monotonic across the whole conversation), 3: invocation/round counter, 4: conversation_id}` |
| 26 | repeated lifecycle event `{1: {1: event code, 2: Timestamp}}` — codes observed but not fully mapped (`1, 2, 3, 8, 9`) |

### User content (field 19)

| # | meaning |
|---|---|
| 2 | prompt text, plain |
| 3 → 1 | prompt text again, wrapped (same value) |
| 4 | empty string in every probe so far — unmapped |
| 12 | a large agent-config/tool-permission snapshot, unrelated to conversation content. **Treated as an opaque template, never modeled**: `AntigravityTranscriptCodec` copies this sub-tree verbatim from a real captured step rather than attempting to understand it. |

### Assistant content (field 20)

| # | meaning |
|---|---|
| 1 | response text — **or the full reasoning trace** when a thinking-capable model (e.g. Claude Sonnet via Cursor's inference API) is in use |
| 8 | visible response text. Identical to field 1 in non-thinking sessions; contains only the final response (no reasoning) in thinking-model sessions. **Always prefer field 8** when decoding for display. |
| 14 → 2 → 1 | an opaque ~250-byte blob, assistant steps only. Very likely a Gemini encrypted thought-signature — genuinely opaque by design (server-encrypted), not merely undecoded wire format. Notably absent from user-step content, which is why synthesizing a user-role step (the write path) does not need to fabricate anything like it. |

### System-notice content (field 114)

A self-contained `{1: formatted string, 2: {title, flags, 10: body}, 4: {id, conversation_id, sender, flags, timestamp, body}}` — `agy` inserts these itself (observed after an idle/server reconnect mid-session). The reader extracts the body text and otherwise ignores the structure.

## What's proven vs. assumed

**Proven, against a real local `agy` install:**
- The blobs are unencrypted and decode cleanly.
- The `steps` table alone governs resume — a same-length text patch to an
  existing completed step changed what `agy` reported as its own prior reply,
  with no other file touched.
- A hand-built, from-scratch `step_type == 14` step, inserted as a *trailing*
  pending turn on a conversation `agy` itself had created, was picked up on
  the next `agy --conversation <id>` invocation and acted on as real user
  input.
- Tool-call steps decode the same way — plaintext tool name, arguments, and
  (for small results) the literal output.

**Assumed / not yet proven at the time this was written:**
- Whether a **wholly new** conversation — a `conversations/<uuid>.db` `agy`
  never created, at a UUID Flotilla chose — is sufficient on its own, or
  whether `agy` additionally expects a `conversation_summaries.db` row and/or
  a `brain/<uuid>/` directory before it will accept `--conversation <uuid>`.
  This is the one open question the write path's design depends on; see the
  "Bootstrapping a new conversation" note in `AntigravityTranscriptCodec.swift`
  for the current answer and how it was settled.

## Caveats (read before trusting this in a new context)

- **Undocumented and unversioned.** Google can change any of this on any
  release with no notice. There is no schema-fingerprint check here — a
  format change fails at read/decode time (tolerated: unknown step types are
  skipped) or, worse for the write path, at `agy`'s own resume time, which
  this codec cannot detect in advance.
- Verified against one `agy` build, on one machine, with a handful of manual
  probes. Not fuzzed, not tested across upgrades.
- This is an unofficial, reverse-engineered dependency on a closed-source
  tool Google has no obligation to keep working.
