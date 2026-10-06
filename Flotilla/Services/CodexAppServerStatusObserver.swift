import Foundation
import AgentKit
import HooksKit
import SessionKit

@MainActor
enum CodexAppServerAccess {
    static func latestSession(
        endpoint: String,
        workingDirectory: URL,
        since: Date?
    ) async throws -> DiscoveredAgentSession? {
        let rpc = ProviderRPC()
        try await rpc.connect(socketPath: endpoint)
        defer { rpc.close() }
        return try await latestSession(using: rpc, workingDirectory: workingDirectory, since: since)
    }

    static func latestSession(
        using rpc: any ProviderRPCServing,
        workingDirectory: URL,
        since: Date?
    ) async throws -> DiscoveredAgentSession? {
        let target = workingDirectory.standardizedFileURL.path
        var cursor: String?
        var visited = Set<String>()
        var matches: [DiscoveredAgentSession] = []

        repeat {
            var params: [String: Any] = [
                "cwd": target,
                "limit": 100,
                "sortDirection": "asc",
                "archived": false
            ]
            if let cursor { params["cursor"] = cursor }
            let response = try await rpc.request("thread/list", params: params)
            let data = response["data"]
            let threads = data as? [[String: Any]]
                ?? (data as? [String: Any])?["items"] as? [[String: Any]]
                ?? []

            for thread in threads {
                guard let id = thread["id"] as? String,
                      let cwd = thread["cwd"] as? String,
                      URL(fileURLWithPath: cwd).standardizedFileURL.path == target,
                      let createdSeconds = (thread["createdAt"] as? NSNumber)?.doubleValue
                else { continue }
                let createdAt = Date(timeIntervalSince1970: createdSeconds)
                guard since.map({ createdAt >= $0 }) ?? true else { continue }

                let rawName = (thread["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let usableName = rawName.flatMap { !$0.isEmpty && !$0.contains("\n") && $0.count <= 100 ? $0 : nil }
                let isCustom = usableName != nil
                let title = usableName
                    ?? TitleSynthesizer.synthesize(from: thread["preview"] as? String ?? "")
                    ?? ""
                let updatedAt = (thread["updatedAt"] as? NSNumber).map {
                    Date(timeIntervalSince1970: $0.doubleValue)
                }
                matches.append(DiscoveredAgentSession(
                    id: id,
                    title: title,
                    workingDirectory: URL(fileURLWithPath: cwd),
                    createdAt: createdAt,
                    lastActiveAt: updatedAt,
                    agent: .codexCLI,
                    isCustomTitle: isCustom
                ))
            }

            let page = data as? [String: Any]
            cursor = response["nextCursor"] as? String ?? page?["nextCursor"] as? String
            guard let cursor, visited.insert(cursor).inserted else { break }
        } while cursor != nil

        if let since {
            return matches.min { ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture) }
        }
        return matches.max { ($0.lastActiveAt ?? .distantPast) < ($1.lastActiveAt ?? .distantPast) }
    }
}

@MainActor
final class CodexAppServerStatusObserver {
    private let session: Session
    private let rpc: any ProviderRPCServing
    private let endpoint: String
    private let continuation: AsyncStream<SessionStatusObservation>.Continuation
    let observationStream: AsyncStream<SessionStatusObservation>
    private var task: Task<Void, Never>?
    private var connected = false
    private var threadID: String?
    private var lastObservation: SessionStatusObservation?
    var onThreadID: ((String) -> Void)?

    init(session: Session, endpoint: String, rpc: any ProviderRPCServing = ProviderRPC()) {
        self.session = session
        self.endpoint = endpoint
        self.rpc = rpc
        var streamContinuation: AsyncStream<SessionStatusObservation>.Continuation!
        observationStream = AsyncStream { streamContinuation = $0 }
        continuation = streamContinuation
        threadID = session.agentSessionID
        rpc.onMessage = { [weak self] in self?.receive($0) }
        rpc.onDisconnect = { [weak self] in self?.connected = false }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        rpc.close()
        continuation.finish()
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                if !connected {
                    try await rpc.connect(socketPath: endpoint)
                    connected = true
                }
                if threadID == nil,
                   let found = try await CodexAppServerAccess.latestSession(
                    using: rpc,
                    workingDirectory: session.workingDirectory,
                    since: session.createdAt
                   ) {
                    threadID = found.id
                    onThreadID?(found.id)
                }
                guard let threadID else {
                    try await Task.sleep(for: .seconds(2))
                    continue
                }
                let response = try await rpc.request("thread/resume", params: [
                    "threadId": threadID,
                    "excludeTurns": true
                ])
                if let thread = response["thread"] as? [String: Any],
                   let status = thread["status"] as? [String: Any] {
                    emit(status, initial: true)
                }
                while connected && !Task.isCancelled {
                    try await Task.sleep(for: .seconds(1))
                }
            } catch {
                connected = false
            }
            rpc.close()
            guard !Task.isCancelled else { break }
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func receive(_ message: [String: Any]) {
        guard message["method"] as? String == "thread/status/changed",
              let params = message["params"] as? [String: Any],
              params["threadId"] as? String == threadID,
              let status = params["status"] as? [String: Any]
        else { return }
        emit(status, initial: false)
    }

    private func emit(_ status: [String: Any], initial: Bool) {
        guard let type = status["type"] as? String else { return }
        let observation: SessionStatusObservation
        switch type {
        case "active":
            let flags = Set(status["activeFlags"] as? [String] ?? [])
            if flags.contains("waitingOnApproval") {
                observation = SessionStatusObservation(.waitingForInput, waitingReason: .permission, cause: "thread/status/changed waitingOnApproval")
            } else if flags.contains("waitingOnUserInput") {
                observation = SessionStatusObservation(.waitingForInput, waitingReason: .question, cause: "thread/status/changed waitingOnUserInput")
            } else {
                observation = SessionStatusObservation(.working, cause: "thread/status/changed active")
            }
        case "idle":
            // Loading a never-used thread also reports idle; that is not a
            // completed turn and must not move its new Flotilla card.
            if initial && session.status == nil { return }
            observation = SessionStatusObservation(.readyForReview, cause: "thread/status/changed idle")
        case "systemError":
            observation = SessionStatusObservation(.readyForReview, cause: "thread/status/changed systemError")
        default:
            return
        }
        guard observation != lastObservation else { return }
        lastObservation = observation
        continuation.yield(observation)
    }
}
