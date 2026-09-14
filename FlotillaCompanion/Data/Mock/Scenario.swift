import Foundation
import SessionKit
import TranscriptKit

/// A scripted situation from `Ideas/mobile-companion/prototype.md`. Run from
/// the debug menu or at launch with `-scenario <rawValue>`.
enum Scenario: String, CaseIterable, Identifiable, Sendable {
    case permission
    case permissionAnsweredOnMac
    case lateAnswer
    case stackedPermissions
    case question
    case multiQuestion
    case planClaude
    case planCodex
    case needsTerminal
    case streamingClaude
    case streamingCodex
    case streamingOpenCode
    case streamingAntigravity
    case queuedPrompt
    case longToolCall
    case retryThenFail
    case slowStop
    case crash
    case readyForReview
    case macUnreachable

    var id: String { rawValue }

    var title: String {
        switch self {
        case .permission: "Permission"
        case .permissionAnsweredOnMac: "Permission answered on Mac"
        case .lateAnswer: "Late answer from phone"
        case .stackedPermissions: "Three subagent permissions"
        case .question: "Single question"
        case .multiQuestion: "Multi-question with multi-select"
        case .planClaude: "Plan · Claude Code (mode split)"
        case .planCodex: "Plan · Codex"
        case .needsTerminal: "Needs the terminal"
        case .streamingClaude: "Streaming · lines (Claude Code)"
        case .streamingCodex: "Streaming · tokens (Codex)"
        case .streamingOpenCode: "Streaming · tokens (OpenCode)"
        case .streamingAntigravity: "Streaming · terminal tail (Antigravity)"
        case .queuedPrompt: "Prompt queued while busy"
        case .longToolCall: "Long-running tool call"
        case .retryThenFail: "Retrying, then quota failure"
        case .slowStop: "Slow Stop"
        case .crash: "Session crashes"
        case .readyForReview: "Becomes ready for review"
        case .macUnreachable: "Mac goes unreachable and back"
        }
    }
}

/// Where a scenario wants the app to land.
struct ScenarioFocus {
    var macID: MacHost.ID
    var sessionID: CompanionSession.ID?
}

extension MockCompanionDataSource {
    /// Sets up `scenario` and starts its timeline. Returns where to navigate.
    func run(_ scenario: Scenario) -> ScenarioFocus {
        let mac = MockFixtures.MacID.studio
        switch scenario {
        case .permission, .permissionAnsweredOnMac, .lateAnswer:
            let id = makeSession("Clean build artifacts", agent: .claudeCode) { t in
                t.user("The build folder is stale. Clear it and rebuild.")
                t.assistant("I'll remove `build/` and run a clean build.")
            }
            startTurn(id) { source in
                try await source.pause(1.2)
                let interaction = source.raisePermission(
                    PermissionRequest(tool: "Bash", summary: "rm -rf build", detail: "rm -rf build", pattern: "rm *"),
                    output: "Removed build/",
                    in: id
                )
                if scenario == .lateAnswer {
                    source.answeredOnMacPendingRetraction.insert(interaction.id)
                    try await source.pause(12)
                    await source.answerOnMac(interaction.id, in: id, outcome: "Allowed")
                } else if scenario == .permissionAnsweredOnMac {
                    try await source.pause(4)
                    await source.answerOnMac(interaction.id, in: id, outcome: "Allowed")
                }
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .stackedPermissions:
            let id = makeSession("Audit package licences", agent: .claudeCode) { t in
                t.user("Check every dependency's licence, one subagent per package manager.")
                t.assistant("Starting three subagents in parallel.")
            }
            startTurn(id) { source in
                let requests: [(String, PermissionRequest)] = [
                    ("general", PermissionRequest(tool: "Bash", summary: "swift package show-dependencies --format json", pattern: "swift package *")),
                    ("Explore", PermissionRequest(tool: "WebFetch", summary: "https://spdx.org/licenses/", pattern: "spdx.org")),
                    ("general", PermissionRequest(tool: "Bash", summary: "npm ls --all --json", pattern: "npm ls *")),
                ]
                for (subagent, request) in requests {
                    try await source.pause(0.6)
                    source.raisePermission(request, output: "Done", subagent: subagent, in: id)
                }
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .question, .multiQuestion:
            let id = makeSession("Add token refresh", agent: .openCode) { t in
                t.user("Add token refresh to the API client.")
                t.assistant("I need a decision before I start.")
            }
            let steps = scenario == .question ? [MockFixtures.sampleQuestions[0]] : MockFixtures.sampleQuestions
            startTurn(id) { source in
                try await source.pause(1)
                source.raise(PendingInteraction(kind: .question(steps)), in: id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .planClaude, .planCodex:
            let id = makeSession("Move settings to SQLite", agent: scenario == .planClaude ? .claudeCode : .codexCLI) { t in
                t.user("Plan how to move settings out of UserDefaults.")
            }
            startTurn(id) { source in
                try await source.runTool("Grep", ["pattern": "UserDefaults.standard"], output: "11 matches", seconds: 1, in: id)
                source.raise(PendingInteraction(kind: .plan(MockFixtures.samplePlan)), in: id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .needsTerminal:
            let id = makeSession("Explore new repository", agent: .claudeCode) { t in
                t.user("Get familiar with this repository.")
            }
            startTurn(id) { source in
                try await source.pause(1)
                let interaction = PendingInteraction(kind: .needsTerminal(dialogTitle: "Trust this folder?"))
                source.raise(interaction, in: id)
                try await source.pause(8)
                await source.answerOnMac(interaction.id, in: id, outcome: "Trusted")
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .streamingClaude, .streamingCodex, .streamingOpenCode, .streamingAntigravity:
            let agent: AgentKind = switch scenario {
            case .streamingCodex: .codexCLI
            case .streamingOpenCode: .openCode
            case .streamingAntigravity: .antigravity
            default: .claudeCode
            }
            let id = makeSession("Explain the offline banner", agent: agent) { t in
                t.user("Summarise what changed for the unreachable state.")
            }
            startTurn(id) { source in
                try await source.pause(0.8)
                try await source.streamReply(MockFixtures.sampleReply, in: id)
                try await source.finishTurn(id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .queuedPrompt:
            let id = makeSession("Run the full test suite", agent: .claudeCode) { t in
                t.user("Run the whole test suite and fix anything that fails.")
            }
            startTurn(id) { source in
                async let run: Void = source.runTool("Bash", ["command": "make test"], output: "Executed 412 tests, 0 failures", seconds: 6, in: id)
                try await source.pause(1.5)
                source.mutateTranscript(id) { $0.queuedPrompts.append(QueuedPrompt(text: "Also update the CHANGELOG when you're done.", sentAt: .now)) }
                try await run
                try await source.streamReply("All 412 tests pass.", in: id)
                try await source.finishTurn(id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .longToolCall, .slowStop:
            let id = makeSession("Run end-to-end tests", agent: .codexCLI) { t in
                t.user("Run the end-to-end tests against staging.")
            }
            if scenario == .slowStop { stopDelay = .seconds(4) }
            let useID = UUID().uuidString
            mutateTranscript(id) {
                $0.append(.toolUse(id: useID, tool: "shell", input: MockFixtures.json(["command": "npm test"]), timestamp: .now.addingTimeInterval(-42)))
            }
            startTurn(id) { source in
                try await source.pause(20)
                source.mutateTranscript(id) { $0.append(.toolResult(toolUseID: useID, output: "118 passing", isError: false, timestamp: .now)) }
                try await source.streamReply("All 118 end-to-end tests pass against staging.", in: id)
                try await source.finishTurn(id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .retryThenFail:
            let id = makeSession("Summarise open pull requests", agent: .antigravity) { t in
                t.user("Summarise every open pull request.")
            }
            startTurn(id) { source in
                for attempt in 1...3 {
                    try await source.pause(1.5)
                    source.mutateTranscript(id) { $0.retryAttempt = attempt }
                }
                try await source.pause(2)
                source.mutateTranscript(id) {
                    $0.retryAttempt = nil
                    $0.append(.turnFailed(message: "Turn failed · quota exceeded"))
                }
                source.mutateSession(id) {
                    $0.failure = "quota exceeded"
                    $0.status = .readyForReview
                    $0.reviewAcknowledged = true
                }
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .crash:
            let id = makeSession("Regenerate API client", agent: .codexCLI) { t in
                t.user("Regenerate the API client from the OpenAPI spec.")
            }
            startTurn(id) { source in
                try await source.runTool("shell", ["command": "openapi-generator generate -i spec.yaml"], output: "Generating 214 files…", seconds: 2, in: id)
                try await source.pause(1)
                source.mutateSession(id) {
                    $0.status = .crashed
                    $0.crashReason = "Process exited with code 1"
                    $0.isProcessLive = false
                }
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .readyForReview:
            let id = makeSession("Tighten fleet row spacing", agent: .claudeCode) { t in
                t.user("Rows feel loose on the phone. Tighten them.")
            }
            diffs[id] = MockFixtures.sampleDiff
            commitsBySession[id] = MockFixtures.sampleCommits(now: .now)
            startTurn(id) { source in
                try await source.runTool("Edit", ["file_path": "FlotillaCompanion/Features/Fleet/FleetView.swift"], output: "Applied", seconds: 1.5, in: id)
                try await source.streamReply("Rows are 6 pt tighter and still clear the 44 pt touch target.", in: id)
                try await source.finishTurn(id)
            }
            return ScenarioFocus(macID: mac, sessionID: id)

        case .macUnreachable:
            Task {
                try? await Task.sleep(for: .seconds(2))
                setReachable(false, macID: mac)
                try? await Task.sleep(for: .seconds(10))
                setReachable(true, macID: mac)
            }
            return ScenarioFocus(macID: mac, sessionID: nil)
        }
    }

    @discardableResult
    func raisePermission(
        _ request: PermissionRequest,
        output: String,
        subagent: String? = nil,
        in sessionID: CompanionSession.ID
    ) -> PendingInteraction {
        let useID = UUID().uuidString
        mutateTranscript(sessionID) {
            $0.append(.toolUse(id: useID, tool: request.tool, input: MockFixtures.json(["command": request.summary]), timestamp: .now))
        }
        let interaction = PendingInteraction(kind: .permission(request), subagent: subagent)
        gatedToolCalls[interaction.id] = (useID, output)
        raise(interaction, in: sessionID)
        return interaction
    }

    private func makeSession(
        _ title: String,
        agent: AgentKind,
        _ build: (inout TranscriptBuilder) -> Void
    ) -> CompanionSession.ID {
        let catalog = AgentCatalog.fallback.entry(for: agent)
        let session = CompanionSession(
            id: UUID(),
            title: title,
            agent: agent,
            model: catalog.defaultModel,
            effort: catalog.defaultEffort,
            status: .working,
            projectID: MockFixtures.ProjectID.flotilla,
            branch: "flotilla/" + Self.slug(from: title),
            hasWorktree: true,
            isProcessLive: true,
            updatedAt: .now
        )
        sessionsByMac[MockFixtures.MacID.studio, default: []].insert(session, at: 0)
        transcripts[session.id] = TranscriptBuilder(start: .now.addingTimeInterval(-120), build).transcript
        return session.id
    }
}
