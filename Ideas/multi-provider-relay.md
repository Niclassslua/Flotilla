# Priority 0b (Future) — Multi-Provider Task Relay

## Dependency

Builds directly on [Cross-Agent & Cross-Session Context Sharing](context-sharing.md) — specifically its snapshot mechanism and CodexBar telemetry integration. Do not start this before that mechanism is reliable; relay is only as good as the checkpoint it hands off.

## Idea

Beyond checkpointing a single session before it runs out of quota, proactively route work to whichever provider currently has headroom. If OpenCodeGo is at 99% quota and Codex has 497 credits remaining at 29% usage, start the continuation on Codex rather than waiting for OpenCodeGo to fail.

## Why this is a separate idea, not part of context-sharing

Context-sharing answers "how do we not lose state." Relay answers "which provider should do the next unit of work," which is a genuinely different, harder problem:

- **Provider-routing heuristics** — headroom isn't the only variable; different providers/models produce different code style and quality mid-refactor. Switching providers because of quota, not task fit, is a real regression risk that needs a policy, not just a threshold.
- **Cost awareness** — some providers are pay-per-credit; auto-routing has budget implications a human should probably approve, at least initially.
- **Explainability** — if Flotilla silently moves a task to a different provider, the user needs to see why (which UI, what triggered it) or this becomes confusing rather than helpful.
- **Per-window nuance** — a provider can be safe on one usage window and critical on another simultaneously (e.g. fine on the 5-hour window, exhausted on the weekly one); routing logic needs both, not a single collapsed percentage.

## Sketch (not yet a committed design)

- Read CodexBar's per-provider, per-window `usedPercent`/`pace` data (see [context-sharing.md](context-sharing.md#telemetry-source-codexbar-optional-dependency)) to build a live headroom picture across configured providers.
- Surface headroom in the UI wherever agent/model is selected, so relay starts as a human decision aid before it's ever an automatic one.
- Only after that's proven useful, consider an opt-in automatic mode: proactively launch a successor session on a higher-headroom provider, seeded with the outgoing session's latest snapshot, when the active provider crosses its critical threshold — with the outgoing session's status made obvious in the UI (e.g. "handed off to Codex," not a silent disappearance).

## Open questions

- Does switching providers mid-task produce acceptable continuity in code style/approach, or does every relay need a human review checkpoint before continuing?
- Should relay ever be fully automatic, or should it always require a one-click confirmation given the cost/quality risk?
