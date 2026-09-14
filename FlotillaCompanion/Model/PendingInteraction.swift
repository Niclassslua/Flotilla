import Foundation

/// Something a session is blocked on, shown in the composer slot.
struct PendingInteraction: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case permission(PermissionRequest)
        case question([QuestionStep])
        case plan(PlanProposal)
        /// A dialog with no structured channel (Claude trust / MCP consent).
        /// Only answerable in the Mac's terminal.
        case needsTerminal(dialogTitle: String)
    }

    /// What happened to a card the phone did not resolve itself.
    enum Resolution: Hashable, Sendable {
        /// The Mac answered first; the card shows the outcome briefly.
        case answeredOnMac(outcome: String)
        /// The phone answered after the Mac had already done so.
        case alreadyAnswered
    }

    let id: UUID
    var kind: Kind
    /// Set for requests raised by a subagent (`general`, `Explore`).
    var subagent: String?
    var raisedAt: Date
    var resolution: Resolution?

    init(id: UUID = UUID(), kind: Kind, subagent: String? = nil, raisedAt: Date = .now, resolution: Resolution? = nil) {
        self.id = id
        self.kind = kind
        self.subagent = subagent
        self.raisedAt = raisedAt
        self.resolution = resolution
    }

    /// The one-line summary a fleet row shows.
    var attentionSummary: String {
        switch kind {
        case .permission(let request): "Allow \(request.summary)?"
        case .question(let steps): steps.first?.prompt ?? "Question"
        case .plan(let plan): plan.title
        case .needsTerminal(let title): "Needs your Mac · \(title)"
        }
    }
}

struct PermissionRequest: Hashable, Sendable {
    /// `Bash`, `Edit`, `Write`, `WebFetch`…
    var tool: String
    /// The command, file path, or URL.
    var summary: String
    /// A diff preview or longer command body, when there is one.
    var detail: String?
    /// The pattern an always-allow would cover, for providers that scope it
    /// by pattern (OpenCode: `touch *`).
    var pattern: String?
}

struct QuestionStep: Identifiable, Hashable, Sendable {
    struct Option: Hashable, Sendable {
        var label: String
        var description: String?
    }

    let id: String
    /// A short chip-like header (`Auth method`).
    var header: String
    var prompt: String
    var options: [Option]
    var allowsMultiple: Bool
}

struct PlanProposal: Hashable, Sendable {
    var title: String
    var markdown: String
}

/// Every answer the phone can give. One `answer` intent carries all of them so
/// the data layer can apply first-answer-wins in one place.
enum InteractionAnswer: Hashable, Sendable {
    case allow
    case deny
    case alwaysAllow
    case allowWithNote(String)
    case denyWithNote(String)
    case denyAndStop
    case questionAnswers([QuestionAnswer])
    case approvePlan(PlanApprovalMode?)
    case revisePlan(String)
}

struct QuestionAnswer: Hashable, Sendable {
    var stepID: String
    var selected: [String]
    var other: String?
}

enum PlanApprovalMode: Hashable, Sendable {
    case autoAccept
    case askForEdits
}

enum AnswerOutcome: Sendable {
    case accepted
    case alreadyAnswered
}
