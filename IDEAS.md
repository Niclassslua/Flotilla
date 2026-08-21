# Flotilla — Feature & Improvement Ideas Roadmap

> Index of research findings, recent implementations, and prioritized ideas for Flotilla. Full detail lives in [`Ideas/`](Ideas/).

- [Completed Milestones](Ideas/completed.md) — status check of previously identified work that has since shipped.
- [Priority 0 — Cross-Agent & Cross-Session Context Sharing](Ideas/context-sharing.md) — session memory that survives agent switches and time, inspired by Spotify's Xirp; markdown snapshots + SQLite FTS5 retrieval + Rules-channel injection, with a two-track capture design (plus optional CodexBar quota telemetry) so a quota/crash mid-session can't silently lose context.
- [Priority 0b (Future) — Multi-Provider Task Relay](Ideas/multi-provider-relay.md) — proactively route work to whichever agent provider has quota headroom; depends on context sharing being solid first.
- [Priority 1 — High-Leverage Quick Wins & Bug Fixes](Ideas/quick-wins.md) — inline diff hunks, markdown editing, dead code, Kanban actions, session form consolidation.
- [Priority 2 — Multi-Session Orchestration & Fleet Control](Ideas/orchestration.md) — batch selection/actions, live board previews, adaptive polling, Focus mode.
- [Priority 3 — Agent Parity & Hook Expansion](Ideas/agent-parity.md) — Codex native hooks, rich model picker, dynamic model catalog.
- [Priority 4 — Settings, File Browser & Rules Polish](Ideas/polish.md) — diagnostics, warning persistence, file browser lifecycle ops, theme cleanup.
