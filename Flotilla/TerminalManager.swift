import Foundation
import SessionKit
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

    func applyPreferences(fontSize: Double, optionAsMetaKey: Bool, scrollSensitivity: Double) {
        self.fontSize = fontSize
        self.optionAsMetaKey = optionAsMetaKey
        self.scrollSensitivity = scrollSensitivity
        for controller in controllers.values {
            controller.applyPreferences(
                fontSize: fontSize,
                optionAsMetaKey: optionAsMetaKey,
                scrollSensitivity: scrollSensitivity
            )
        }
    }

    func controller(
        for session: Session,
        process: PTYProcessProtocol,
        outputHandler: @escaping @MainActor @Sendable (Data) -> Void,
        inputHandler: @escaping @MainActor @Sendable () -> Void
    ) -> TerminalController {
        if let existing = controllers[session.id], existing.processID == process.id {
            return existing
        }
        let controller = TerminalController(
            sessionID: session.id,
            process: process,
            accessibilityIdentifier: "TerminalView-\(session.title)",
            initialScrollback: session.terminalScrollback,
            multilineNewlineSequence: multilineNewlineSequence(for: session.agent),
            outputHandler: outputHandler,
            inputHandler: inputHandler
        )
        controller.applyPreferences(
            fontSize: fontSize,
            optionAsMetaKey: optionAsMetaKey,
            scrollSensitivity: scrollSensitivity
        )
        controllers[session.id] = controller
        return controller
    }

    func removeController(for sessionID: UUID) {
        controllers[sessionID] = nil
    }

    func retainControllers(for sessionIDs: Set<UUID>) {
        controllers = controllers.filter { sessionIDs.contains($0.key) }
    }

    /// Matches Xirp's agent-specific multiline input profiles. Claude's
    /// terminal UI expects Escape+Return; Codex and Gemini accept a line feed.
    private func multilineNewlineSequence(for agent: AgentKind) -> Data {
        switch agent {
        case .claudeCode:
            Data([0x1B, 0x0D])
        case .codexCLI, .geminiCLI:
            Data([0x0A])
        }
    }
}
