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
    /// General markers consult only the bottom of the screen. Agent CLIs draw
    /// their status line, spinner, and composer there; everything above is
    /// arbitrary transcript text that will sooner or later contain any word
    /// we look for — including "esc to interrupt", quoted back by an agent
    /// discussing this very file. The narrow Antigravity permission picker
    /// has a stricter, extended-window signature below.
    public static let inspectedTailLines = 8

    /// Antigravity's permission picker repeats a long command across several
    /// choices. At narrow terminal widths that can push both its heading and
    /// selected choice above the ordinary status-area tail. This larger
    /// window is used only for the combined heading + live-choice signature,
    /// not for broad marker matching against arbitrary transcript text.
    private static let inspectedInteractiveTailLines = 24

    /// Drawn only while the agent is busy, and removed the moment it stops.
    /// These are hints to the user about how to *stop* the work in progress,
    /// which is why they are such a dependable signal.
    private static let workingMarkers = [
        "esc to interrupt",
        "escape to interrupt",
        "esc to cancel",
        "escape to cancel",
        "ctrl+c to interrupt",
        "ctrl-c to interrupt",
        "ctrl+c to stop",
    ]

    /// Approval prompts. Checked before the working markers: some CLIs keep
    /// a spinner underneath a prompt, and needing the user outranks busy.
    private static let permissionMarkers = [
        "do you want to",
        "do you trust",
        // Claude Code's workspace-trust dialog (2.1.291). It holds back every
        // hook until accepted, so the screen is the only thing that can see it.
        "yes, i trust this folder",
        "permission required",
        "permission requested",
        "requires permission",
        "press enter to continue",
        "(y/n)",
        "[y/n]",
        "yes/no",
        "allow this",
        "approve?",
    ]

    /// Provider-specific signals that the agent has produced a plan and is
    /// waiting for the user to review or approve it.
    private static let planApprovalMarkers = [
        "approval for the plan",
        "approve the plan",
        "approve this plan",
        "plan is ready",
        "plan ready for approval",
        "proposed plan",
        "<proposed_plan>",
    ]

    /// A genuine question from the agent, distinct from a tool permission.
    private static let questionMarkers = [
        " unanswered)",
        "waiting for your answer",
        "answer the question",
        "provide your answer",
        "question for you",
    ]

    /// A provider's own statement that the user interrupted the turn. No hook
    /// fires on an interrupt, so this ends a hook-held episode (`endsTurn`).
    private static let interruptMarkers = [
        "interrupted · what should claude do instead?",
        "interrupted · what should antigravity cli do instead?",
    ]

    /// How Flotilla's tmux `remain-on-exit-format` banner begins.
    static let deadPaneBannerPrefix = "[agent exited"

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

    /// Classifies the screen. Returns an observation when the screen exhibits
    /// a recognized status indicator (a working interrupt/cancel marker, an
    /// interactive permission/question prompt, a dead pane, or a composer prompt
    /// with non-empty transcript history). Returns `nil` when no marker matches —
    /// an unremarkable screen, startup banner, or intermediate redraw carries no
    /// status signal and must not decay to Ready for Review.
    public func observation(forScreen screen: String) -> SessionStatusObservation? {
        let tail = Self.tail(of: screen)
        let lowered = tail.lowercased()

        // tmux's dead-pane banner is written below everything else, so when
        // it is the last line nothing above it — a stale permission prompt,
        // a spinner frame — describes a live agent.
        if Self.tail(of: screen, maximumLines: 1).lowercased().hasPrefix(Self.deadPaneBannerPrefix) {
            return SessionStatusObservation(
                .readyForReview,
                cause: "screen: tmux dead-pane banner",
                suggestsAgentExit: true
            )
        }

        let interactiveTail = Self.tail(of: screen, maximumLines: Self.inspectedInteractiveTailLines)
        let loweredInteractiveTail = interactiveTail.lowercased()
        if loweredInteractiveTail.contains("requesting permission for:"),
           Self.showsChoiceList(in: interactiveTail) {
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .permission,
                cause: "screen: Antigravity permission heading with live choice list"
            )
        }

        if let marker = Self.planApprovalMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .planApproval,
                cause: "screen: plan-approval marker \(Self.quoted(marker))"
            )
        }
        if let marker = Self.permissionMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .permission,
                cause: "screen: permission marker \(Self.quoted(marker))"
            )
        }
        if let marker = Self.questionMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .question,
                cause: "screen: question marker \(Self.quoted(marker))"
            )
        }
        if Self.showsChoiceList(in: tail) {
            return SessionStatusObservation(
                .waitingForInput,
                waitingReason: .question,
                cause: "screen: numbered choice list with a selection caret"
            )
        }
        if promptHeuristic.detectStatus(in: tail) == .waitingForInput {
            return SessionStatusObservation(
                .waitingForInput,
                cause: "screen: SessionStatusHeuristic prompt match"
            )
        }
        if let marker = Self.interruptMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .readyForReview,
                cause: "screen: interrupt marker \(Self.quoted(marker))",
                endsTurn: true
            )
        }
        // A dead pane and a composer with transcript both mean the turn is over
        // and the work is there to look at. Only an authoritative non-zero process
        // exit produces `crashed`, and that never comes from here. The branches
        // are kept distinct because their ordering relative to the working
        // marker still matters — a stale "esc to interrupt" left on a dead
        // pane must not read as `working`.
        if let marker = Self.finishedMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .readyForReview,
                cause: "screen: finished marker \(Self.quoted(marker))",
                suggestsAgentExit: true
            )
        }
        if let marker = Self.workingMarkers.first(where: lowered.contains) {
            return SessionStatusObservation(
                .working,
                cause: "screen: working marker \(Self.quoted(marker))"
            )
        }
        if Self.hasComposerWithTranscript(interactiveTail) {
            return SessionStatusObservation(
                .readyForReview,
                cause: "screen: composer prompt above a non-empty transcript"
            )
        }
        return nil
    }

    private static func quoted(_ marker: String) -> String {
        "\u{22}\(marker)\u{22}"
    }

    /// Compatibility convenience for callers interested only in the broad
    /// state. New observation pipelines should retain `waitingReason`.
    public func status(forScreen screen: String) -> SessionStatus? {
        observation(forScreen: screen)?.status
    }

    /// The bottom `inspectedTailLines` non-empty lines, which is where the
    /// status area lives regardless of how much transcript sits above it.
    static func tail(of screen: String, maximumLines: Int = inspectedTailLines) -> String {
        let lines = screen
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(maximumLines).joined(separator: "\n")
    }

    /// Detects a composer prompt (ready marker) with non-empty transcript above it.
    /// This distinguishes "agent finished its turn, your move" (ready) from
    /// "nothing has happened yet" (idle).
    private static func hasComposerWithTranscript(_ tail: String) -> Bool {
        let lines = tail.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2 else { return false }
        // Codex and Claude both draw model/path/usage footers *after* their
        // composer. Search the tail instead of requiring the prompt to be
        // the final non-empty line.
        guard let composerIndex = lines.lastIndex(where: Self.isComposerLine), composerIndex > 0 else {
            return false
        }
        return lines[..<composerIndex].contains(where: Self.isTranscriptLine)
    }

    private static func isComposerLine(_ line: String) -> Bool {
        var content = line.trimmingCharacters(in: .whitespaces)
        while let first = content.first, first == "│" || first == "┃" || first == "║" {
            content.removeFirst()
            content = content.trimmingCharacters(in: .whitespaces)
        }
        return Self.readyMarkers.contains { content.hasPrefix($0) }
    }

    private static func isTranscriptLine(_ line: String) -> Bool {
        let content = line.trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return false }
        let decoration = CharacterSet(charactersIn: "─━═-╭╮╰╯┌┐└┘│┃║ ")
        return content.unicodeScalars.contains { !decoration.contains($0) }
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
