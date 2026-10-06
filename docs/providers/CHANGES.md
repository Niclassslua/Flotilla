# Provider compatibility changes

Record one entry per provider update that changes a verified integration
surface. Provider reference pages state the exact version they are valid
through; captured fixtures remain alongside their provider.

## OpenCode

### 1.18.34 — 2026-10-06

- Replaced project plugin installation and default-port discovery with a
  global env-gated plugin and `opencode session list --format json`.
- Added turn, retry, error, dialog, compaction, and session identity events;
  confirmed `question.asked` live.
- Used the private server's `/session/status` and TUI append/submit endpoints
  for status recovery and companion prompt delivery.
- Added OpenCode transcript export and source deletion to the handoff flow.
- Updated the OpenCode reference and added versioned hook fixtures.
