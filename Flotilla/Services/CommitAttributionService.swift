import Foundation
import os
import SessionKit
import SettingsKit
import GitKit

/// Answers which agent session made each commit, for History.
@MainActor
protocol CommitAttributionResolving: AnyObject {
    func attributions(
        forCommits shas: [String],
        repoPath: URL,
        sessions: [Session]
    ) async -> [String: CommitAttribution]
}

/// Commit attribution in all three `CommitAttributionMode`s.
///
/// - **Launch**: `environment(for:base:)` writes the session's payload and
///   returns the environment that makes the agent's git run
///   `CommitAttributionHooks`. Flotilla's own commit buttons use the same
///   environment, so their commits are attributed the same way.
/// - **On this Mac**: the hooks spool events. `ingestPendingEvents()` stores
///   them; `attributions` follows explicit rewrite mappings and uniquely
///   matching patches, then answers from the database.
/// - **Shared**: markers travel inside the repository, and `attributions`
///   prefers them over anything recorded locally.
@MainActor
final class CommitAttributionService: CommitAttributionResolving {
    private let repository: SessionRepository
    private let gitService: any GitServiceProtocol
    private let settingsProvider: () -> AppSettings
    private let payloadRoot: URL
    private let hooksDirectory: URL
    /// A SHA's patch ID never changes, so each is computed at most once per launch.
    private var ingestionTask: Task<Void, Never>?
    private var ingestingDirectories: Set<URL> = []
    private var patchIDs: [String: String] = [:]
    private var patchIDMisses: Set<String> = []
    private let log = Logger(subsystem: "com.niclassslua.flotilla", category: "CommitAttribution")

    /// A rewritten commit is always committed after the original was recorded;
    /// the slack only absorbs clock differences between git and the hook.
    private static let rewriteSearchSlack: TimeInterval = 24 * 60 * 60

    init(
        repository: SessionRepository,
        gitService: any GitServiceProtocol,
        settingsProvider: @escaping () -> AppSettings,
        supportDirectory: URL
    ) {
        self.repository = repository
        self.gitService = gitService
        self.settingsProvider = settingsProvider
        payloadRoot = supportDirectory.appendingPathComponent("attribution", isDirectory: true)
        hooksDirectory = supportDirectory.appendingPathComponent("attribution-hooks-\(CommitAttributionHooks.version)", isDirectory: true)
    }

    /// Drain promptly while the app runs, including pending events from a prior launch.
    func startIngesting() {
        guard ingestionTask == nil else { return }
        ingestionTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.ingestPendingEvents()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
            }
        }
    }

    deinit { ingestionTask?.cancel() }

    func payloadDirectory(for sessionID: UUID) -> URL {
        payloadRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func mode(for session: Session) -> CommitAttributionMode {
        settingsProvider().git.commitAttributionMode(forProject: session.projectID)
    }

    // MARK: - Recording

    /// Writes the session's payload and returns `base` extended so git runs the
    /// attribution hooks. `nil` when that fails: attribution must never be the
    /// reason a session doesn't start or a commit doesn't happen.
    func environment(for session: Session, base: [String: String]) -> [String: String]? {
        do {
            try CommitAttributionHooks().prepare(directory: hooksDirectory)
            try writePayload(for: session)
        } catch {
            log.notice("Could not prepare commit attribution: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        return CommitAttributionHooks.environment(
            base: base,
            sessionID: session.id.uuidString,
            attributionDirectory: payloadDirectory(for: session.id),
            flotillaHooksDirectory: hooksDirectory,
            originalHooksDirectory: nil
        )
    }

    /// For a commit Flotilla itself makes in a session's checkout.
    func commitEnvironment(for session: Session) -> [String: String] {
        environment(for: session, base: ProcessInfo.processInfo.environment) ?? [:]
    }

    /// Rewrites the payload of every session that has one, so a changed mode
    /// or title reaches agents that are already running.
    func refreshPayloads(for sessions: [Session]) {
        for session in sessions where FileManager.default.fileExists(atPath: payloadDirectory(for: session.id).path) {
            try? writePayload(for: session)
        }
    }

    /// Forgets a deleted session's payload. Its recorded commits stay.
    func removePayload(sessionID: UUID) {
        try? FileManager.default.removeItem(at: payloadDirectory(for: sessionID))
    }

    private func writePayload(for session: Session) throws {
        let hookMode = CommitAttributionHookMode(rawValue: mode(for: session).rawValue) ?? .off
        let info = CommitAttributionSessionInfo(
            sessionID: session.id,
            projectID: session.projectID,
            agent: session.agent.rawValue,
            model: session.model.flatMap { $0.isEmpty ? nil : $0 },
            title: session.title,
            prompt: session.goal,
            createdAt: session.createdAt
        )
        try CommitAttributionPayload.write(info, mode: hookMode, to: payloadDirectory(for: session.id))
    }

    // MARK: - Ingesting

    /// Stores what the hooks spooled for every session, including sessions
    /// deleted since — their payload still says who they were.
    func ingestPendingEvents() async {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories where UUID(uuidString: directory.lastPathComponent) != nil {
            await ingest(payloadDirectory: directory)
        }
    }

    func ingestPendingEvents(sessionID: UUID) async {
        await ingest(payloadDirectory: payloadDirectory(for: sessionID))
    }

    private func ingest(payloadDirectory directory: URL) async {
        guard ingestingDirectories.insert(directory).inserted else { return }
        defer { ingestingDirectories.remove(directory) }
        guard let info = CommitAttributionPayload.readSessionInfo(in: directory),
              let sessionAgent = AgentKind(rawValue: info.agent)
        else { return }
        let claim = CommitAttributionPayload.claimEvents(in: directory)
        do {
            try await store(claim.events, for: info, sessionAgent: sessionAgent)
            claim.complete()
        } catch {
            log.notice("Could not store commit attribution events: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func store(
        _ events: [CommitAttributionEvent],
        for info: CommitAttributionSessionInfo,
        sessionAgent: AgentKind
    ) async throws {
        var touchedRepositories: [String] = []
        for event in events {
            switch event {
            case .commit(let commit):
                let info = commit.sessionInfo ?? info
                let repositoryKey = commit.commonDirectory
                if !touchedRepositories.contains(repositoryKey) {
                    try saveSnapshot(info, agent: sessionAgent, repositoryKey: repositoryKey)
                    touchedRepositories.append(repositoryKey)
                }
                if try repository.loadAttributedCommits(repositoryKey: repositoryKey).contains(where: {
                    $0.sessionID == info.sessionID && $0.originalSHA == commit.sha
                }) { continue }
                let record = AttributedCommit(
                    sessionID: info.sessionID,
                    repositoryKey: repositoryKey,
                    authorEmail: commit.authorEmail,
                    authorTime: commit.authorTime,
                    patchID: await patchID(ofCommit: commit.sha, at: URL(fileURLWithPath: repositoryKey)),
                    originalSHA: commit.sha,
                    agent: AgentKind(rawValue: commit.agent) ?? sessionAgent,
                    model: commit.model,
                    recordedAt: commit.recordedAt
                )
                try repository.saveAttributedCommits(
                    [record],
                    links: [AttributedCommitLink(
                        commitID: record.id,
                        sha: commit.sha,
                        source: .recorded,
                        verifiedAt: commit.recordedAt
                    )]
                )
            case .rewrite(let rewrite):
                try applyRewrite(rewrite)
                if !touchedRepositories.contains(rewrite.commonDirectory) {
                    touchedRepositories.append(rewrite.commonDirectory)
                }
            }
        }
    }

    private func saveSnapshot(
        _ info: CommitAttributionSessionInfo,
        agent: AgentKind,
        repositoryKey: String
    ) throws {
        let existing = try repository.loadAttributionSessions(repositoryKey: repositoryKey)
            .first { $0.sessionID == info.sessionID }
        guard existing == nil else { return }
        try repository.saveAttributionSession(AttributionSessionSnapshot(
            sessionID: info.sessionID,
            projectID: info.projectID,
            repositoryKey: repositoryKey,
            agent: agent,
            model: info.model,
            title: info.title,
            prompt: info.prompt,
            combinedPatchID: existing?.combinedPatchID,
            createdAt: info.createdAt
        ))
    }

    /// Git reported exactly where an amend or rebase moved each commit.
    private func applyRewrite(_ rewrite: CommitAttributionEvent.Rewrite) throws {
        let links = try repository.loadAttributedCommitLinks(repositoryKey: rewrite.commonDirectory)
        var commitIDsBySHA: [String: [UUID]] = [:]
        for link in links {
            commitIDsBySHA[link.sha, default: []].append(link.commitID)
        }
        let moved = rewrite.pairs.flatMap { pair in
            (commitIDsBySHA[pair.old] ?? []).map {
                AttributedCommitLink(commitID: $0, sha: pair.new, source: .rewrite, verifiedAt: rewrite.recordedAt)
            }
        }
        try repository.saveAttributedCommitLinks(moved)
    }

    private func patchID(ofCommit sha: String, at repoPath: URL) async -> String? {
        if let known = patchIDs[sha] { return known }
        guard !patchIDMisses.contains(sha) else { return nil }
        let id = try? await gitService.patchID(ofCommit: sha, at: repoPath)
        if let id {
            patchIDs[sha] = id
        } else {
            patchIDMisses.insert(sha)
        }
        return id
    }

    // MARK: - Resolving

    func attributions(
        forCommits shas: [String],
        repoPath: URL,
        sessions: [Session]
    ) async -> [String: CommitAttribution] {
        guard !shas.isEmpty else { return [:] }
        var result = await recordedAttributions(forCommits: shas, repoPath: repoPath, sessions: sessions)
        // Markers travel with the repository, so they outrank this Mac's records.
        for (sha, attribution) in await sharedAttributions(forCommits: shas, repoPath: repoPath, sessions: sessions) {
            result[sha] = attribution
        }
        return result
    }

    private func recordedAttributions(
        forCommits shas: [String],
        repoPath: URL,
        sessions: [Session]
    ) async -> [String: CommitAttribution] {
        // Resolved before ingesting: a store with no real repository behind it
        // (previews, test doubles) must not consume the app's pending events.
        guard let repositoryKey = try? await gitService.commonGitDirectory(at: repoPath) else { return [:] }
        await ingestPendingEvents()

        guard let snapshots = try? repository.loadAttributionSessions(repositoryKey: repositoryKey),
              !snapshots.isEmpty,
              let commits = try? repository.loadAttributedCommits(repositoryKey: repositoryKey),
              var links = try? repository.loadAttributedCommitLinks(repositoryKey: repositoryKey)
        else { return [:] }
        links += await repairLinks(commits: commits, links: links, snapshots: snapshots, repoPath: repoPath)

        let requested = Set(shas)
        let snapshotsByID = Dictionary(snapshots.map { ($0.sessionID, $0) }, uniquingKeysWith: { first, _ in first })
        let commitsByID = Dictionary(commits.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [String: AttributedCommit] = [:]
        for link in links where requested.contains(link.sha) {
            guard let commit = commitsByID[link.commitID] else { continue }
            // A squash can absorb several recorded commits; the newest speaks for it.
            if let current = chosen[link.sha], current.authorTime >= commit.authorTime { continue }
            chosen[link.sha] = commit
        }

        return chosen.compactMapValues { commit in
            guard let snapshot = snapshotsByID[commit.sessionID] else { return nil }
            let live = sessions.first { $0.id == commit.sessionID }
            return CommitAttribution(
                agent: commit.agent,
                model: commit.model,
                sessionID: commit.sessionID,
                sessionTitle: live?.title ?? snapshot.title,
                prompt: snapshot.prompt,
                branchName: live?.worktree?.branchName,
                source: .thisMac
            )
        }
    }

    /// Finds where recorded commits live now after git rewrote them outside
    /// the agent — a Terminal rebase, a squash merge — and stores the links.
    private func repairLinks(
        commits: [AttributedCommit],
        links: [AttributedCommitLink],
        snapshots: [AttributionSessionSnapshot],
        repoPath: URL
    ) async -> [AttributedCommitLink] {
        guard let oldest = commits.map(\.recordedAt).min(),
              let identities = try? await gitService.commitIdentities(
                  at: repoPath,
                  since: oldest.addingTimeInterval(-Self.rewriteSearchSlack)
              )
        else { return [] }
        let now = Date()
        var repaired: [AttributedCommitLink] = []
        var identitiesByAuthor: [String: [GitCommitIdentity]] = [:]
        for identity in identities {
            identitiesByAuthor[Self.authorKey(identity.authorEmail, identity.authorTime), default: []].append(identity)
        }

        // Author timestamps have one-second precision and are not identities.
        // Only a unique candidate with the same patch can repair an unknown move.
        for commit in commits {
            let knownSHAs = Set(links.filter { $0.commitID == commit.id }.map(\.sha))
            let candidates = (identitiesByAuthor[Self.authorKey(commit.authorEmail, commit.authorTime)] ?? [])
                .filter { !knownSHAs.contains($0.sha) }
            // Identical patches from separate recorded contributions cannot be
            // distinguished by author fields; leave those associations unresolved.
            guard commits.filter({
                $0.authorEmail == commit.authorEmail && $0.authorTime == commit.authorTime && $0.patchID == commit.patchID
            }).count == 1 else { continue }
            var matches: [GitCommitIdentity] = []
            if let originalPatch = commit.patchID {
                for candidate in candidates where await patchID(ofCommit: candidate.sha, at: repoPath) == originalPatch {
                    matches.append(candidate)
                }
            }
            if matches.count == 1, let match = matches.first {
                repaired.append(AttributedCommitLink(commitID: commit.id, sha: match.sha, source: .authorTime, verifiedAt: now))
            }
        }

        // Exact post-rewrite pairs support squashes. Do not infer a squash from
        // a session-wide diff: unrelated intervening commits may contribute to it.

        do {
            try repository.saveAttributedCommitLinks(repaired)
        } catch {
            log.notice("Could not store repaired attribution links: \(error.localizedDescription, privacy: .public)")
        }
        return repaired
    }

    private static func authorKey(_ email: String, _ time: Int) -> String {
        "\(email)\u{0}\(time)"
    }

    private func sharedAttributions(
        forCommits shas: [String],
        repoPath: URL,
        sessions: [Session]
    ) async -> [String: CommitAttribution] {
        guard let markersBySHA = try? await gitService.addedAttributionMarkers(forCommits: shas, at: repoPath),
              !markersBySHA.isEmpty
        else { return [:] }

        var result: [String: CommitAttribution] = [:]
        for (sha, paths) in markersBySHA {
            guard let marker = paths.lazy.compactMap({ CommitAttributionMarker(path: $0) }).first,
                  let agent = AgentKind(rawValue: marker.agent)
            else { continue }
            let document = await promptDocument(for: marker.sessionID, at: sha, repoPath: repoPath)
            let live = sessions.first { $0.id == marker.sessionID }
            result[sha] = CommitAttribution(
                agent: agent,
                model: Self.model(forSlug: marker.modelSlug, documented: document?.model),
                sessionID: marker.sessionID,
                sessionTitle: live?.title ?? document?.title,
                prompt: document?.prompt ?? live?.goal,
                branchName: live?.worktree?.branchName,
                source: .repository
            )
        }
        return result
    }

    /// Read only the document belonging to the requested historical tree.
    private func promptDocument(for sessionID: UUID, at sha: String, repoPath: URL) async -> CommitAttributionSessionInfo? {
        let path = CommitAttributionMarker.promptDocumentPath(for: sessionID)
        for revision in [sha] {
            if let text = try? await gitService.fileContents(at: repoPath, path: path, revision: revision),
               let document = CommitAttributionPromptDocument.parse(text) {
                return document
            }
        }
        return nil
    }

    /// A marker spells the model as a file-name slug; the prompt document has
    /// the exact name, which wins whenever the two agree.
    private static func model(forSlug slug: String, documented: String?) -> String? {
        if let documented, CommitAttributionMarker.slug(documented) == slug {
            return documented
        }
        return slug == "default" ? nil : slug
    }

    // MARK: - Deleting

    /// Removes every record kept on this Mac, including events not yet
    /// ingested — otherwise the next History load would bring them back.
    func deleteLocalRecords() {
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: payloadRoot,
            includingPropertiesForKeys: nil
        )) ?? []
        for directory in directories {
            CommitAttributionPayload.claimEvents(in: directory).complete()
        }
        do {
            try repository.deleteAllCommitAttribution()
        } catch {
            log.notice("Could not delete commit attribution records: \(error.localizedDescription, privacy: .public)")
        }
        patchIDs.removeAll()
        patchIDMisses.removeAll()
    }
}
