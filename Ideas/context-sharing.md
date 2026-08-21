# Priority 0 — Cross-Agent & Cross-Session Context Sharing

## Motivation

Every Flotilla session currently starts cold. Switching agents mid-task (Claude Code → Codex), or simply starting a new session on a project you worked on last week, means re-explaining state the previous session already worked out. This is the single biggest capability gap relative to where multi-agent orchestration tools are heading — Spotify's [Xirp](https://xirp.spotify.com/) (a closed-source sibling of Flotilla: macOS, vendor-neutral, worktree-isolated sessions) makes this its headline feature, describing context that "decouples from any single agent or harness" and is "saved back" so the next session — human or agent — inherits it. Team-wide sharing is a longer-term extension of the same mechanism, not a separate feature.

## Prior art considered

No public source discloses Xirp's actual implementation — every account stops at outcome-level claims ("full working state carries over"). The useful references are open ones:

- **Cline's Memory Bank** — plain markdown files in the repo (`memory-bank/*.md`), read/written via a rules-file convention understood by any agent. No DB. Shareable via git for free. Weakness: whole files get dumped every time, so it bloats and goes stale.
- **This repo's own `handoff` skill** (`~/.claude/skills/handoff/SKILL.md`, mirrored across ~20 other agent CLIs) — a structured point-in-time snapshot: Goal, User Requirements, Current State, Important Discoveries, Decisions & Assumptions, Failed Approaches, Remaining Work, Next Action, References, Verification. Written by the outgoing agent, sanity-checked against real repo state by the incoming one before use.
- **OpenHands' Condenser** — not cross-agent sharing, but the right mental model for *when* to summarize: an explicit, triggered step (threshold detection → summary generation), not something left to an agent's discretion.
- **Letta (MemGPT)** — a full stateful-agent runtime with tiered memory (Core / Recall / Archival) backed by Postgres + pgvector and semantic retrieval. Technically the most complete answer, but it's a memory *service an agent calls into* — the wrong shape for Flotilla, which orchestrates external CLI agents it doesn't control internally, and would add infrastructure (vector DB) Flotilla doesn't otherwise need.

## What we're taking from each

| From | Take | Leave |
|---|---|---|
| Cline Memory Bank | Durable, human-readable markdown living in the project; injection via the same rules channel every agent CLI already honors; git-committable → team sharing later is free. | Generic 4-file split; unbounded whole-file dumping. |
| `handoff` skill | The snapshot schema (Goal / Current State / Discoveries / Decisions / Remaining Work / Next Action); validate-before-trust discipline on the receiving end. | OS-temp-dir, delete-after-use lifecycle — wrong when the whole point is accumulation. |
| OpenHands Condenser | Snapshot generation as a deliberate, triggered step, not agent discretion. | Its live-context compression algorithms — irrelevant here; we're summarizing discrete sessions, not a running window. |
| Letta | Tiering: separate "always-inject" context from "searchable on demand" history. | Postgres + pgvector. `PersistenceKit` already wraps GRDB/SQLite — FTS5 gets keyword/BM25 relevance ranking at zero new infrastructure. |

## Design

1. **Storage** — per-project markdown snapshots using the `handoff` schema, in a Flotilla-managed directory (e.g. `.flotilla/memory/<project>/*.md`), sitting alongside the in-progress `Knowledge` module (`Flotilla/Features/Projects/Knowledge/`) rather than beside it as a separate system.
2. **Index** — mirror snapshot content into a new FTS5 virtual table via `PersistenceKit` (`Packages/PersistenceKit/Sources/PersistenceKit/Records.swift`, `GRDBSessionRepository.swift`), so "which past memory is relevant to this new session" is a keyword query, not a full-file read.
3. **Trigger** — generate a snapshot programmatically, not by agent discretion, at: session end, and explicit agent/model switch. Natural hook point is alongside the existing session-lifecycle notifications in `Flotilla/Services/SessionProcessManager.swift` and the status-transition plumbing in `Packages/HooksKit/Sources/HooksKit/`.
4. **Injection** — at new-session launch, query the FTS index for the top-N relevant entries for that project/goal and inject them through the same Rules mechanism already used to feed CLAUDE.md-equivalent instructions to every agent (`Flotilla/Features/Projects/ProjectRulesView.swift` / `Knowledge`) — uniform across Claude Code, Codex, and OpenCode with no per-agent integration work.
5. **Team sharing (future, explicitly out of scope for now)** — since the mechanism is files + an index, this reduces to "commit `.flotilla/memory/` to git" — no architecture change required to unlock later.

## Reliability: preventing silent context loss

The failure mode that breaks this design if left unaddressed: if snapshot-writing is "ask the agent to summarize as its last act," and the agent runs out of usage, hits a rate limit, or crashes before that last act, the session produces *nothing* — worse than not building the feature, since the system would be trusted at exactly the moment it silently fails. The mechanism has to assume the agent may never get a clean, well-resourced final turn.

**Two tracks, not one:**

- **Track 1 — structural, continuous, zero-LLM-cost.** Flotilla already observes session state via `HooksKit` / `SessionProcessManager` (screen heuristics, status transitions, diff stats). Continuously accumulate a bare structural record as the session runs — files touched, commands run, diff deltas, todo/plan state where the agent exposes one. This is Flotilla observing, not the agent reporting, so it cannot be starved by quota exhaustion. Worst case, this is all you get — but there is always something.
- **Track 2 — LLM-authored enrichment, requested early and often.** The rich `handoff`-schema snapshot (Goal / Decisions / Discoveries / Remaining Work) is higher quality but must be requested *before* the risk window, not only at a terminal step that may not arrive. Trigger it at multiple checkpoints: natural pause points already detected by the hook system (e.g. `waitingForInput`), and proactively when usage/context-limit signals surface on screen (rate-limit warnings, context-window-full indicators both Codex and Claude Code display) — "approaching the wall" is its own trigger, fired before the wall. If the agent dies mid-session, the worst case becomes "slightly stale last checkpoint," never "nothing."

**Crash / limit-exhaustion as an explicit trigger.** The instant `HooksKit` detects an error, rate-limit, or crash signal, that itself fires an immediate snapshot from whatever Track 1 data has accumulated — Flotilla does not wait for a clean exit that may never come.

### Telemetry source: CodexBar (optional dependency)

[steipete/CodexBar](https://github.com/steipete/CodexBar) (MIT, macOS 14+) reads Claude/Codex usage from local session logs — no login, no API calls, matching Flotilla's local-first posture. Two things from it are directly usable:

- `codexbar usage --json` reports per-provider `primary`/`secondary` (session/weekly) `usedPercent` plus a `pace` object (`stage`, `willLastToReset`, `etaSeconds`) — a real, verified schema, not guessed.
- `codexbar hooks watch --interval <seconds>` is an existing edge-triggered subscription (fires once per threshold crossing, not every poll) — Flotilla should register against this rather than building its own polling loop, the same way it already writes hook config for Claude Code (`HookConfigurationWriter`).

**This is a distinct trigger from context-window fill, not a replacement for it.** CodexBar's `usedPercent` measures rate-limit *quota* (the 5-hour/weekly allowance) — a session can be at 2% quota and still choke on an oversized conversation on its very first call, or sit at 99% quota with a short, healthy conversation. Track 2's "approaching the wall" trigger needs both signals independently: CodexBar for quota headroom, screen-heuristics/token-accounting for context-window fill. Treat "safe/warning/critical" zones per-window too (a provider can be fine on its 5-hour window and critical on its weekly one simultaneously) — collapsing them into one number misfires.

Since CodexBar is a third-party tool the user may not have installed, treat it the same way Flotilla already treats optional tools like `tmux`/`gh` (see [Priority 4.B](polish.md)) — an enhancement when present, with the existing screen-heuristic path as the fallback when it's not.

**Open questions, not yet validated — same spike:**
1. Whether a "checkpoint now" signal can actually be delivered mid-turn to a running agent (injected via the PTY) in time for it to act before quota/context runs out, and whether each of Claude Code/Codex/OpenCode even honors an interrupt-and-redirect like that.
2. Whether quota-exhaustion is reliably visible and parseable on-screen per provider — the assumption the CodexBar-fallback path depends on for providers CodexBar doesn't cover.

Both need a small spike against `SessionProcessManager`/`TerminalManager` before the design commits to either — Track 1's continuous structural capture is what makes the design safe even if both turn out not to work reliably.

**Verifying it actually works** splits into two different claims, checked differently:

1. *Was a snapshot written and is it well-formed?* — validate on write (frontmatter present, required sections present, non-empty). A failed validation falls back to the Track 1 structural record rather than persisting a corrupt or empty file that looks fine until read.
2. *Does retrieval surface the right thing later?* — this is the kind of behavior this project's testing conventions single out as worth a real test: easy to silently regress, hard to catch by eye. Cover the FTS5 ranking with unit tests over known query / expected-snapshot pairs (not a UI test — see `CLAUDE.md` testing scope). Pair this with a debug affordance in the Knowledge UI showing what was captured and what was injected for a given session, so a bad result is visible and explainable rather than a black box.

## Resolved decisions

Open questions worked through and decided:

| Question | Decision | Rationale |
|---|---|---|
| Two sessions on the same project finish near-simultaneously — merge, serialize, or keep both? | **Keep both, timestamp-ordered.** No merge logic. | Avoids the risk of an automatic merge silently producing a wrong combined narrative; recency-weighted retrieval (below) already prefers the newer one when they conflict. |
| Retrieval resurrecting a decision a later session abandoned | **Recency-weighted ranking only** — no explicit supersession links. | Works without relying on agent discipline to mark supersession correctly; revisit with explicit links only if recency weighting proves insufficient in practice. |
| Injected snapshots bloating a new session's opening context | **Fixed token/character budget**, include top-ranked entries until the budget is spent, drop the rest. | Bounds worst case without needing a second summarization pass. |
| Unbounded growth of `.flotilla/memory/` over months | **Time-based expiry.** Snapshots older than N months are archived/pruned automatically. | Bounded storage with no user effort required; N is a tunable, not fixed here. |
| Trusting agent-authored claims in a snapshot | **Rely on the receiving agent's judgement**, per the existing `handoff` skill norm — no new automated fact-checking machinery. | Automated verification of arbitrary claims is a much bigger and more speculative build; the existing validate-before-trust discipline is proven and cheap. |
| Reviewing/correcting a bad snapshot | **Full edit/delete UI in Knowledge**, not just the read-only debug inspector. | Snapshots are agent-authored and will sometimes be wrong; users need real control, not just visibility, from day one. |
| Secrets/proprietary content ending up in snapshots | **Basic secret-pattern redaction** on write (API keys, tokens, credential-shaped strings). | Catches the common case cheaply; matters now for local storage and becomes a hard prerequisite once git-tracked team sharing (item H) ships. |
| Memory scope across related/adjacent projects | **Strictly per-project.** No cross-project retrieval. | Matches how Rules/Knowledge already scope; predictable mental model; cross-project linking can be revisited later if monorepo usage demands it. |
| CodexBar's uneven provider coverage (Gemini, Antigravity, OpenCode vs. Claude/Codex) | **Graceful per-provider fallback** — CodexBar telemetry where available, screen-heuristics-only triggering elsewhere. | No provider is blocked from context-sharing; providers just get a less proactive trigger until/unless CodexBar (or another source) covers them. |
| Verifying the full pipeline, not just FTS ranking in isolation | **Scripted integration test**, fixture-driven, no live LLM calls — asserting capture → validate → index → retrieve → inject end-to-end. | Real coverage of the composed pipeline without the cost/flakiness of calling an actual agent in CI. |

### Second pass — gaps found on review

A closer look surfaced two items that didn't just need a decision but actually **contradicted** what was already decided, plus several real gaps the first pass missed:

| Question | Decision | Rationale |
|---|---|---|
| How does an agent actually write into `.flotilla/memory/` without inheriting the real `handoff` skill's delete-after-use behavior? | **New Flotilla-specific instruction**, distinct from the general-purpose `handoff` skill — same schema, targets `.flotilla/memory/`, never self-deletes. | Reusing the real skill unmodified would silently undo the accumulation model the moment the agent runs its own cleanup step. |
| The edit/delete UI needs the FTS index to stay in sync, but item B only specified insert-on-write | **Synchronous re-index on save/delete.** | Every edit/delete through the Knowledge UI updates the index in the same operation; negligible cost at this scale, no staleness window. |
| Markdown files (canonical) and the SQLite index (derived) can drift — crash mid-write, external edit, DB corruption | **Rebuild index from disk on demand**, runnable on launch or manually. | Files stay the real source of truth throughout; a corrupted/stale index is always recoverable by re-scanning `.flotilla/memory/*.md`. |
| Redaction (item E) was scoped to agent-authored snapshots only — Track 1's raw commands/diffs can contain secrets too | **Apply redaction to both tracks.** | A captured `export API_KEY=...` command is exactly as dangerous as an agent narrating a secret; the scan needs to run over Track 1's captured text as well. |
| A brand-new session's thin/vague goal can make keyword retrieval return nothing right when continuity matters most | **Always include the most recent snapshot as a floor**, then layer relevance-ranked results on top when the query is strong enough to produce them. | Prevents the feature from going silent exactly when a fresh session most needs it. |
| Injected memory shares the Rules channel with existing CLAUDE.md-equivalent content; the memory budget was sized in isolation | **Unified budget, Rules takes priority** — Rules content included first, memory fills whatever budget remains. | Never lets the new feature crowd out established project conventions. |
| What happens to `.flotilla/memory/` when a project is deleted/unregistered from Flotilla | **Delete memory with the project.** | Matches the expectation that unregistering a project cleans up its Flotilla-managed state; avoids an orphan problem outside the time-based expiry policy. |
| Whether quota-exhaustion is reliably visible/parseable on-screen per provider (the CodexBar-fallback path) | **Same validation spike, same caveat as the PTY-interrupt mechanism** — flagged as unverified, not assumed. | This is a sibling unverified assumption to the interrupt-delivery question; it shouldn't ship unflagged while its sibling is called out. |
| Recency-weighting had a direction but no formula | **Time-decay multiplier on the relevance score** (e.g. halving every N weeks), tunable. | Smooth blend where keyword match still matters but fades with age, rather than an all-or-nothing tiebreaker. |
| Whether retrieval should account for unrelated concurrent worktrees on the same project | **Project-level scope only — no worktree/branch signal.** | Relevance ranking alone should naturally deprioritize a worktree's snapshot on an unrelated goal; avoids adding a new ranking dimension and its edge cases. |
| Concurrent snapshot writes need to avoid file corruption | **Write-temp-then-rename** on every snapshot write. | Standard atomic-write pattern; guarantees no reader ever observes a partially-written file, compatible with the plain-markdown-file design as-is. |

## Phased work items

### A. Snapshot schema & storage
- **Action:** Define the on-disk snapshot format (reuse the `handoff` skill's section schema), and where it lives per project. Timestamp every snapshot so concurrent writes from separate sessions land as distinct, orderable entries rather than needing a merge step. Write with the temp-file-then-rename pattern so no reader ever observes a partial write. Deleting a project removes its `.flotilla/memory/` store.
- **Files:** new `Flotilla/Features/Projects/Knowledge/` addition, or a sibling `Flotilla/Features/Projects/Memory/` module.

### B. FTS5 index in PersistenceKit
- **Action:** Add a snapshot table + FTS5 virtual table, scoped strictly per-project, with a relevance-ranked query API using a time-decay multiplier over the base keyword score (not just a tiebreaker). Insert/update/delete kept in sync with the store synchronously on every write, edit, and delete. Add an on-demand rebuild routine that re-scans `.flotilla/memory/*.md` and repopulates the index, for recovery from drift or corruption. Time-based expiry job to archive/prune snapshots past a configurable age; deleting a project cascades to its index rows.
- **Files:** `Packages/PersistenceKit/Sources/PersistenceKit/Records.swift`, `Packages/PersistenceKit/Sources/PersistenceKit/GRDBSessionRepository.swift`.

### C. Track 1 — continuous structural capture
- **Action:** Accumulate a zero-LLM-cost structural record (files touched, commands run, diff deltas, todo/plan state) throughout the session lifecycle, independent of agent cooperation. This is the reliability floor everything else builds on. Runs through the same redaction pass as Track 2 (item E) before persisting, since captured command text can contain secrets just as easily as agent narration.
- **Files:** `Flotilla/Services/SessionProcessManager.swift`, `Packages/HooksKit/Sources/HooksKit/HooksKit.swift`, `Packages/HooksKit/Sources/HooksKit/SessionScreenMonitor.swift`.

### D. Track 2 — checkpointed LLM-authored enrichment
- **Action:** Define a Flotilla-specific instruction (distinct from the general-purpose `handoff` skill) that targets `.flotilla/memory/` and never self-deletes, using the same section schema. Wire it into multiple triggers: natural pause points (`waitingForInput`), proactive quota-approaching signals (via optional CodexBar `hooks watch` integration), proactive context-window-fill signals (screen-heuristics/token-accounting, independent of quota), session end, and agent/model switch — plus an immediate emergency trigger on crash/rate-limit/error detection, sourced from whatever Track 1 data exists at that moment. Requires a spike validating (a) whether a mid-turn "checkpoint now" signal is actually deliverable and honored per agent, and (b) whether quota-exhaustion is reliably visible/parseable on-screen per provider, before relying on either.
- **Files:** `Flotilla/Services/SessionProcessManager.swift`, `Packages/HooksKit/Sources/HooksKit/TerminalScreenHeuristic.swift`, `Packages/HooksKit/Sources/HooksKit/SessionStatusHeuristic.swift`.

### E. Write-time validation, redaction & fallback
- **Action:** Validate every snapshot on write (frontmatter present, required sections present, non-empty); on failure, fall back to the Track 1 structural record instead of persisting a corrupt/empty file. Run a basic secret-pattern redaction pass (API keys, tokens, credential-shaped strings) before persisting or indexing, applied to both Track 1 and Track 2 content — required before item H can ship, valuable even while memory stays local.
- **Files:** new validation/redaction pass alongside A's storage module.

### F. Relevant-context injection on session launch
- **Action:** Query top-N relevant snapshots (per-project only, recency-weighted) at session creation; if the new session's goal text is too thin to produce a meaningful match, always include the most recent snapshot as a floor. Fill a token/character budget in rank order and drop whatever doesn't fit, where that budget is unified with (and subordinate to) existing Rules content — Rules fill first, memory fills whatever remains — then surface the combined result through the Rules injection path.
- **Files:** `Flotilla/CreateSessionView.swift`, `Flotilla/Features/Projects/ProjectRulesView.swift`.

### G. Retrieval correctness tests, debug inspector & edit/delete UI
- **Action:** Unit tests over FTS5 ranking with known query/expected-snapshot pairs (per this repo's testing conventions — regressions here are easy to introduce and hard to eyeball), plus a scripted fixture-driven integration test covering the full capture → validate → index → retrieve → inject pipeline with no live LLM calls. Add a debug affordance in the Knowledge UI showing what was captured and what was injected for a given session, and full edit/delete controls (synchronously re-indexing per B) so a wrong snapshot can be corrected or removed, not just observed.
- **Files:** `FlotillaUnitTests/`, `Flotilla/Features/Projects/Knowledge/`.

### H. (Future) Git-tracked team sharing
- **Action:** Optional setting to keep `.flotilla/memory/` inside the tracked repo instead of app-support storage, so it travels with `git pull`/`git push` like any other project file. Depends on item E's redaction pass being solid first — this is what turns "local scratch state" into "content that leaves the machine."
- **Files:** TBD — depends on A.
