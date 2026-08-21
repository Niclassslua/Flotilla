# Priority 3 — Agent Parity & Hook Expansion

### A. Codex CLI Native `notify` Hook Wiring
- **Context:** Claude Code uses native hook JSON files to report status transitions directly (`HookConfigurationWriter`). Codex CLI also supports a native `notify` hook mechanism, but Flotilla currently falls back to regex substring heuristics (`TerminalScreenHeuristic`) for Codex.
- **Action:** Mirror the `HookConfigurationWriter` & `HookEventReceiver` architecture for Codex CLI, configuring Codex's native notification dispatching on session launch.
- **Files:** `Packages/HooksKit/Sources/HooksKit/`, `Packages/AgentKit/Sources/AgentKit/`.

### B. Rich Unified Model Picker (EffortPicker-Style UX)
- **Context:** `ModelPickerView` is currently a standard macOS native `Picker` dropdown, contrasting with `EffortLevelPicker` which uses a custom capsule chip, meter graphics, and an informative popover card stack. The dropdown lacks rich context on model capabilities, context window sizes, strengths, or reasoning support.
- **Action:**
  - Build `AgentModelPicker` styled identically to `EffortLevelPicker` (capsule chip with brand badge/icon + chevron, opening a rich popover).
  - Enrich `AgentModelProfile` / `ModelCatalog` with descriptive metadata (summary, capability tags like *Flagship*, *Fast*, *Long Context*, context limits, and effort compatibility).
  - Include a rich model card stack in the popover displaying capability badges, descriptions, default indicators, search/filter for large provider lists (e.g., OpenCode), and a streamlined "Custom Model" entry.
  - Unify the composer chip strip (`[Project] [Agent] [Model] [Effort] [Isolation]`) into a consistent, keyboard-navigable design system.
- **Files:** `Flotilla/Components/ModelPickerView.swift` (or new `AgentModelPicker.swift`), `Flotilla/Components/EffortLevelPicker.swift`, `Packages/AgentKit/Sources/AgentKit/ModelCatalog.swift`, `Flotilla/Features/CreateSession/Designs/CommandBarDesign.swift`, `Flotilla/Features/CreateSession/Designs/LaunchpadDesign.swift`.

### C. Dynamic Model Catalog Refresh
- **Context:** `ModelCatalog` entries are static and go stale as providers ship new models.
- **Action:** Periodically refresh catalog metadata from provider docs/APIs where available, falling back to the bundled static catalog.
- **Files:** `Packages/AgentKit/Sources/AgentKit/ModelCatalog.swift`.
