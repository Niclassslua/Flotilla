<img width="4550" alt="flotilla" src="https://github.com/user-attachments/assets/65b3544b-569c-4358-8b08-0dd3f5fb1026" />

## Features

- **Multi-agent sessions** — launch and run Claude Code, Codex CLI, OpenCode, and Antigravity sessions side by side, each in its own terminal.
- **Git worktree management** — sessions can run in isolated worktrees automatically, so parallel agents never collide on the same checkout.
- **Session handoff** — move a running session to another agent mid-conversation; its transcript is transcoded, not summarized, so the destination resumes what it takes to be its own prior session.
- **Mission Control grid, Kanban board, and focus views** — four switchable layouts for watching a fleet of sessions at once or diving into one.
- **Git visualizer** — commit graph, diff panel, and history browsing per project.
- **iPhone companion** — an end-to-end encrypted remote control for a running Flotilla, paired over LAN or Tailscale. See [`docs/companion.md`](docs/companion.md).
- **Hooks** — per-provider hook wiring drives status transitions and notifications as agents move through their lifecycle.

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
