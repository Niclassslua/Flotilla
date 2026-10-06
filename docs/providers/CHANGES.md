# Provider compatibility changes

Record one entry per provider update that changes a verified integration
surface. Provider reference pages state the exact version they are valid
through; captured fixtures remain alongside their provider.

Upstream release notes to check on each version bump:

- Claude Code: [CHANGELOG.md](https://github.com/anthropics/claude-code/blob/main/CHANGELOG.md)
- Codex CLI: [GitHub releases](https://github.com/openai/codex/releases)
- OpenCode: [GitHub releases](https://github.com/anomalyco/opencode/releases)
- Antigravity: `agy changelog`
- Cursor Agent: [Cursor changelog](https://cursor.com/changelog)

For every bump, capture the upstream notes and local snapshots, compare the
provider page's verified rows and fixtures, then add one dated entry below.

## Claude Code

### 2.1.291 — 2026-10-06

- Added turn-start, session identity, compact, subagent, failure, denial,
  notification, and completion hook coverage; observe-only hooks run async.
- Replaced most screen-derived status with hook observations while retaining
  trust and interrupt detection as screen fallbacks.
- Passed Flotilla's session title at launch and documented versioned fixtures.

## Antigravity

### 1.3.0 — 2026-10-06

- Installed env-gated hooks in the user config and added `PreInvocation` turn
  start and phone prompt injection.
- Captured `Stop.terminationReason`, confirmed the decision limitation, and
  retained screen reading for permission dialogs.
- Documented versioned CLI behavior and the global hook configuration.

## Cursor Agent

### 2026.10.01-e373342 — 2026-10-06

- Moved hooks to the user config, added failure/interrupt/session lifecycle
  handling, and used `stop.followup_message` for queued phone prompts.
- Added live session IDs and title discovery through `agent create-chat` and
  `agent ls`; screen parsing remains necessary for approval dialogs.
- Recorded the oversized handoff prompt spill fix and updated fixtures.

## Codex CLI

### 0.160.1 — 2026-10-06

- Register `UserPromptSubmit` and `Interrupt` hooks and map them to turn
  start and interruption status. Register additional lifecycle events for
  capture; their payload behavior remains marked unverified.
- Inspect the generated app-server protocol schema and record available
  status, thread, model, title, and plan APIs in the Codex reference.
- Subscribe to `thread/status/changed` independently of the phone companion,
  mapping work, approval, question, idle, and system-error states to the board.
- Replace launch-time SQLite/index discovery with cwd-filtered,
  cursor-paginated `thread/list`, retaining the old provider as a compatibility
  fallback when the private app-server is unavailable.
- Keep title synchronization and the pre-session `model/list` query as
  follow-up items because they need separate lifecycle and catalog decisions.

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
