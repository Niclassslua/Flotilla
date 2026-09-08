import Foundation
import AgentKit
import SessionKit
import TranscriptKit

/// Owns background work for a session run; metadata is applied by AppStore.
@MainActor
final class SessionMetadataMonitor {
    struct Timing: Sendable {
        let burstDelays: [Duration]
        let steadyInterval: Duration
        let giveUpAfter: Duration
        let fallbackAfter: Duration
        let pollChunk: Duration

        init(
            burstDelays: [Duration] = [.seconds(1), .milliseconds(2500), .seconds(5), .seconds(9), .seconds(15), .seconds(25)],
            steadyInterval: Duration = .seconds(20),
            giveUpAfter: Duration = .seconds(1800),
            fallbackAfter: Duration = .seconds(180),
            pollChunk: Duration = .seconds(20)
        ) {
            self.burstDelays = burstDelays
            self.steadyInterval = steadyInterval
            self.giveUpAfter = giveUpAfter
            self.fallbackAfter = fallbackAfter
            self.pollChunk = pollChunk
        }
    }

    struct Dependencies {
        var discover: @MainActor (Session) async -> DiscoveredAgentSession? = { session in
            if let found = await AgentSessionProviderRegistry.default.fetchLatestSession(
                for: session.agent,
                workingDirectory: session.workingDirectory,
                since: session.createdAt.addingTimeInterval(-30)
            ) {
                return found
            }

            // The providers answer from each agent's own catalog, which can lag
            // the conversation or omit it entirely — Antigravity registers one
            // only once it has titled it, and records no working directory at
            // all, so a session that has plainly been used stays undiscovered.
            //
            // The transcript on disk is the earlier and more reliable evidence.
            // It yields only an id (no title, no cwd), which is exactly what is
            // needed: without it the session cannot be resumed after a relaunch
            // and cannot be handed off. `AppStore` already declines to apply an
            // empty title.
            guard let reader = TranscriptCodecRegistry.flotilla().reader(for: session.agent),
                  let discovered = try? reader.discoverSession(
                      workingDirectory: session.workingDirectory,
                      since: session.createdAt.addingTimeInterval(-30)
                  )
            else { return nil }

            return DiscoveredAgentSession(
                id: discovered.sessionID,
                title: "",
                workingDirectory: session.workingDirectory,
                lastActiveAt: nil,
                agent: session.agent
            )
        }
        var readDescriptor: @MainActor (URL, Duration) async -> AgentSelfReportDescriptor? = { path, timeout in
            await AgentSelfReportCoordinator.waitForDescriptor(at: path, timeout: timeout)
        }
    }

    private let timing: Timing
    private let dependencies: Dependencies
    private var discoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var descriptorTasks: [UUID: Task<Void, Never>] = [:]
    private var generations: [UUID: UUID] = [:]

    init(timing: Timing = Timing(), dependencies: Dependencies = Dependencies()) {
        self.timing = timing
        self.dependencies = dependencies
    }

    deinit {
        for task in discoveryTasks.values { task.cancel() }
        for task in descriptorTasks.values { task.cancel() }
    }

    func generation(for id: UUID) -> UUID {
        if let generation = generations[id] { return generation }
        let generation = UUID()
        generations[id] = generation
        return generation
    }

    func isCurrent(_ generation: UUID, for id: UUID) -> Bool {
        !Task.isCancelled && generations[id] == generation
    }

    func discover(_ session: Session) async -> DiscoveredAgentSession? {
        await dependencies.discover(session)
    }

    func startDiscovery(for id: UUID, isActive: @escaping @MainActor () -> Bool,
                        refresh: @escaping @MainActor () async -> Void) {
        discoveryTasks[id]?.cancel()
        let timing = timing
        discoveryTasks[id] = Task {
            var elapsed: Duration = .zero
            var burstIndex = 0
            while elapsed < timing.giveUpAfter {
                let delay = burstIndex < timing.burstDelays.count
                    ? timing.burstDelays[burstIndex] : timing.steadyInterval
                burstIndex += 1
                do { try await Task.sleep(for: delay) } catch { return }
                elapsed += delay
                guard !Task.isCancelled, isActive() else { return }
                await refresh()
            }
        }
    }

    func startSelfReport(
        for id: UUID, path: URL, wantsWorktree: Bool,
        exists: @escaping @MainActor () -> Bool,
        isActive: @escaping @MainActor () -> Bool,
        fallback: @escaping @MainActor () async -> WorktreeInfo?,
        apply: @escaping @MainActor (AgentSelfReportDescriptor, WorktreeInfo?) async -> Void
    ) {
        descriptorTasks[id]?.cancel()
        let timing = timing
        let read = dependencies.readDescriptor
        descriptorTasks[id] = Task {
            var elapsed: Duration = .zero
            var fallbackWorktree: WorktreeInfo?
            while elapsed < timing.giveUpAfter {
                let descriptor = await read(path, timing.pollChunk)
                guard !Task.isCancelled, exists() else { return }
                if let descriptor {
                    await apply(descriptor, fallbackWorktree)
                    return
                }
                elapsed += timing.pollChunk
                let active = isActive()
                if wantsWorktree, fallbackWorktree == nil, elapsed >= timing.fallbackAfter || !active {
                    fallbackWorktree = await fallback()
                }
                guard !Task.isCancelled, active else { return }
            }
        }
    }

    func cancel(_ id: UUID) {
        generations[id] = nil
        discoveryTasks.removeValue(forKey: id)?.cancel()
        descriptorTasks.removeValue(forKey: id)?.cancel()
    }

    func cancelAll() {
        for task in discoveryTasks.values { task.cancel() }
        for task in descriptorTasks.values { task.cancel() }
        discoveryTasks.removeAll()
        descriptorTasks.removeAll()
        generations.removeAll()
    }
}
