import Foundation
import SessionKit
import GitKit
import AgentKit
import CompanionKit
import SettingsKit

/// Translates the Mac's session records into what the phone renders.
///
/// Pure: every input is a value, so the mapping is unit-tested without an
/// `AppStore`.
enum CompanionSnapshotBuilder {
    struct SessionContext {
        var diffStat: GitDiffStat?
        var handoffTargets: [AgentKind]
        var isProcessLive: Bool
        /// Cards the phone can answer, from the provider permission bridge.
        var answerable: [PendingInteraction]
        /// The provider accepted a phone answer, but the persisted session
        /// status has not caught up yet. Do not replace that card with the
        /// generic terminal fallback during this handoff window.
        var suppressTerminalFallback: Bool = false
    }

    static let crashReason = "The agent process exited unexpectedly"

    static func snapshot(
        macID: String,
        macName: String,
        sessions: [Session],
        projects: [Project],
        catalog: CompanionKit.AgentCatalog? = nil,
        context: (Session) -> SessionContext
    ) -> FleetSnapshot {
        var pending: [UUID: [PendingInteraction]] = [:]
        let companionSessions = sessions
            .sorted { $0.lastActiveAt > $1.lastActiveAt }
            .map { session -> CompanionSession in
                let sessionContext = context(session)
                let cards = interactions(
                    for: session,
                    answerable: sessionContext.answerable,
                    suppressTerminalFallback: sessionContext.suppressTerminalFallback
                )
                if !cards.isEmpty { pending[session.id] = cards }
                return companionSession(session, context: sessionContext, cards: cards)
            }
        return FleetSnapshot(
            macID: macID,
            macName: macName,
            sessions: companionSessions,
            projects: projects
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { ProjectSummary(id: $0.id, name: $0.name) },
            catalog: catalog ?? self.catalog(),
            pending: pending
        )
    }

    static func companionSession(_ session: Session, context: SessionContext, cards: [PendingInteraction]) -> CompanionSession {
        CompanionSession(
            id: session.id,
            title: session.title,
            agent: session.agent,
            model: session.model ?? AgentCatalog.descriptor(for: session.agent).fallbackModels.first ?? "default",
            effort: session.effort,
            status: cards.contains(where: { $0.resolution == nil }) ? .waitingForInput : session.status,
            waitingReason: session.waitingReason,
            projectID: session.projectID,
            branch: session.worktree?.branchName,
            hasWorktree: session.worktree != nil,
            isProcessLive: context.isProcessLive,
            updatedAt: session.lastActiveAt,
            diffStat: context.diffStat.flatMap { $0.isEmpty ? nil : DiffStat(files: $0.files, additions: $0.additions, deletions: $0.deletions) },
            attentionSummary: cards.first?.attentionSummary,
            crashReason: session.status == .crashed ? crashReason : nil,
            handoffTargets: context.handoffTargets,
            hasTranscript: true
        )
    }

    /// The provider's answerable requests whenever there are any — they are
    /// authoritative, and the session's status can already read `working`
    /// while a second approval is still open. Otherwise a waiting session gets
    /// one "Needs the terminal" card naming what the agent waits for — the
    /// phone must never offer a prompt field then.
    static func interactions(
        for session: Session,
        answerable: [PendingInteraction],
        suppressTerminalFallback: Bool = false
    ) -> [PendingInteraction] {
        if !answerable.isEmpty { return answerable }
        guard session.status == .waitingForInput, !suppressTerminalFallback else { return [] }
        let title = switch session.waitingReason {
        case .permission: "Permission prompt"
        case .question: "Question"
        case .planApproval: "Plan approval"
        case nil: "Waiting for input"
        }
        return [PendingInteraction(
            id: terminalCardID(for: session),
            kind: .needsTerminal(dialogTitle: title),
            raisedAt: session.lastActiveAt
        )]
    }

    /// Stable per session and reason, so the phone doesn't re-animate the
    /// same card on every snapshot.
    static func terminalCardID(for session: Session) -> UUID {
        var bytes = withUnsafeBytes(of: session.id.uuid) { Array($0) }
        let reason: UInt8 = switch session.waitingReason {
        case .permission: 1
        case .question: 2
        case .planApproval: 3
        case nil: 0
        }
        bytes[15] ^= 0xA5 ^ reason
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Queries `ModelCatalogCache` for live model profiles, descriptions, and
    /// Antigravity groups. `openCodeSubscription` should be the Mac's
    /// currently configured plan — passing `.none` (the default) means
    /// OpenCode has nothing to scope a live query to, so its entry falls
    /// back to the static catalog with no per-model display names beyond
    /// what `ModelCatalog`'s own fallback table already knows.
    static func catalog(openCodeSubscription: OpenCodeSubscription = .none) async -> CompanionKit.AgentCatalog {
        var entries: [AgentKind: CompanionKit.AgentCatalog.Entry] = [:]
        for agent in AgentKind.allCases {
            let profiles = await ModelCatalogCache.shared.profiles(for: agent, openCodeSubscription: openCodeSubscription)
            let models = profiles.map {
                CompanionKit.ModelOption(slug: $0.slug, displayName: $0.displayName, description: $0.description)
            }
            let effortOptions = AgentEffortCatalog.options(for: agent, model: nil, profiles: profiles)
            let antigravityGroups: [CompanionKit.AntigravityGroupOption]
            if agent == .antigravity {
                let groups = await ModelCatalogCache.shared.antigravityGroups()
                antigravityGroups = groups.map {
                    CompanionKit.AntigravityGroupOption(
                        baseSlug: $0.baseSlug,
                        displayName: $0.displayName,
                        variants: $0.variants,
                        soleSlug: $0.soleSlug
                    )
                }
            } else {
                antigravityGroups = []
            }
            let defaultModel = models.first?.slug ?? AgentKit.AgentCatalog.descriptor(for: agent).fallbackModels.first ?? ""
            entries[agent] = .init(
                models: models,
                defaultModel: defaultModel,
                effortLevels: effortOptions.map(\.level),
                defaultEffort: agent.supportsEffortSelection ? (effortOptions.first { $0.level == .medium }?.level ?? effortOptions.first?.level) : nil,
                effortLabels: Dictionary(uniqueKeysWithValues: effortOptions.map { ($0.level, $0.label) }),
                antigravityGroups: antigravityGroups
            )
        }
        return .init(entries: entries)
    }

    /// Static fallback lists when offline or before live catalog finishes loading.
    static func catalog(openCodeSubscription: OpenCodeSubscription = .none) -> CompanionKit.AgentCatalog {
        var entries: [AgentKind: CompanionKit.AgentCatalog.Entry] = [:]
        for agent in AgentKind.allCases {
            let profiles = ModelCatalog.staticFallbackProfiles(for: agent, openCodeSubscription: openCodeSubscription)
            let models = profiles.map {
                CompanionKit.ModelOption(slug: $0.slug, displayName: $0.displayName, description: $0.description)
            }
            let options = AgentEffortCatalog.staticOptions(for: agent)
            let antigravityGroups: [CompanionKit.AntigravityGroupOption]
            if agent == .antigravity {
                antigravityGroups = ModelCatalog.staticAntigravityGroups().map {
                    CompanionKit.AntigravityGroupOption(
                        baseSlug: $0.baseSlug,
                        displayName: $0.displayName,
                        variants: $0.variants,
                        soleSlug: $0.soleSlug
                    )
                }
            } else {
                antigravityGroups = []
            }
            let defaultModel = models.first?.slug ?? AgentKit.AgentCatalog.descriptor(for: agent).fallbackModels.first ?? ""
            entries[agent] = .init(
                models: models,
                defaultModel: defaultModel,
                effortLevels: options.map(\.level),
                defaultEffort: agent.supportsEffortSelection ? (options.first { $0.level == .medium }?.level ?? options.first?.level) : nil,
                effortLabels: Dictionary(uniqueKeysWithValues: options.map { ($0.level, $0.label) }),
                antigravityGroups: antigravityGroups
            )
        }
        return .init(entries: entries)
    }

    // MARK: - Git

    static func fileDiffs(_ changes: [GitCommitFileChange]) -> [CompanionKit.FileDiff] {
        changes.map { change in
            let kind: CompanionKit.FileDiff.Change = switch change.kind {
            case .added: .added
            case .deleted: .deleted
            case .renamed, .copied: .renamed(from: change.previousPath ?? change.path)
            case .modified, .typeChanged, .unmerged: .modified
            }
            return CompanionKit.FileDiff(
                path: change.path,
                change: kind,
                hunks: change.hunks.map { DiffHunk(header: $0.header, unifiedLines: $0.lines) }
            )
        }
    }

    static func commits(_ log: [GitCommit], unpushed: Set<String>) -> [CommitSummary] {
        log.map {
            CommitSummary(hash: $0.sha, subject: $0.subject, author: $0.authorName, date: $0.authorDate, isPushed: !unpushed.contains($0.sha))
        }
    }
}
