import Foundation
import AgentKit
import SessionKit
import ProcessKit
import SettingsKit

/// Owns the live `PTYProcessProtocol` for every session that has been
/// started, keyed by session id. Sessions keep running here across sidebar
/// selection changes — Phase 7's terminal view just attaches to whatever
/// is already running rather than owning process lifecycle itself.
@MainActor
final class SessionProcessManager {
    private var processes: [UUID: PTYProcessProtocol] = [:]
    private let locator: ExecutableLocating
    private let processFactory: any PTYProcessCreating
    private let providers: AgentProviderRegistry
    private let settingsProvider: () -> AppSettings
    private var intentionallyTerminating = Set<UUID>()
    var eventHandler: ((SessionProcessEvent) -> Void)?

    enum SessionProcessEvent: Equatable {
        case terminated(sessionID: UUID, exitCode: Int32)
    }

    enum LaunchError: LocalizedError, Equatable {
        case executableNotFound(agent: AgentKind, binary: String, configuredPath: String)
        case failedToStart(agent: AgentKind, message: String)

        var errorDescription: String? {
            switch self {
            case let .executableNotFound(agent, binary, configuredPath):
                if configuredPath.isEmpty {
                    return "\(agent.displayName) was not found. Install ‘\(binary)’ or choose its executable in Settings."
                }
                return "\(agent.displayName) is not executable at \(configuredPath). Choose a valid binary in Settings."
            case let .failedToStart(agent, message):
                return "\(agent.displayName) could not start: \(message)"
            }
        }
    }

    init(
        locator: ExecutableLocating = PATHExecutableLocator(),
        processFactory: any PTYProcessCreating = SystemPTYProcessFactory(),
        providers: AgentProviderRegistry = AgentProviderRegistry(),
        settingsProvider: @escaping () -> AppSettings = { AppSettings() }
    ) {
        self.locator = locator
        self.processFactory = processFactory
        self.providers = providers
        self.settingsProvider = settingsProvider
    }

    func process(for sessionID: UUID) -> PTYProcessProtocol? {
        processes[sessionID]
    }

    @discardableResult
    func start(session: Session, deliverGoal: Bool = true) throws -> PTYProcessProtocol {
        if let existing = processes[session.id], existing.isRunning {
            return existing
        }

        // A previous, caller-initiated termination may have completed before
        // its callback reached the main actor. A replacement process is a new
        // lifecycle and its eventual exit must never inherit that suppression.
        intentionallyTerminating.remove(session.id)

        let provider = providers.provider(for: session.agent)
        let settings = settingsProvider()
        let plan = provider.launchPlan(
            goal: deliverGoal ? session.goal : nil,
            settings: settings,
            baseEnvironment: ProcessInfo.processInfo.environment
        )
        guard let executable = resolveExecutable(plan: plan) else {
            throw LaunchError.executableNotFound(
                agent: session.agent,
                binary: plan.binaryName,
                configuredPath: plan.configuredPath
            )
        }

        let process = processFactory.makeProcess()
        let size = PTYSize(cols: 80, rows: 24)
        process.terminationHandler = { [weak self] exitCode in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processes[session.id] = nil
                if self.intentionallyTerminating.remove(session.id) == nil {
                    self.eventHandler?(.terminated(sessionID: session.id, exitCode: exitCode))
                }
            }
        }

        do {
            try process.start(
                executable: executable,
                arguments: plan.arguments,
                environment: plan.environment,
                workingDirectory: session.workingDirectory,
                initialSize: size
            )
        } catch {
            throw LaunchError.failedToStart(agent: session.agent, message: error.localizedDescription)
        }

        processes[session.id] = process
        if let initialInput = plan.initialInput {
            process.send(input: initialInput)
        }
        return process
    }

    private func resolveExecutable(plan: AgentLaunchPlan) -> URL? {
        if !plan.configuredPath.isEmpty,
           FileManager.default.isExecutableFile(atPath: plan.configuredPath) {
            return URL(fileURLWithPath: plan.configuredPath)
        }
        return locator.locate(plan.binaryName)
    }

    func terminate(sessionID: UUID) {
        if let process = processes[sessionID], process.isRunning {
            intentionallyTerminating.insert(sessionID)
            process.terminate()
        } else {
            intentionallyTerminating.remove(sessionID)
        }
        processes[sessionID] = nil
    }
}
