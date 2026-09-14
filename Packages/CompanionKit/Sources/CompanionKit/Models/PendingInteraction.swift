import Foundation

/// Something a session is blocked on, shown in the composer slot.
public struct PendingInteraction: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case permission(PermissionRequest)
        case question([QuestionStep])
        case plan(PlanProposal)
        /// A dialog the phone can't answer — no structured channel for it.
        /// Only answerable in the Mac's terminal.
        case needsTerminal(dialogTitle: String)
    }

    /// What happened to a card the phone did not resolve itself.
    public enum Resolution: Hashable, Codable, Sendable {
        /// The Mac answered first; the card shows the outcome briefly.
        case answeredOnMac(outcome: String)
        /// The phone answered after the Mac had already done so.
        case alreadyAnswered
    }

    public let id: UUID
    public var kind: Kind
    /// Set for requests raised by a subagent (`general`, `Explore`).
    public var subagent: String?
    public var raisedAt: Date
    public var resolution: Resolution?

    public init(id: UUID = UUID(), kind: Kind, subagent: String? = nil, raisedAt: Date = .now, resolution: Resolution? = nil) {
        self.id = id
        self.kind = kind
        self.subagent = subagent
        self.raisedAt = raisedAt
        self.resolution = resolution
    }

    /// The one-line summary a fleet row shows.
    public var attentionSummary: String {
        switch kind {
        case .permission(let request): "Allow \(request.summary)?"
        case .question(let steps): steps.first?.prompt ?? "Question"
        case .plan(let plan): plan.title
        case .needsTerminal(let title): "Needs your Mac · \(title)"
        }
    }
}

public struct PermissionRequest: Hashable, Codable, Sendable {
    /// `Bash`, `Edit`, `Write`, `WebFetch`…
    public var tool: String
    /// The command, file path, or URL.
    public var summary: String
    /// A diff preview or longer command body, when there is one.
    public var detail: String?
    /// The pattern an always-allow would cover, for providers that scope it
    /// by pattern (OpenCode: `touch *`).
    public var pattern: String?
    /// `false` hides Always Allow where the answer path can't grant it (Codex's hook fallback).
    public var allowsAlwaysAllow: Bool?
    /// `false` hides Deny and Stop where the answer path can't interrupt (Codex's hook fallback).
    public var allowsDenyAndStop: Bool?

    public init(tool: String, summary: String, detail: String? = nil, pattern: String? = nil, allowsAlwaysAllow: Bool? = nil, allowsDenyAndStop: Bool? = nil) {
        self.tool = tool
        self.summary = summary
        self.detail = detail
        self.pattern = pattern
        self.allowsAlwaysAllow = allowsAlwaysAllow
        self.allowsDenyAndStop = allowsDenyAndStop
    }
}

public struct QuestionStep: Identifiable, Hashable, Codable, Sendable {
    public struct Option: Hashable, Codable, Sendable {
        public var label: String
        public var description: String?

        public init(label: String, description: String? = nil) {
            self.label = label
            self.description = description
        }
    }

    public let id: String
    /// A short chip-like header (`Auth method`).
    public var header: String
    public var prompt: String
    public var options: [Option]
    public var allowsMultiple: Bool
    /// `false` hides the write-in text field for providers that don't support free-text answers.
    public var allowsFreeText: Bool?

    public init(id: String, header: String, prompt: String, options: [Option], allowsMultiple: Bool, allowsFreeText: Bool? = nil) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.allowsMultiple = allowsMultiple
        self.allowsFreeText = allowsFreeText
    }
}

public struct PlanProposal: Hashable, Codable, Sendable {
    public var title: String
    public var markdown: String

    public init(title: String, markdown: String) {
        self.title = title
        self.markdown = markdown
    }
}

/// Every answer the phone can give. One `answer` intent carries all of them so
/// the data layer can apply first-answer-wins in one place.
public enum InteractionAnswer: Hashable, Codable, Sendable {
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

public struct QuestionAnswer: Hashable, Codable, Sendable {
    public var stepID: String
    public var selected: [String]
    public var other: String?

    public init(stepID: String, selected: [String], other: String? = nil) {
        self.stepID = stepID
        self.selected = selected
        self.other = other
    }
}

public enum PlanApprovalMode: Hashable, Codable, Sendable {
    case autoAccept
    case askForEdits
}

public enum AnswerOutcome: Hashable, Codable, Sendable {
    case accepted
    case alreadyAnswered
}
