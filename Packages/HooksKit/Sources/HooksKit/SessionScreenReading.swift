import Foundation

/// Supplies the text currently drawn on a session's screen.
///
/// Read-only by construction, exactly like `SessionOutputObserving`: HooksKit
/// can look at what a session is showing but has no way to type into it or
/// stop it. The app layer decides *how* the screen is obtained — from the
/// live terminal renderer when one exists, or from tmux for a session whose
/// terminal has never been opened.
public protocol SessionScreenReading: Sendable {
    /// The session's visible screen, or `nil` when it cannot be read right
    /// now. `nil` means "no information", never "empty screen" — callers
    /// must leave the status alone rather than guessing from an absence.
    func readScreen(for sessionID: UUID) async -> String?
}
