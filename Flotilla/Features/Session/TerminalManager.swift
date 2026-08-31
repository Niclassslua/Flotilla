import Foundation
import SessionKit
import AgentKit
import ProcessKit
import TerminalKit

/// Caches one `TerminalController` per session, keyed by session id, for the
/// life of the app. Each controller owns the process stream and stable
/// presentation-specific renderers, so sidebar and grid transitions preserve
/// terminal state without moving one measured NSView between containers.
@MainActor
final class TerminalManager {
    private var controllers: [UUID: TerminalController] = [:]
    private var fontSize = 14.0
    private var optionAsMetaKey = true
    private var scrollSensitivity = 1.0
    private var gpuRendering = false

    func applyPreferences(
        fontSize: Double,
        optionAsMetaKey: Bool,
        scrollSensitivity: Double,
        gpuRendering: Bool = false
    ) {
        self.fontSize = fontSize
        self.optionAsMetaKey = optionAsMetaKey
        self.scrollSensitivity = scrollSensitivity
        self.gpuRendering = gpuRendering
        for controller in controllers.values {
            controller.applyPreferences(
                fontSize: fontSize,
                optionAsMetaKey: optionAsMetaKey,
                scrollSensitivity: scrollSensitivity,
                gpuRendering: gpuRendering
            )
        }
    }

    /// `scrollback` is passed in rather than read from `session.terminalScrollback`
    /// because live terminal output is kept off the observed `Session` struct
    /// (see `AppStore.scrollback(for:)`) — only the persisted snapshot lives there.
    /// Whether a session already has a warm controller. Only used by the
    /// performance probes, to tell "this view mounted a cached renderer" apart
    /// from "this view paid for a fresh emulator plus a scrollback replay".
    func hasController(for sessionID: UUID) -> Bool {
        controllers[sessionID] != nil
    }

    func controller(
        for session: Session,
        process: PTYProcessProtocol,
        scrollback: Data,
        customReflowHandler: (@MainActor @Sendable (TerminalPresentation) -> Void)? = nil,
        onPTYResize: (@MainActor @Sendable (PTYSize) -> Void)? = nil,
        outputHandler: @escaping @MainActor @Sendable (Data) -> Void,
        inputHandler: @escaping @MainActor @Sendable () -> Void
    ) -> TerminalController {
        if let existing = controllers[session.id] {
            // The cached controller outlives the view that created it, and the
            // focused session view and a grid tile ask for the same one. Adopt
            // the caller's closures rather than silently keeping whichever
            // mount happened to be first — and follow renames, so the
            // accessibility identifier UI tests look terminals up by does not
            // stay pinned to the session's original title.
            existing.updateHandlers(
                accessibilityIdentifier: "TerminalView-\(session.title)",
                customReflowHandler: customReflowHandler,
                onPTYResize: onPTYResize,
                outputHandler: outputHandler,
                inputHandler: inputHandler
            )
            if existing.processID != process.id {
                existing.rebind(process: process)
            }
            return existing
        }
        PerfLog.event("TerminalManager: creating controller for \(session.title) (scrollback \(scrollback.count)B)")
        let controller = TerminalController(
            sessionID: session.id,
            process: process,
            accessibilityIdentifier: "TerminalView-\(session.title)",
            initialScrollback: scrollback,
            multilineNewlineSequence: multilineNewlineSequence(for: session.agent),
            customReflowHandler: customReflowHandler,
            onPTYResize: onPTYResize,
            outputHandler: outputHandler,
            inputHandler: inputHandler
        )
        controller.applyPreferences(
            fontSize: fontSize,
            optionAsMetaKey: optionAsMetaKey,
            scrollSensitivity: scrollSensitivity,
            gpuRendering: gpuRendering
        )
        controllers[session.id] = controller
        return controller
    }

    /// The screen a session's renderer currently shows, or `nil` when that
    /// session has no controller yet (its terminal has never been opened).
    func screenText(for sessionID: UUID) -> String? {
        controllers[sessionID]?.visibleScreenText()
    }

    func removeController(for sessionID: UUID) {
        controllers[sessionID] = nil
    }

    func retainControllers(for sessionIDs: Set<UUID>) {
        controllers = controllers.filter { sessionIDs.contains($0.key) }
    }

    /// Matches Xirp's agent-specific multiline input profiles. Claude's
    /// terminal UI expects Escape+Return; Codex and OpenCode accept a line feed.
    private func multilineNewlineSequence(for agent: AgentKind) -> Data {
        AgentCatalog.descriptor(for: agent).multilineNewline
    }
}
