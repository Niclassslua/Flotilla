import SwiftUI
import SessionKit
import DesignSystem

/// Maps SessionKit's domain status into presentation — kept in the App
/// layer so DesignSystem and SessionKit stay decoupled from each other.
enum StatusPresentation {
    static func color(for status: SessionStatus) -> Color {
        switch status {
        case .working: return FlotillaColors.statusWorking
        case .idle: return FlotillaColors.statusIdle
        case .waitingForInput: return FlotillaColors.statusWaitingForInput
        case .ready: return FlotillaColors.statusReady
        case .finished: return FlotillaColors.statusFinished
        case .crashed: return FlotillaColors.statusCrashed
        }
    }

    static func label(
        for status: SessionStatus,
        waitingReason: SessionWaitingReason? = nil
    ) -> String {
        switch status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .waitingForInput:
            switch waitingReason {
            case .permission: return "Needs Permission"
            case .question: return "Needs Answer"
            case .planApproval: return "Plan Ready"
            case nil: return "Waiting for Input"
            }
        case .ready: return "Ready"
        case .finished: return "Finished"
        case .crashed: return "Crashed"
        }
    }

    static func glyph(
        for status: SessionStatus,
        waitingReason: SessionWaitingReason? = nil
    ) -> String {
        switch status {
        case .working: return "gearshape.2"
        case .idle: return "circle"
        case .waitingForInput:
            switch waitingReason {
            case .permission: return "lock.open"
            case .question: return "questionmark.bubble"
            case .planApproval: return "list.clipboard"
            case nil: return "exclamationmark.circle"
            }
        case .ready: return "hand.raised"
        case .finished: return "checkmark.circle"
        case .crashed: return "xmark.octagon"
        }
    }

    /// Lowercase technical register for dense surfaces like the sidebar's
    /// fleet legend, where title-case labels would read as shouting.
    static func compactLabel(for status: SessionStatus) -> String {
        switch status {
        case .working: return "working"
        case .idle: return "idle"
        case .waitingForInput: return "waiting"
        case .ready: return "ready"
        case .finished: return "finished"
        case .crashed: return "crashed"
        }
    }

    /// Statuses ordered by how urgently they need attention. Drives the
    /// sidebar's fleet composition bar and legend so the most actionable
    /// state is always read first.
    static let attentionOrder: [SessionStatus] = [.waitingForInput, .working, .ready, .idle, .finished, .crashed]
}
