# Priority 4 — Settings, File Browser & Rules Polish

### A. Advanced Diagnostics & Reset
- **Context:** The "Advanced" tab in Settings currently displays static copy with no interactive diagnostic tools.
- **Action:** Add "Export Diagnostic Logs", "Clear Terminal Cache", and "Reset to Default Settings" buttons.
- **Files:** `Flotilla/SettingsView.swift`, `Packages/SettingsKit/Sources/SettingsKit/`.

### B. Persist Startup Warning Dismissals
- **Context:** If optional tools (like `tmux` or `gh`) are missing, the warning banner reappears on every launch even after dismissal, with no inline "Recheck" action.
- **Action:** Persist dismissed tool warning keys in `UserDefaults` / `AppSettings` and add an inline "Check Again" button to the banner.
- **Files:** `Flotilla/AppEnvironment.swift`, `Flotilla/ContentView.swift`.

### C. File Browser Enhancements
- **Context:** The file browser lacks filtering, file lifecycle operations (create/rename/delete), and debounced syntax highlighting on large files.
- **Action:**
  - Add a lightweight search/filter bar to the file tree.
  - Add context-menu actions for "New File", "Rename", and "Delete".
  - Debounce the regex syntax highlighting in `SyntaxHighlightedTextEditor`.
- **Files:** `Flotilla/FileBrowserView.swift`, `Flotilla/SyntaxHighlightedTextEditor.swift`.

### D. Appearance / Theme Cleanup
- **Context:** `AppearanceSettingsPane` is fully written and `AppSettings.appearance` is persisted, but the tab is commented out in Settings and the app forces dark mode.
- **Action:** Either complete and enable dynamic light/dark/system mode switching throughout all color tokens, or clean up the unused appearance settings code.
- **Files:** `Flotilla/SettingsView.swift`, `Packages/SettingsKit/Sources/SettingsKit/AppSettings.swift`, `Packages/DesignSystem/Sources/DesignSystem/FlotillaPalette.swift`.
