<img width="4550" alt="flotilla" src="https://github.com/user-attachments/assets/4fad54ce-13ed-479d-93de-e467b7b3db56" />

<h3 align="center">A native macOS command center for your fleet of coding agents.</h3>

<p align="center">
Run Claude Code, Codex, Cursor Agent, OpenCode, and Antigravity side by side, each in its own worktree.<br/>
Hand a live conversation from one agent to another, review their diffs, and approve their requests from your iPhone.
</p>

<p align="center">
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-000?logo=apple&logoColor=white" />
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" />
  <img alt="SwiftUI" src="https://img.shields.io/badge/UI-native%20SwiftUI-0A84FF" />
  <img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-green" />
  <img alt="Status: beta" src="https://img.shields.io/badge/status-beta-orange" />
</p>

https://github.com/user-attachments/assets/2c9a99b6-196c-42f7-94f4-9de2aa107d46

## Companion beta

**[Join the Flotilla Companion beta on TestFlight](https://testflight.apple.com/join/mDaW89Bn)** for iPhone and iPad (iOS/iPadOS 26+). Install TestFlight, open the link on your device, and tap **Accept**.

To pair, open **Settings → iPhone Companion → Pair iPhone** in Flotilla on your Mac, then scan the QR code in the companion. Keep both devices reachable over LAN or Tailscale.

## Why Flotilla

- **Native, not Electron.** Flotilla is SwiftUI from top to bottom, with Liquid Glass, real macOS windows, the Dock and the menu bar. It is not a web view wrapped in a browser runtime.
- **The real CLIs, on the plans you already pay for.** Every agent runs as its own interactive CLI in a real terminal. No SDK sits in between and nothing extra is billed, and new CLI features work the day they ship.
- **Agents are interchangeable mid-task.** Hit a rate limit with Claude? Hand the live session to Codex. The transcript is transcoded into the other agent's native format, not summarized, so the conversation carries over intact.
- **A phone app that's actually native.** The iPhone companion is a real iOS app with Live Activities and Lock Screen controls. It pairs straight to your Mac over LAN or Tailscale with end-to-end encryption, so there is no account and no cloud relay.

## Features

### 🛰️ Run a fleet, not a terminal

- **Five agents, one launcher.** Start Claude Code, Codex CLI, Cursor Agent, OpenCode, or Antigravity from one New Session window, with a model and reasoning effort picker for each and an Act/Plan mode toggle.
- **Every session in its own worktree.** Sessions can get an isolated git worktree automatically, so parallel agents never step on the same checkout. Worktrees and branches get names that match the task.
- **Sessions that outlive the app.** Agents run inside tmux, so quitting or updating Flotilla doesn't kill them. Relaunch it and every terminal reattaches right where it was.
- **Watch the whole fleet or one agent.** Switch between a Mission Control grid (pick its columns × rows), a Kanban board, and a focused single-session view.
- **Names itself.** Apple Intelligence titles each session from its first prompt, so the sidebar reads like a to-do list instead of `session-7`.
- **Keyboard-first.** A command palette (⌘K) reaches every session, project, and action.

<table>
  <tr>
    <td width="50%"><img alt="Mission Control grid" src="docs/images/ui-vocabulary/grid-presentation.png" /><p align="center"><sub>Mission Control grid</sub></p></td>
    <td width="50%"><img alt="Kanban board" src="docs/images/ui-vocabulary/board-presentation.png" /><p align="center"><sub>Kanban board</sub></p></td>
  </tr>
</table>

### 🔔 Know exactly which agent needs you

- **Accurate status for every session.** Flotilla wires each provider's own lifecycle hooks and backs them up with a terminal-screen classifier. Each session shows a distinct status: *working*, *waiting for you*, *ready*, *finished*, or *crashed*. Status comes from real events, not idle-timeout guesses.
- **Attention everywhere you look.** Waiting sessions show up as native notifications, a Dock badge, and a menu bar item, so you can work in another app and still know when to come back.
- **See what the agent sees.** Screenshots an agent takes or views open in an inspector panel with zoom, so UI work is reviewable at a glance.

### 🔀 Hand off between agents

Move a running session to a different agent without losing the thread. Flotilla reads the source agent's native transcript, converts it to a neutral model, and writes it back out in the destination's own format. The new agent resumes what it believes is its own prior session. The worktree, board position, and history all stay put, and the handoff finishes in under a second. No model call is involved. → [How handoff works](docs/session-handoff.md)

### 🔍 Review, then ship

- **A real review window.** Read an agent's changes in a file-by-file diff and leave line or file comments. Then send the review back to the same agent, or start a fresh agent (of any provider) to address it.
- **CI that talks back.** GitHub Actions checks show up on each session's branch. When one fails, send the failure straight to the agent that caused it.
- **Git, visualized.** Every project gets a commit graph (DAG), history browser, commit details, and a live diff panel.
- **Know which agent wrote what.** Commit attribution records the agent, model, and prompt behind each commit. It is stored on your Mac by default, or shared in the repo if you choose. Commits from agent sessions you haven't seen yet are flagged.

<table>
  <tr>
    <td width="50%"><img alt="Diff panel" src="docs/images/ui-vocabulary/diff-panel.png" /><p align="center"><sub>Diff panel</sub></p></td>
    <td width="50%"><img alt="Commit graph" src="docs/images/ui-vocabulary/commit-graph.png" /><p align="center"><sub>Commit graph</sub></p></td>
  </tr>
</table>

### 🗂️ A workspace for every project

- **Home dashboard.** A customizable widget grid with a commit heatmap, codebase growth, activity stats, and your projects with their custom icons and accent colors.
- **Files and editing.** A file browser with VS Code Material icons and a Monaco-powered editor with Markdown preview and ⌘S save.
- **Instructions in one place.** Browse and edit every agent's rules and skills (`CLAUDE.md`, `AGENTS.md`, `GEMINI.md`, `.cursorrules`, `SKILL.md`, and more) from a single Instructions view.

<table>
  <tr>
    <td width="50%"><img alt="Home dashboard" src="docs/images/ui-vocabulary/shell-home-dashboard.png" /><p align="center"><sub>Home dashboard</sub></p></td>
    <td width="50%"><img alt="Command palette" src="docs/images/ui-vocabulary/command-palette.png" /><p align="center"><sub>Command palette</sub></p></td>
  </tr>
</table>

### 📱 Your fleet, in your pocket

The **Flotilla Companion** for iPhone is a remote control for the Flotilla running on your Mac. The Mac keeps the real terminals, and the phone does the rest:

- **Answer agents from anywhere.** Allow or deny permission requests, answer questions, and approve or revise plans for every agent.
- **Watch without opening the app.** A Fleet Radar Live Activity in the Dynamic Island and on the Lock Screen shows which sessions are working and which are waiting.
- **Full control.** Create, prompt, stop, restart, hand off, and delete sessions. Read transcripts, diffs, commits, and files.
- **Private by design.** It pairs once over LAN or Tailscale and uses an end-to-end encrypted link that the Mac app hosts itself. There are no accounts and no third-party servers. → [Companion docs](docs/companion.md)

<p align="center">
  <img width="23%" alt="Companion fleet" src="docs/images/ui-vocabulary/companion-fleet.png" />
  <img width="23%" alt="Permission card" src="docs/images/ui-vocabulary/companion-permission-card.png" />
  <img width="23%" alt="Plan card" src="docs/images/ui-vocabulary/companion-plan-card.png" />
  <img width="23%" alt="Diff on iPhone" src="docs/images/ui-vocabulary/companion-diff.png" />
</p>

## Supported agents

| Agent | Status hooks | Handoff from | Handoff to | iPhone approvals |
|-------|:-:|:-:|:-:|:-:|
| Claude Code | ✓ | ✓ | ✓ | ✓ |
| Codex CLI | ✓ | ✓ | ✓ | ✓ |
| Cursor Agent | ✓ | ✓ | ✓ | ✓ |
| Antigravity | ✓ | ✓ | ✓ | ✓ |
| OpenCode | ✓ | — | ✓ | ✓ |

Flotilla launches each CLI you already have installed and signed in, so it never needs your API keys.

## Requirements

- macOS 26.0+
- Xcode with Swift 6.0 toolchain
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Getting started

```bash
git clone <this-repo>
cd Flotilla
xcodegen generate
make run
```

| Command | Purpose |
|---------|---------|
| `make build` | Debug build via xcodebuild |
| `make run` | Build and launch the app |
| `make test` | Run unit tests |
| `make test-ui` | Run UI tests |
| `make build-companion` | Build the iOS companion for the simulator |
| `make run-companion-demo` | Run the companion on its fixture fleet (no Mac pairing needed) |
| `make clean` | Remove build artifacts |

See [`AGENTS.md`](AGENTS.md) for the full architecture reference, package layout, and build/test conventions.

## Project structure

Flotilla is a SwiftUI app backed by 11 local Swift packages (`Packages/`) split along protocol boundaries — `SessionKit`, `GitKit`, `PersistenceKit`, `TerminalKit`, `AgentKit`, `HooksKit`, `TranscriptKit`, `CompanionKit`, `DesignSystem`, `SettingsKit`, and `ProcessKit`. The iOS companion (`FlotillaCompanion`) shares several of these with the Mac app. See [`AGENTS.md`](AGENTS.md#project-structure) for the full breakdown.

## Documentation

| File | Covers |
|------|--------|
| [`docs/ui-vocabulary.md`](docs/ui-vocabulary.md) | Canonical names for every UI region and component, with screenshots |
| [`docs/companion.md`](docs/companion.md) | iPhone companion architecture, pairing handshake, and protocol |
| [`docs/session-handoff.md`](docs/session-handoff.md) | How a live session moves between agents |
| [`docs/provider-hooks.md`](docs/provider-hooks.md) | Per-provider hook wiring and status-transition matrix |
| [`docs/testing.md`](docs/testing.md) | Testing policy |

## Status

Flotilla is early (v0.1.0, beta) and built primarily for its own author's workflow. Expect rough edges.

## License

[MIT](LICENSE)

The Claude, Codex, Cursor, OpenCode, and Antigravity logos are trademarks of their respective owners. They are included only to identify each provider and are not covered by the MIT license.
