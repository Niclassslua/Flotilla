# Context Sharing — Outside Verdict

> Review of [`context-sharing.md`](context-sharing.md), written 2026-08-21.
>
> This document evaluates the concept from product, UX, reliability, security, and implementation perspectives. It does not replace the original proposal. Its purpose is to define what must change before implementation.

## Executive verdict

Context sharing should exist in Flotilla. It addresses a real, high-value problem and could become one of the app's defining capabilities.

The current proposal is ready for a focused prototype and dogfood phase, but it is not ready for implementation of the complete A–H plan or for invisible automatic use in production.

The concept is strongest where it addresses storage integrity and failure recovery. It is weakest where it defines the user-facing promise, the authority of historical context, and the mechanics of safely interacting with live external agents.

The central recommendation is:

> Build exact session continuity first. Build general project memory after exact continuation is proven trustworthy.

### Concept health

| Dimension | Assessment |
|---|---:|
| Strategic value | 9/10 |
| Reliability thinking | 8/10 |
| Architectural readiness | 5/10 |
| User trust contract | 4/10 |
| Ready for a narrow dogfood prototype | Yes |
| Ready for automatic production use | No |

The lower readiness scores do not mean the idea is weak. They mean the most dangerous behavior—selecting and injecting historical context—is currently the least specified part.

## What is already strong

Several parts of the proposal are unusually thoughtful and should be preserved:

- It targets Flotilla's core job: preserving momentum across sessions, agents, and time.
- It correctly treats silent capture failure as unacceptable.
- The two-tier idea—machine-observed structural evidence plus richer agent-authored context—is directionally correct.
- Human-readable storage, atomic file writes, a rebuildable derived index, bounded launch context, and fixture-driven integration tests are all strong instincts.
- The proposal already considers concurrent sessions, secret leakage, bad snapshots, index drift, context budgets, crashes, quota exhaustion, and user correction.
- Provider-neutral product behavior is the right goal.
- Avoiding a vector database fits Flotilla's local and compact architecture.

Spotify's public Xirp material validates the desired outcome: context can carry between agents without binding work to one harness. It does not disclose an implementation that Flotilla can directly reproduce, so Flotilla still needs its own explicit trust and lifecycle model.

## The product promise should be narrower

The first release should make this promise:

> When I continue an existing thread with another agent—or return to it later—Flotilla carries enough verifiable state forward that the next agent can resume without re-briefing, while showing me exactly what it received.

This is narrower and more trustworthy than “Flotilla remembers the project.”

The immediate user problem is normally continuation of a particular task, branch, worktree, or session lineage. General retrieval across everything ever done in a project is useful later, but it is a different and much less deterministic problem.

## Recommended user mental model

The current proposal mixes `context`, `memory`, `knowledge`, `rules`, `snapshot`, `checkpoint`, and `handoff`. These objects have different authority and lifecycles and should not appear interchangeable.

| Concept | Meaning | Authority and lifecycle |
|---|---|---|
| **Rules** | Durable project instructions about how agents should work | Authoritative; current project state |
| **Handoff** | State captured from one source session | Historical evidence; must be verified |
| **Project Memory** | Browsable collection of handoffs | Mixed historical evidence |
| **Launch Context** | Exact bundle selected and delivered to a new session | Per-launch; visible and recorded |

`Track 1`, `Track 2`, `checkpoint`, ranking, and indexing should remain implementation language. Most users should encounter only **Handoff** and **Context**.

### Trust hierarchy

Every field should preserve its provenance:

1. **Live fact** — re-observed at launch, such as the current branch, commit, or file existence.
2. **Observed history** — Flotilla observed a diff, status, exit code, or file change during the source session.
3. **Agent report** — the outgoing agent claimed a decision, discovery, or next step.
4. **User amendment** — the user explicitly corrected or added information.

The receiving agent must be able to distinguish these categories. An old agent's claim must never be presented as a current repository fact or as an authoritative Rule.

## Priority blockers

### P0 — Historical memory is being elevated to Rules authority

The proposal intends to deliver agent-authored summaries, terminal-derived content, and machine-observed state through the same channel as project Rules.

This is unsafe even if the transport is technically convenient:

- Agent summaries can be wrong or stale.
- Terminal or repository content can contain prompt-injection text.
- A receiving model is less likely to question content Flotilla presents alongside authoritative instructions.
- “Rely on the receiving agent's judgement” is not a sufficient trust boundary when Flotilla selected and delivered the content.

There is also no uniform Rules injection pipeline in the current app:

- `Flotilla/Features/Projects/ProjectRulesView.swift` browses and edits conventionally named files. It does not assemble or inject them.
- `Packages/AgentKit/Sources/AgentKit/AgentKit.swift` currently passes the session goal using each provider's prompt argument.
- `Flotilla/Features/Settings/SettingsView.swift` currently tells users that Flotilla sends the goal unchanged and does not prepend instructions.

#### Required change

- Introduce a dedicated `LaunchContextEnvelope`.
- Deliver historical context separately from Rules, even if both ultimately travel through a prompt.
- Frame the envelope as untrusted historical evidence.
- Explicitly state that the current user goal, current repository state, and project Rules override it.
- Persist a **context receipt** containing the exact envelope delivered to each session.
- Never reread and prepend all existing Rules; providers may already discover them independently.
- Treat changing the “goal unchanged” contract as a visible product change.

### P0 — Automatic checkpointing at `waitingForInput` is unsafe

`waitingForInput` currently includes permission prompts, yes/no questions, and interactive pickers. Automatically typing “checkpoint now” at that state could answer or corrupt the active prompt.

The separate `.ready` state more closely represents a completed turn with an available composer, but even sending a request there starts another agent turn, consumes quota, and changes the conversation.

Structured hooks are also currently Claude-only. The other providers fall back to screen heuristics. HooksKit is intentionally observational and should not become a PTY-control system.

The existing agent-switch lifecycle compounds the problem: `AppStore.moveSessionToAgent` changes the stored agent before calling restart, and restart terminates the existing process immediately. A checkpoint initiated downstream could lose the outgoing provider identity or arrive after the process has been destroyed.

#### Required change

- Do not automatically type checkpoint requests into live sessions in the MVP.
- Put orchestration in an app-level `MemoryCoordinator`, not HooksKit.
- Attempt rich checkpointing only through provider capabilities proven safe at `.ready`.
- Provide explicit **Create Handoff** and **Continue with another agent…** actions.
- Implement agent switching as a serialized transaction:
  1. Preserve outgoing session and provider identity.
  2. Finalize structural context.
  3. Optionally request a rich handoff with a short timeout.
  4. Let the user continue with structural-only context if enrichment fails.
  5. Terminate the outgoing process.
  6. Create or launch the target-agent session with the selected context.
- Deduplicate checkpoint triggers and reject stale results using per-session generations.

### P0 — The structural reliability floor currently promises too much

Flotilla does not currently observe provider-neutral semantic commands, tool calls, todo state, or agent plans.

Today:

- HooksKit emits session statuses.
- Screen monitoring classifies a small visible tail of the terminal.
- The PTY exposes raw bytes and timestamps, not semantic agent actions.
- Raw TUI output is not equivalent to command history.
- Structured hooks cover Claude only.
- Output persistence currently depends on terminal-controller consumption, although the process broadcaster keeps a capped replay buffer.
- Multiple sessions sharing a main checkout make changed-file attribution fundamentally ambiguous.

#### Honest provider-neutral structural floor

The MVP can reliably capture:

- Original goal
- Source session and provider
- Start, checkpoint, and finish timestamps
- Working directory
- Project, worktree, and branch identity
- Baseline and current commit
- Changed filenames and aggregate diff statistics
- Commits produced between baseline and checkpoint where attribution is possible
- Exit code and last observed status
- Whether capture is final, partial, or structural-only

Commands, tool calls, transcripts, plans, and todos should be capability-based enrichment provided by provider adapters. They must not be part of the universal guarantee.

### P0 — Agent-written canonical files bypass validation and redaction

The proposal says the agent writes into `.flotilla/memory/` and that Flotilla validates and redacts content “on write.” Those statements are incompatible.

If the agent writes the canonical file directly, the unredacted bytes have already reached disk before Flotilla can inspect them. They may also reach SQLite WAL files, backups, or Git history.

Direct agent writes also enable:

- Persistent prompt-injection memory
- Arbitrarily large or malformed snapshots
- Invalid identifiers and paths
- Symlink or path-traversal problems during index rebuild
- Tampering by any process or branch able to edit the checkout

#### Required change

- Only Flotilla writes canonical memory.
- Agent-authored enrichment must enter through a bounded staging or response protocol.
- Validate UTF-8, schema version, IDs, generation, maximum sizes, and path containment.
- Strip terminal control sequences and unsafe control characters.
- Redact before content reaches either canonical storage or the index.
- Treat regex secret detection as best effort, never as proof that content is safe to publish.
- Frame all agent-authored content as historical evidence, not executable instructions.

### P1 — Retrieval is solving search before solving continuity

“Always include the latest snapshot” is dangerous in an application centered on parallel worktrees. The newest session may be unrelated, abandoned, or based on a mutually exclusive branch.

Recency is not a correctness mechanism. Ignoring worktree and branch signals conflicts with Flotilla's worktree-isolation model.

#### Recommended retrieval order

For exact continuation:

1. Explicit source session lineage
2. Worktree and branch
3. Baseline and final commit
4. Compatibility with current live repository facts
5. User selection

For a genuinely new session:

1. Project scope
2. Branch/worktree compatibility
3. Goal, symbol, and changed-path overlap
4. Keyword relevance
5. Recency
6. Confidence threshold

If a vague goal has no confident match, Flotilla should say **No confident context selected**. It should not silently inject the latest unrelated handoff.

FTS5 can supplement structured signals later. It should not define the first-release mental model.

Additional ranking requirements if FTS5 is adopted:

- Deduplicate to the latest retrieval revision per source session.
- Safely construct `MATCH` queries from punctuation-heavy goals.
- Account for code paths, underscores, hyphens, and symbol names.
- Specify BM25 direction precisely: SQLite FTS5 `bm25()` treats lower/more negative values as better, so a naive time multiplier is easy to invert.
- Test abandoned decisions and conflicting concurrent branches.

### P1 — Repeated checkpoints will crowd out useful context

“Early and often” combined with timestamped immutable snapshots can make the top results consist entirely of near-identical checkpoints from one long session.

#### Required change

- Maintain one revisable current checkpoint per active source session.
- Finalize it into an immutable handoff when the session ends or switches.
- Historical intermediate revisions may be retained for diagnostics but should not compete as normal retrieval candidates.
- Preserve amendments and provenance rather than silently editing finalized history in place.

### P1 — Storage and project lifecycle contradict each other

The proposal alternates between repo-local `.flotilla/memory/` and a future optional repo-storage mode.

Repo-local default storage would:

- Dirty the repository and every affected worktree
- Exist independently across worktrees
- Pollute Git diff and changed-file capture
- Turn expiry into repository deletions
- Risk accidental team sharing before review
- Make project unregistration destructive to user-owned files

The current `AppStore.removeProject` behavior is library unregistration and retains associated sessions as standalone sessions. Automatically deleting memory on unregister conflicts with that contract.

#### Recommended MVP storage

- Store canonical files under `Application Support/Flotilla/Memory/<local-project-key>/`.
- Use a stable repository identity capable of reassociation after unregister/reimport, not only the transient project UUID.
- Make **Forget Context** a separate explicit action.
- Do not delete memory merely because a project was unregistered.
- Keep Git/team sharing as a later explicit export/import/sync workflow.
- Do not describe team sharing as “zero architecture change”; storage, review, conflict, redaction, and retention semantics all change when content leaves one machine.

### P1 — Files and SQLite cannot be synchronously atomic together

Temp-file-then-rename protects an individual file. It does not create a transaction spanning the filesystem and SQLite.

Either side can succeed while the other fails.

#### Required change

- Use one `MemoryStore` actor as the only canonical writer.
- Keep indexing behind a separate `MemoryIndexing` protocol instead of expanding the existing session repository with unrelated responsibilities.
- Store content hashes and revisions in the index.
- Use one database transaction for metadata and FTS rows.
- Validate file existence and hash before injection.
- Record a dirty/reconciliation marker when file persistence succeeds but indexing fails.
- Rebuild automatically after database corruption or replacement, not merely through a manual debug action.

### P1 — CodexBar is unsuitable as a reliability foundation

CodexBar is useful optional telemetry, but its quota events are provider/account-level rather than session-level. With multiple active sessions on one provider, a quota warning cannot say which session should checkpoint. Checkpointing every session could consume the remaining quota exactly when it is scarce.

Its current CLI behavior also makes it too coarse for a last-moment guarantee:

- JSON usage is requested with `--format json`.
- `hooks watch` has a minimum 60-second interval.
- The first poll establishes a baseline and fires no transition event.
- Hook rules are explicit opt-in.

#### Required change

- Keep CodexBar out of the MVP.
- If added later, isolate it behind a `UsageTelemetryProvider` capability.
- Treat it as an early warning enhancement, never as the only capture trigger.
- Define a session-prioritization policy before reacting to provider-wide quota events.

## Provider-neutral does not mean zero provider adapters

The realistic architecture is:

- Provider-neutral domain models, storage, retrieval, UI, and launch envelope
- Capability-specific capture and checkpoint adapters per provider
- Graceful degradation when a provider lacks a capability
- A visible capability level for each captured handoff

Suggested capability levels:

| Level | Meaning |
|---|---|
| Structural | Git/session facts only |
| Rich checkpoint | Provider can safely produce a structured handoff |
| Transcript assisted | Provider-native local transcript can be bounded and parsed |
| Usage aware | Optional provider/account quota telemetry exists |

This is more honest and robust than treating screen scraping as an equivalent fallback.

## Recommended architecture shape

### Domain types

Use a provider-neutral memory domain, ideally behind a dedicated package or protocol boundary:

- `SessionHandoff`
- `HandoffProvenance`
- `StructuralEvidence`
- `AgentReportedContext`
- `UserAmendment`
- `LaunchContextEnvelope`
- `ContextReceipt`
- `ContextCapability`

### Services

- `MemoryCoordinator` — owns lifecycle orchestration and serialized per-session checkpoint generations.
- `MemoryStore` actor — sole canonical writer.
- `MemoryIndexing` — derived index and recovery.
- `StructuralCaptureService` — observes deterministic Git/session facts.
- `AgentContextAdapter` — optional provider-specific rich capture.
- `LaunchContextBuilder` — selects, validates, budgets, and renders the exact delivery envelope.
- `UsageTelemetryProvider` — optional future warning signals such as CodexBar.

### Minimum handoff metadata

```yaml
---
handoff_version: 1
id: <UUID>
project_key: <stable local repository identity>
source_session_id: <UUID>
source_agent: <agent kind>
capture_kind: structural | rich | mixed
status: current | final | partial | crashed
created_at: <timestamp>
updated_at: <timestamp>
working_directory: <path>
worktree_path: <path if applicable>
branch: <branch if applicable>
baseline_commit: <commit if available>
final_commit: <commit if available>
generation: <monotonic integer>
content_hash: <hash>
---
```

Each section within the body should identify whether it is a live fact, observed history, agent report, or user amendment.

## Recommended first release

Build the continuity feature first, not the general memory system.

1. Add **Continue with another agent…** to a session.
2. Capture deterministic structural context automatically.
3. Capture a rich handoff only when explicitly requested or supported by a proven-safe provider adapter.
4. Preserve a structural-only handoff on crash or enrichment failure.
5. Re-check branch, worktree, commits, and files immediately before launch.
6. Show a compact launcher control such as `Context: 1 handoff · Review`.
7. Let the user inspect and exclude sources before launch.
8. Deliver context separately from Rules, with provenance and untrusted-history framing.
9. Store the exact delivered envelope as the new session's context receipt.
10. Surface **Handoff saved**, **Structural only**, **Capture failed**, and **Context not delivered** states.
11. Default to Application Support storage with no repository mutation.
12. Provide exclude, amend, and explicit delete actions; do not silently expire finalized handoffs.

### Explicitly defer

- Automatic mid-turn PTY interruption
- Automatic “latest snapshot” injection
- CodexBar-triggered checkpointing
- Context-window screen heuristics as a reliability guarantee
- General FTS retrieval across unrelated sessions
- Provider-neutral command/tool capture claims
- Automatic pruning of finalized handoffs
- Git/team sharing
- Full in-place Markdown editing of finalized handoffs

## Required user flows

### Continue with another agent

1. User chooses **Continue with…** from the source session.
2. Flotilla immediately finalizes structural evidence.
3. If safe rich capture exists, Flotilla shows `Creating handoff…` with a short timeout.
4. On failure or timeout, Flotilla offers **Continue with structural context**.
5. The launcher shows the source session, branch, age, capture quality, and estimated size.
6. The user may inspect or exclude sections.
7. Flotilla revalidates live Git facts.
8. The target session launches with a delimited context envelope.
9. The target session retains a context receipt.

### Start an unrelated new session

1. User chooses project and enters a goal.
2. Flotilla may show confident context candidates.
3. Nothing is silently selected below the confidence threshold.
4. A vague goal with no exact lineage shows **No confident context selected**.
5. The user may deliberately choose an older handoff.

### Crash or quota exhaustion

1. Flotilla finalizes whatever deterministic structural evidence exists.
2. It labels the result **Structural only** or **Partial**.
3. It never implies that decisions or next steps were captured if they were not.
4. The next session can inspect and include the fallback explicitly.

## Failure states that need explicit product behavior

| State | Required behavior |
|---|---|
| No history | Start normally; show `No prior handoff` only where useful |
| Structural fallback only | Label it clearly; never present it as a complete summary |
| Capture failed | Preserve the session; explain the failure and offer retry/manual note |
| Low-confidence match | Do not inject silently; show likely candidates |
| Branch/worktree conflict | Warn and default to exclusion |
| Stale handoff | Show its age and changed live facts |
| Context budget exhausted | State which content was omitted |
| Provider rejected delivery | Show `Context not delivered`; offer copy/retry |
| Bad context already delivered | Exclude it from future launches and offer a correction message to the live session |
| Secret detected | Indicate that redaction occurred without revealing the secret |
| File/index drift | Reconcile automatically and surface recovery status if it affects launch |
| Project unregistered | Retain context unless the user separately chooses to forget it |
| User correction | Store an amendment/revision with provenance instead of silently rewriting history |

## Validation plan

The proposed fixture integration test is necessary, but it proves plumbing rather than usefulness. A perfectly functioning index that selects the wrong handoff is still a product failure.

### Gate 1 — Injection and consumption spike

Test a canary `LaunchContextEnvelope` against all four installed CLIs:

- The receiving agent identifies the canary.
- The original user goal remains clear and primary.
- Empty-goal launches have a deliberate, visible behavior.
- Unicode and large context remain intact.
- Embedded malicious instructions are treated as historical data.
- Actual provider discovery of Rules does not cause duplicated instructions.
- A request sent only at `.ready` is tested separately per provider.

Mid-turn interruption remains unsupported until proven safe for each provider.

### Gate 2 — Structural capture spike

Verify baseline and current Git state for:

- Isolated worktree sessions
- Main-checkout sessions
- Committed, staged, unstaged, and untracked changes
- Renamed and deleted files
- Rebase and branch changes
- Two concurrent sessions using one main checkout

Document the attribution ceiling rather than hiding it.

Produce a provider capability matrix covering structured hooks, transcript access, safe checkpoint output, tool events, and quota telemetry.

### Gate 3 — Retrieval spike

Build a realistic corpus containing:

- Exact continuations
- Synonymous goals
- Punctuation-heavy code identifiers
- Abandoned decisions
- Concurrent branches
- Rebased worktrees
- Vague goals
- Several checkpoints from one session
- Malicious or misleading snapshot text

Measure top-1 and top-3 selection quality. Define a confidence threshold before any automatic inclusion.

### Engineering tests

Add coverage for:

- Schema and parser size limits
- Malformed frontmatter and invalid UTF-8
- Symlink and path containment
- Redaction before both canonical and database writes
- Verification that raw test secrets never appear in either store
- File/index/delete fault injection and reconciliation
- Database corruption followed by automatic disk rebuild
- Concurrent same-session checkpoints completing out of order
- Concurrent different-session writes
- Latest-revision deduplication
- FTS punctuation escaping and time-decay direction if FTS is adopted
- Branch and worktree compatibility
- Context byte/token budgets and Unicode
- Empty-goal behavior
- Malicious-memory framing
- Ready, waiting-permission, crash, intentional restart, agent switch, and app-relaunch lifecycle states
- Provider launch-plan contracts for all four providers

Fixture tests must be supplemented by a non-CI manual smoke suite using the actual CLIs. Mocks cannot prove that real agents consume or interpret the context correctly.

## Quality bar before automatic injection

Automatic inclusion should not ship until all of the following are true:

- No silent capture or delivery failures.
- Exact continuation never selects an unrelated source session.
- Every included source is visible before launch during dogfooding.
- Structural context survives crashes, intentional switches, and app relaunch.
- All supported CLIs pass real context-envelope smoke tests.
- Branch/worktree conflicts default to safe exclusion.
- Context receipts reliably match the actual delivered envelope.
- A realistic corpus meets a predefined relevance target.
- Misleading-context incidents are measured and rare enough to justify automation.

Recommended product metrics:

- Re-briefing avoided
- Time to first meaningful action in the target session
- Context candidate acceptance/exclusion rate
- User amendment rate
- Structural-only fallback frequency
- Capture and delivery failure rate
- Misleading-context incidents
- Average delivered context size

Run a **shadow mode** first: capture and rank context, but show what would have been injected without silently injecting it. This validates selection quality without letting mistakes steer an agent.

## UX assessment

This score evaluates concept readiness, not the current Flotilla interface.

| # | Heuristic | Score | Main gap |
|---|---|---:|---|
| 1 | Visibility of system status | 1/4 | Capture and delivery states are not part of the core flow |
| 2 | Match with user mental model | 2/4 | Handoff is familiar, but Rules/Knowledge/Memory are conflated |
| 3 | User control and freedom | 2/4 | Edit/delete exists; launch-time exclude and correction are missing |
| 4 | Consistency and standards | 2/4 | Reusing Rules transport conflicts with the meaning of Rules |
| 5 | Error prevention | 1/4 | Wrong-thread and unsafe-checkpoint failures remain easy |
| 6 | Recognition rather than recall | 2/4 | History helps, but lineage and delivered sources are not surfaced |
| 7 | Flexibility and efficiency | 3/4 | Automation is efficient, but exact `Continue with…` is absent |
| 8 | Aesthetic and minimalist design | 2/4 | The core can be quiet; a general memory catalog risks overload |
| 9 | Error recovery | 2/4 | Structural fallback is good; already-delivered bad context is unresolved |
| 10 | Help and documentation | 1/4 | Provenance, privacy, and authority lack contextual explanation |
| **Total** |  | **18/40 — Poor** | Strong foundation; major UX contract work remains |

The score is deliberately strict because this feature can silently influence code changes. It does not mean the strategic idea is poor.

### Cognitive load

As currently described, 5 of 8 cognitive-load checks fail:

- Chunking fails because two capture tracks, six-section snapshots, ranking, editing, and debug information lack a simple user digest.
- Grouping fails because Rules, Knowledge, Memory, and Launch Context are not clearly separated.
- Visual hierarchy is unspecified at the key capture and launch moments.
- Users must remember which previous session or branch is relevant to judge opaque retrieval.
- Progressive disclosure begins with a debug inspector and full editing rather than a simple context receipt.

The desired default should be one compact line:

> `Context: Handoff from “Fix terminal resize” · Codex · branch/fix-resize · 2h ago · Review`

Everything deeper can be progressively disclosed.

### Persona red flags

#### Impatient power user

- Wants one-command exact continuation, not a memory catalog.
- Needs keyboard-first inspect/include/exclude controls.
- Will reject automatic checkpoint turns that add latency or consume quota.
- Prefers explicit source-session lineage over opaque keyword ranking.

#### First-time user

- May interpret “Flotilla remembers” as a stronger guarantee than the system can make.
- Cannot currently distinguish a live fact from an old agent's opinion.
- Needs confirmation that capture succeeded and context was actually delivered.
- Needs clear consequences for amend, exclude, forget, unregister, expiry, and Git sharing.

#### Stress tester

- Will find unrelated latest snapshots from concurrent worktrees.
- Will create conflicts between structural evidence and agent narration.
- Will test rebase, external edits, drift, malformed files, and index failure.
- Will find secrets missed by regexes.
- Will test corrections made after bad context has already been injected.

## Decisions required before rewriting the implementation plan

Recommended choices are shown first.

1. **Primary promise:** exact thread continuation, or broad automatic project memory?
   - Recommendation: exact continuation first.
2. **Default storage:** private Application Support, or repo-local Markdown?
   - Recommendation: private Application Support with later reviewed export/sync.
3. **Launch transparency:** context always visible and removable before launch, or eventual silent high-confidence injection?
   - Recommendation: always visible during MVP and shadow-mode dogfooding; revisit the default only after measurement.
4. **Rich checkpoint automation:** explicit/provider-capability-based, or generic invisible PTY automation?
   - Recommendation: explicit and capability-based until each provider is proven safe.
5. **History semantics:** amend finalized handoffs, or edit them in place?
   - Recommendation: amendments/revisions preserve provenance.
6. **Unregister behavior:** retain context, or automatically delete it?
   - Recommendation: retain it; provide a separate explicit **Forget Context** action.

## Final recommendation

Approve a narrow implementation spike and dogfood prototype centered on **Continue with another agent…**.

Do not begin the full A–H implementation from the original document unchanged. First revise the concept around:

- Exact lineage
- Separated authority
- Flotilla-owned storage
- Honest provider capabilities
- Safe checkpoint lifecycle
- Visible launch receipts
- Local-only default storage
- Measured usefulness before automation

If this narrower form works, the broader project-memory system becomes a credible second layer. If exact continuation is not reliable, adding FTS, quota telemetry, automatic pruning, and team sharing will only make an unreliable foundation more complicated.

## External references checked

- [Spotify: What we've learned scaling AI coding agents](https://portal.spotify.com/blog/introducing-xirp)
- [CodexBar CLI documentation](https://github.com/steipete/CodexBar/blob/main/docs/cli.md)
- [CodexBar external hook configuration](https://github.com/steipete/CodexBar/blob/main/docs/configuration.md)
- [Cline Memory Bank prompt](https://github.com/cline/prompts/blob/main/.clinerules/memory-bank.md)

