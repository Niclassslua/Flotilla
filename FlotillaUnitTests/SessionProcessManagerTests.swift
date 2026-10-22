import XCTest
import SessionKit
import ProcessKit
import GitKit
import PersistenceKit
import SettingsKit
import TerminalKit
import HooksKit
@testable import Flotilla

@MainActor
final class SessionProcessManagerTests: XCTestCase {
    private func session(id: UUID = UUID()) -> Session {
        Session(
            id: id,
            title: "Repair build",
            goal: "Resolve every compiler error",
            agent: .codexCLI,
            projectID: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp")
        )
    }

    func testStartUsesInjectedFactoryConfiguredArgumentsAndDeliversGoal() throws {
        let factory = RecordingProcessFactory()
        var settings = AppSettings()
        settings.agentOverrides.arguments["codexCLI"] = ["--profile", "careful"]
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            settingsProvider: { settings },
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
        )

        let model = session()
        let process = try manager.start(session: model)
        let mock = try XCTUnwrap(process as? MockPTYProcess)

        XCTAssertEqual(mock.startedExecutable?.path, "/usr/bin/env")
        XCTAssertEqual(
            Array(mock.startedArguments.prefix(3)),
            ["--profile", "careful", "Resolve every compiler error"]
        )
        XCTAssertTrue(mock.startedArguments.contains("features.hooks=true"))
        for event in ["PermissionRequest", "PostToolUse", "Stop"] {
            XCTAssertTrue(mock.startedArguments.contains { $0.hasPrefix("hooks.\(event)=") })
        }
        XCTAssertEqual(
            mock.startedEnvironment[HookConfigurationWriter.eventFileEnvironmentKey],
            HookConfigurationWriter.eventFilePath(
                for: model.id,
                supportDirectory: TmuxSessionWrapping.defaultSupportDirectory()
            ).path
        )
        XCTAssertEqual(mock.startedWorkingDirectory, model.workingDirectory)
        XCTAssertTrue(mock.sentInput.isEmpty)
    }

    func testClaudeLaunchPassesSessionTitleAsName() throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
        )
        var model = session()
        model.agent = .claudeCode
        model.title = "Fix the beacon"

        let process = try manager.start(session: model)
        let mock = try XCTUnwrap(process as? MockPTYProcess)
        let pairs = zip(mock.startedArguments, mock.startedArguments.dropFirst())
        XCTAssertTrue(
            pairs.contains { $0.0 == "--name" && $0.1 == "Fix the beacon" },
            "Claude launch must pass --name with the session title; got \(mock.startedArguments)"
        )
    }

    func testHookInstallFailureSurfacesViaEvent() throws {
        let factory = RecordingProcessFactory()
        let support = FileManager.default.temporaryDirectory
            .appendingPathComponent("hooks-fail-\(UUID().uuidString)", isDirectory: true)
        // A file where a directory is required makes configureHooks fail closed.
        try Data().write(to: support)
        defer { try? FileManager.default.removeItem(at: support) }

        var events: [SessionProcessManager.SessionProcessEvent] = []
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false),
            hookSupportDirectory: support
        )
        manager.eventHandler = { events.append($0) }

        let model = session()
        _ = try manager.start(session: model)

        XCTAssertTrue(
            events.contains { if case .hooksConfigurationFailed(let id) = $0 { return id == model.id }; return false },
            "failed hook install must surface; got \(events)"
        )
    }

    func testStartDoesNotForwardXcodeInstrumentationToAgentProcess() throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            environmentProvider: {
                [
                    "PATH": "/usr/bin:/bin",
                    "SAFE_VALUE": "kept",
                    "DYLD_INSERT_LIBRARIES": "/Applications/Xcode.app/libViewDebuggerSupport.dylib",
                    "SWIFTUI_VIEW_DEBUG": "1",
                    "GPUTOOLS_CAPTURE_ENABLED": "1",
                    "__XPC_DYLD_LIBRARY_PATH": "/Applications/Xcode.app/Frameworks",
                ]
            },
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )

        let process = try manager.start(session: session())
        let mock = try XCTUnwrap(process as? MockPTYProcess)

        XCTAssertEqual(mock.startedEnvironment["SAFE_VALUE"], "kept")
        XCTAssertNil(mock.startedEnvironment["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(mock.startedEnvironment["SWIFTUI_VIEW_DEBUG"])
        XCTAssertNil(mock.startedEnvironment["GPUTOOLS_CAPTURE_ENABLED"])
        XCTAssertNil(mock.startedEnvironment["__XPC_DYLD_LIBRARY_PATH"])
        XCTAssertTrue(
            zip(mock.startedArguments, mock.startedArguments.dropFirst()).contains { pair in
                pair.0 == "-u" && pair.1 == "DYLD_INSERT_LIBRARIES"
            }
        )
        XCTAssertFalse(
            mock.startedArguments.contains(where: { $0.hasPrefix("DYLD_INSERT_LIBRARIES=") })
        )
    }

    func testTmuxWrappedLaunchUsesRootWorkingDirectoryForOuterProcess() throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )

        let model = session()
        let process = try manager.start(session: model)
        let mock = try XCTUnwrap(process as? MockPTYProcess)

        XCTAssertEqual(mock.startedWorkingDirectory?.path, "/")
    }

    func testMissingAgentFailsTruthfullyWithoutCreatingFallbackProcess() {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: nil,
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )

        XCTAssertThrowsError(try manager.start(session: session())) { error in
            guard case SessionProcessManager.LaunchError.executableNotFound(let agent, let binary, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(agent, .codexCLI)
            XCTAssertEqual(binary, "codex")
        }
        XCTAssertTrue(factory.processes.isEmpty, "missing agents must never silently fall back to a mock terminal")
    }

    func testFactoryStartFailurePropagatesAsAgentLaunchFailure() {
        let factory = RecordingProcessFactory()
        factory.shouldFailToStart = true
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        let model = session()

        XCTAssertThrowsError(try manager.start(session: model)) { error in
            guard case SessionProcessManager.LaunchError.failedToStart(let agent, _) = error else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(agent, .codexCLI)
        }
        XCTAssertFalse(
            manager.isTmuxWrapped(sessionID: model.id),
            "failed start must not leave the session marked tmux-wrapped"
        )
    }

    func testStalePTYExitDoesNotClearIntentionalTerminateForReplacement() async throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        let model = session()
        var terminatedCodes: [Int32] = []
        manager.eventHandler = { event in
            if case let .terminated(_, code) = event {
                terminatedCodes.append(code)
            }
        }

        let first = try XCTUnwrap(try manager.start(session: model, deliverGoal: false) as? MockPTYProcess)
        first.exitOnTerminate = false

        let second = try XCTUnwrap(try manager.reattach(session: model) as? MockPTYProcess)
        XCTAssertFalse(first === second)
        second.exitOnTerminate = false

        // Intentional stop of the replacement — flag is set, but neither exit
        // has landed yet.
        manager.terminate(sessionID: model.id)
        // Stale exit from the superseded client arrives first.
        first.simulateCrash(code: 42)
        // Then the current process exits.
        second.simulateCrash(code: 0)

        try await Task.sleep(for: .milliseconds(80))

        XCTAssertTrue(
            terminatedCodes.isEmpty,
            "stale exit must not clear the intentional flag so the replacement publishes .terminated; got \(terminatedCodes)"
        )
    }

    func testTmuxPlanModeDeliversInitialInputNotBareGoal() async throws {
        let factory = RecordingProcessFactory()
        let deliverer = RecordingTmuxGoalDeliverer()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxGoalDeliverer: deliverer,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        var model = session()
        model.goal = "Refactor database migrations"
        model.startingMode = .plan

        _ = try manager.start(session: model)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, deliverer.deliveries.isEmpty {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(deliverer.deliveries.map(\.goal), ["/plan Refactor database migrations"])
        XCTAssertNotEqual(
            deliverer.deliveries.first?.goal,
            model.goal,
            "tmux must not strip the /plan prefix Codex needs"
        )
    }

    func testDeliverMessageCancelsInFlightGoalDelivery() async throws {
        let factory = RecordingProcessFactory()
        let deliverer = RecordingTmuxGoalDeliverer()
        deliverer.delay = 0.4
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxGoalDeliverer: deliverer,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        var model = session()
        model.goal = "first goal"
        model.startingMode = .plan

        _ = try manager.start(session: model)
        try await Task.sleep(for: .milliseconds(30))
        try await manager.deliverMessage("Review feedback", to: model.id)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, deliverer.deliveries.count < 1 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(deliverer.deliveries.map(\.goal), ["Review feedback"])
    }

    func testTerminateForDeletionRetriesSurvivingTmuxSession() async throws {
        let factory = RecordingProcessFactory()
        let terminator = MockTmuxSessionTerminator()
        let model = session()
        let name = TmuxSessionWrapping.sessionName(for: model.id)
        terminator.stubbedSessions = [name]
        terminator.survivingKillCount = 1
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
            ),
            processFactory: factory,
            tmuxTerminator: terminator,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        _ = try manager.start(session: model, deliverGoal: false)

        manager.terminateForDeletion(sessionID: model.id)

        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, terminator.killedSessions.count < 2 {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertEqual(terminator.killedSessions, [name, name])
        XCTAssertFalse(terminator.stubbedSessions.contains(name))
    }

    func testAntigravityNativeResumeRefusesConversationOwnedByAnotherCLI() {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false),
            conversationOwnershipChecker: StubConversationOwnershipChecker(isActive: true)
        )
        var model = session()
        model.agent = .antigravity
        model.agentSessionID = "conv-123"

        XCTAssertThrowsError(try manager.start(session: model)) { error in
            XCTAssertEqual(
                error as? SessionProcessManager.LaunchError,
                .conversationAlreadyActive(agent: .antigravity, conversationID: "conv-123")
            )
        }
        XCTAssertTrue(factory.processes.isEmpty)
    }

    func testAntigravityReconnectsToItsExistingTmuxPaneWithoutOwnershipConflict() throws {
        let factory = RecordingProcessFactory()
        let terminator = MockTmuxSessionTerminator()
        let sessionID = UUID()
        terminator.stubbedSessions = [TmuxSessionWrapping.sessionName(for: sessionID)]
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/bin/tmux")
            ),
            processFactory: factory,
            tmuxTerminator: terminator,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true),
            conversationOwnershipChecker: StubConversationOwnershipChecker(isActive: true)
        )
        var model = session(id: sessionID)
        model.agent = .antigravity
        model.agentSessionID = "conv-123"

        _ = try manager.start(session: model)

        XCTAssertEqual(factory.processes.count, 1)
        XCTAssertTrue(factory.processes[0].startedArguments.contains("new-session"))
    }

    func testAntigravitySessionStartInvokesWorkspaceTruster() throws {
        final class TrustRecorder: @unchecked Sendable {
            var recorded: [URL] = []
        }
        let recorder = TrustRecorder()
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false),
            antigravityWorkspaceTruster: { url in
                recorder.recorded.append(url)
            }
        )
        var model = session()
        model.agent = .antigravity

        _ = try manager.start(session: model)
        XCTAssertEqual(recorder.recorded, [model.workingDirectory])

        var codexModel = session()
        codexModel.agent = .codexCLI
        _ = try manager.start(session: codexModel)
        XCTAssertEqual(recorder.recorded, [model.workingDirectory], "Non-Antigravity agents should not invoke Antigravity workspace truster")
    }

    func testUnexpectedCrashPublishesExitEventAndExplicitRestartUsesNewProcess() async throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        let model = session()
        let event = expectation(description: "exit event")
        manager.eventHandler = { received in
            XCTAssertEqual(received, .terminated(sessionID: model.id, exitCode: 9))
            event.fulfill()
        }

        let first = try XCTUnwrap(try manager.start(session: model) as? MockPTYProcess)
        first.simulateCrash(code: 9)
        await fulfillment(of: [event], timeout: 1)

        let replacement = try XCTUnwrap(try manager.start(session: model, deliverGoal: false) as? MockPTYProcess)
        XCTAssertFalse(first === replacement)
        XCTAssertTrue(replacement.sentInput.isEmpty, "restart must not replay potentially destructive goals")
    }

    func testReviewDeliveryReturnsOnlyAfterTmuxAcceptsTheMessage() async throws {
        let factory = RecordingProcessFactory()
        let deliverer = RecordingTmuxGoalDeliverer()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxGoalDeliverer: deliverer,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        let model = session()
        _ = try manager.start(session: model, deliverGoal: false)

        try await manager.deliverMessage("Review feedback", to: model.id)

        XCTAssertEqual(deliverer.deliveries.map(\.goal), ["Review feedback"])
        XCTAssertEqual(
            deliverer.deliveries.map(\.sessionName),
            [TmuxSessionWrapping.sessionName(for: model.id)]
        )
    }

    func testReviewDeliveryFailurePropagatesWithoutWritingToRawPTY() async throws {
        let factory = RecordingProcessFactory()
        let deliverer = RecordingTmuxGoalDeliverer()
        deliverer.shouldFail = true
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(
                executable: URL(fileURLWithPath: "/usr/bin/env"),
                tmuxExecutable: URL(fileURLWithPath: "/usr/local/bin/tmux")
            ),
            processFactory: factory,
            tmuxGoalDeliverer: deliverer,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: true)
        )
        let model = session()
        let process = try XCTUnwrap(try manager.start(session: model, deliverGoal: false) as? MockPTYProcess)

        do {
            try await manager.deliverMessage("Review feedback", to: model.id)
            XCTFail("delivery should propagate the tmux failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "tmux rejected the message")
        }
        XCTAssertTrue(process.sentInput.isEmpty, "failed tmux delivery must not pretend a raw PTY write was submitted")
    }

    func testReviewDeliveryRefusesANonTmuxSession() async throws {
        let factory = RecordingProcessFactory()
        let manager = SessionProcessManager(
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false)
        )
        let model = session()
        let process = try XCTUnwrap(try manager.start(session: model, deliverGoal: false) as? MockPTYProcess)

        do {
            try await manager.deliverMessage("Review feedback", to: model.id)
            XCTFail("raw PTY delivery is not a reliable submission path")
        } catch {
            XCTAssertEqual(
                error as? SessionProcessManager.MessageDeliveryError,
                .reliableTransportUnavailable
            )
        }
        XCTAssertTrue(process.sentInput.isEmpty)
    }
}
