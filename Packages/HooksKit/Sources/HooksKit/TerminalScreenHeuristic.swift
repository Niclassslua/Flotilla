import Foundation
import SessionKit

/// Reads a session's status off the screen the agent is actually drawing.
///
/// This replaces inferring status from output *volume*, which could never
/// work: a full-screen CLI writes constantly for reasons unrelated to
/// progress, so "bytes moved" made idle sessions look busy and repaints look
/// like work. What the agent draws, by contrast, is a direct statement of
/// what it is doing — every one of these CLIs puts an interrupt hint on
/// screen while it works and takes it away when it stops.
///
/// Being a function of the current screen rather than of events makes this a
/// level signal: the same screen always yields the same status, so a repaint
/// that redraws identical content cannot change anything.
public struct TerminalScreenHeuristic: Sendable {
    /// Only the bottom of the screen is consulted. Agent CLIs draw their
    /// status line, spinner, and composer there; everything above is the
    /// conversation transcript, which is arbitrary text that will sooner or
    /// later contain any word we look for — including "esc to interrupt",
    /// quoted back by an agent discussing this very file.
    public static let inspectedTailLines = 8

    /// Drawn only while the agent is busy, and removed the moment it stops.
    /// These are hints to the user about how to *stop* the work in progress,
    /// which is why they are such a dependable signal.
    private static let workingMarkers = [
        "esc to interrupt",
        "escape to interrupt",
        "ctrl+c to interrupt",
        "ctrl-c to interrupt",
        "ctrl+c to stop",
    ]

    /// Blocking questions. Checked before the working markers: some CLIs
    /// keep a spinner on screen underneath a permission prompt, and needing
    /// the user always outranks being busy.
    private static let waitingMarkers = [
        "do you want to",
        "do you trust",
        "permission required",
        "permission requested",
        "requires permission",
        "waiting for input",
        "press enter to continue",
        "(y/n)",
        "[y/n]",
        "yes/no",
        "allow this",
        "approve?",
    ]

    /// Markers indicating the process or agent exited.
    private static let finishedMarkers = [
        "agent exited",
        "pane is dead",
        "process finished",
    ]

    /// Composer/ready markers — indicate the agent is at a prompt with
    /// transcript history, meaning it finished its turn and awaits user input.
    private static let readyMarkers = [
        "❯",
        "> ",
        "› ",
    ]

    private let promptHeuristic: SessionStatusHeuristic

    public init(promptHeuristic: SessionStatusHeuristic = SessionStatusHeuristic()) {
        self.promptHeuristic = promptHeuristic
    }

    /// Classifies the screen. Always returns a status — a screen is a
    /// complete description of the session's state, so there is no "no
    /// opinion" case the way there was for a single chunk of output.
    public func status(forScreen screen: String) -> SessionStatus {
        let tail = Self.tail(of: screen)
        let lowered = tail.lowercased()

        if Self.waitingMarkers.contains(where: lowered.contains) { return .waitingForInput }
        if promptHeuristic.detectStatus(in: tail) == .waitingForInput { return .waitingForInput }
        if Self.showsChoiceList(in: tail) { return .waitingForInput }
        if Self.finishedMarkers.contains(where: lowered.contains) { return .finished }
        if Self.workingMarkers.contains(where: lowered.contains) { return .working }
        if Self.hasComposerWithTranscript(tail) { return .ready }
        return .idle
    }

    /// The bottom `inspectedTailLines` non-empty lines, which is where the
    /// status area lives regardless of how much transcript sits above it.
    static func tail(of screen: String) -> String {
        let lines = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(inspectedTailLines).joined(separator: "\n")
    }

    /// Detects a composer prompt (ready marker) with non-empty transcript above it.
    /// This distinguishes "agent finished its turn, your move" (ready) from
    /// "nothing has happened yet" (idle).
    private static func hasComposerWithTranscript(_ tail: String) -> Bool {
        let lines = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return false }
        // Last line should have a ready marker (composer prompt)
        let lastLine = lines.last ?? ""
        let hasReadyMarker = Self.readyMarkers.contains { lastLine.hasPrefix($0) }
        // And there should be transcript content above (non-marker lines)
        let hasTranscript = lines.dropLast().contains { !$0.isEmpty }
        return hasReadyMarker && hasTranscript
    }

    /// An interactive picker — several numbered options with a selection
    /// caret on one of them. The caret is what distinguishes a live prompt
    /// from a numbered list the agent merely printed.
    private static func showsChoiceList(in tail: String) -> Bool {
        var numberedOptions = 0
        var hasSelectionCaret = false
        for line in tail.split(separator: "\n") {
            guard let isSelected = numberedOptionIsSelected(in: line) else { continue }
            numberedOptions += 1
            if isSelected { hasSelectionCaret = true }
        }
        return numberedOptions >= 2 && hasSelectionCaret
    }

    /// Matches `❯ 1. Yes` / `2. No` and the ASCII `> 1.` variant, returning
    /// whether this option carries the selection caret.
    private static func numberedOptionIsSelected(in line: Substring) -> Bool? {
        var scalars = Substring(line.drop { $0 == " " })
        var isSelected = false
        if let first = scalars.first, first == "❯" || first == ">" || first == "›" {
            isSelected = true
            scalars = Substring(scalars.dropFirst().drop { $0 == " " })
        }
        let digits = scalars.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        var rest = scalars.dropFirst(digits.count)
        guard rest.first == "." || rest.first == ")" else { return nil }
        rest = Substring(rest.dropFirst().drop { $0 == " " })
        guard !rest.isEmpty else { return nil }
        return isSelected
    }
}
