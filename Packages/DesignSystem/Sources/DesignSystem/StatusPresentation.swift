import SwiftUI
import SessionKit

/// Maps SessionKit's domain status into presentation. Lives here, not in an
/// app target, so the Mac app and the iOS companion label and colour a
/// status identically.
///
/// A `nil` status means the session has produced no signal yet ("Unstarted").
/// It presents quietly: a muted dot, and `StatusBadge` renders nothing at all.
public enum StatusPresentation {
    public static func color(for status: SessionStatus?) -> Color {
        switch status {
        case .working: return FlotillaColors.statusWorking
        case .waitingForInput: return FlotillaColors.statusWaitingForInput
        case .readyForReview: return FlotillaColors.statusReady
        case .crashed: return FlotillaColors.statusCrashed
        case nil: return FlotillaColors.statusIdle
        }
    }

    public static func label(
        for status: SessionStatus?,
        waitingReason: SessionWaitingReason? = nil
    ) -> String {
        switch status {
        case .working: return "Working"
        case .waitingForInput:
            switch waitingReason {
            case .permission: return "Needs Permission"
            case .question: return "Needs Answer"
            case .planApproval: return "Plan Ready"
            case nil: return "Waiting for Input"
            }
        case .readyForReview: return "Ready for Review"
        case .crashed: return "Crashed"
        case nil: return "Unstarted"
        }
    }

    public static func glyph(
        for status: SessionStatus?,
        waitingReason: SessionWaitingReason? = nil
    ) -> String {
        switch status {
        case .working: return "gearshape.2"
        case .waitingForInput:
            switch waitingReason {
            case .permission: return "lock.open"
            case .question: return "questionmark.bubble"
            case .planApproval: return "list.clipboard"
            case nil: return "exclamationmark.circle"
            }
        case .readyForReview: return "checkmark.circle"
        case .crashed: return "xmark.octagon"
        case nil: return "circle.dotted"
        }
    }

    /// Lowercase technical register for dense surfaces like the sidebar's
    /// fleet legend, where title-case labels would read as shouting.
    public static func compactLabel(for status: SessionStatus) -> String {
        switch status {
        case .working: return "working"
        case .waitingForInput: return "waiting"
        case .readyForReview: return "review"
        case .crashed: return "crashed"
        }
    }

    /// Statuses ordered by how urgently they need attention. Drives the
    /// sidebar's fleet composition bar and legend so the most actionable
    /// state is always read first.
    public static let attentionOrder: [SessionStatus] = [.waitingForInput, .working, .readyForReview, .crashed]
}
