import Foundation
import SessionKit

/// Pattern-matches raw terminal output to detect a session that needs the
/// user's attention. Deliberately simple (substring matching) — good
/// enough to catch common permission/confirmation prompt phrasing without
/// needing to understand any particular agent CLI's exact output format.
public struct SessionStatusHeuristic: Sendable {
    public init() {}

    private static let waitingPatterns = [
        "permission required", "permission requested", "requires permission",
        "allow this", "approve?", "(y/n)", "[y/n]", "yes/no",
        "waiting for input", "do you want to", "continue?"
    ]

    /// Returns the detected status for this chunk of output, or `nil` if
    /// nothing recognizable was found (most output says nothing about status).
    public func detectStatus(in text: String) -> SessionStatus? {
        let lowered = text.lowercased()
        for pattern in Self.waitingPatterns where lowered.contains(pattern) {
            return .waitingForInput
        }
        return nil
    }
}
