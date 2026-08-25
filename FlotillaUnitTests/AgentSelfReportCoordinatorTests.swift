import XCTest
import SessionKit
import AgentKit
@testable import Flotilla

final class AgentSelfReportCoordinatorTests: XCTestCase {

    func testDescriptorPathIsDeterministic() {
        let sessionID = UUID()
        let supportDir = URL(fileURLWithPath: "/tmp/flotilla-support")
        let path = AgentSelfReportCoordinator.descriptorPath(for: sessionID, supportDirectory: supportDir)

        XCTAssertEqual(
            path.path,
            "/tmp/flotilla-support/self-report/\(sessionID.uuidString).json"
        )
    }

    func testClearDescriptorRemovesExistingFile() throws {
        let sessionID = UUID()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-test-\(UUID().uuidString)")
        let selfReportDir = tempDir.appendingPathComponent("self-report", isDirectory: true)
        try FileManager.default.createDirectory(at: selfReportDir, withIntermediateDirectories: true)

        let descPath = AgentSelfReportCoordinator.descriptorPath(for: sessionID, supportDirectory: tempDir)
        try Data("{}".utf8).write(to: descPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: descPath.path))

        AgentSelfReportCoordinator.clearDescriptor(for: sessionID, supportDirectory: tempDir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: descPath.path))
    }

    func testWaitForDescriptorReturnsDecodedData() async throws {
        let sessionID = UUID()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-test-\(UUID().uuidString)")
        let selfReportDir = tempDir.appendingPathComponent("self-report", isDirectory: true)
        try FileManager.default.createDirectory(at: selfReportDir, withIntermediateDirectories: true)

        let descPath = AgentSelfReportCoordinator.descriptorPath(for: sessionID, supportDirectory: tempDir)

        Task {
            try? await Task.sleep(for: .milliseconds(50))
            let descriptor = AgentSelfReportDescriptor(
                title: "Agent Chosen Title",
                branch: "flotilla/agent-branch",
                worktreePath: "/tmp/worktrees/agent-branch"
            )
            let data = try! JSONEncoder().encode(descriptor)
            try? data.write(to: descPath)
        }

        let result = await AgentSelfReportCoordinator.waitForDescriptor(
            sessionID: sessionID,
            supportDirectory: tempDir,
            timeout: .seconds(2)
        )

        let unwrapped = try XCTUnwrap(result)
        XCTAssertEqual(unwrapped.title, "Agent Chosen Title")
        XCTAssertEqual(unwrapped.branch, "flotilla/agent-branch")
        XCTAssertEqual(unwrapped.worktreePath, "/tmp/worktrees/agent-branch")
    }

    func testWaitForDescriptorTimesOutWhenNoFileWritten() async {
        let sessionID = UUID()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("flotilla-test-\(UUID().uuidString)")

        let result = await AgentSelfReportCoordinator.waitForDescriptor(
            sessionID: sessionID,
            supportDirectory: tempDir,
            timeout: .milliseconds(200)
        )

        XCTAssertNil(result)
    }

    func testInstructionsCompositionBothDisabledReturnsEmpty() {
        let instructions = AgentSelfReportCoordinator.instructions(
            wantsTitle: false,
            wantsWorktree: false,
            descriptorPath: URL(fileURLWithPath: "/tmp/desc.json"),
            projectRoot: URL(fileURLWithPath: "/tmp/repo"),
            worktreeBaseDirectory: URL(fileURLWithPath: "/tmp/worktrees")
        )
        XCTAssertTrue(instructions.isEmpty)
    }

    func testInstructionsCompositionTitleOnly() {
        let descPath = URL(fileURLWithPath: "/tmp/desc.json")
        let instructions = AgentSelfReportCoordinator.instructions(
            wantsTitle: true,
            wantsWorktree: false,
            descriptorPath: descPath,
            projectRoot: nil,
            worktreeBaseDirectory: nil
        )

        XCTAssertTrue(instructions.contains("Choose a concise 2–5 word noun-phrase title"))
        XCTAssertFalse(instructions.contains("Create an isolated git worktree"))
        XCTAssertTrue(instructions.contains("\"title\": \"...\""))
        XCTAssertFalse(instructions.contains("\"branch\""))
        XCTAssertFalse(instructions.contains("\"worktreePath\""))
        XCTAssertTrue(instructions.contains(descPath.path))
    }

    func testInstructionsCompositionWorktreeOnly() {
        let descPath = URL(fileURLWithPath: "/tmp/desc.json")
        let repoPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreeBase = URL(fileURLWithPath: "/tmp/worktrees")
        let instructions = AgentSelfReportCoordinator.instructions(
            wantsTitle: false,
            wantsWorktree: true,
            descriptorPath: descPath,
            projectRoot: repoPath,
            worktreeBaseDirectory: worktreeBase
        )

        XCTAssertFalse(instructions.contains("Choose a concise 2–5 word noun-phrase title"))
        XCTAssertTrue(instructions.contains("Create an isolated git worktree"))
        XCTAssertTrue(instructions.contains(repoPath.path))
        XCTAssertTrue(instructions.contains(worktreeBase.path))
        XCTAssertFalse(instructions.contains("\"title\""))
        XCTAssertTrue(instructions.contains("\"branch\": \"flotilla/<slug>\""))
        XCTAssertTrue(instructions.contains("\"worktreePath\": \"\(worktreeBase.path)/<slug>\""))
        XCTAssertTrue(instructions.contains(descPath.path))
    }

    func testInstructionsCompositionBothEnabled() {
        let descPath = URL(fileURLWithPath: "/tmp/desc.json")
        let repoPath = URL(fileURLWithPath: "/tmp/repo")
        let worktreeBase = URL(fileURLWithPath: "/tmp/worktrees")
        let instructions = AgentSelfReportCoordinator.instructions(
            wantsTitle: true,
            wantsWorktree: true,
            descriptorPath: descPath,
            projectRoot: repoPath,
            worktreeBaseDirectory: worktreeBase
        )

        XCTAssertTrue(instructions.contains("Choose a concise 2–5 word noun-phrase title"))
        XCTAssertTrue(instructions.contains("Create an isolated git worktree"))
        XCTAssertTrue(instructions.contains("\"title\": \"...\""))
        XCTAssertTrue(instructions.contains("\"branch\": \"flotilla/<slug>\""))
        XCTAssertTrue(instructions.contains("\"worktreePath\": \"\(worktreeBase.path)/<slug>\""))
        XCTAssertTrue(instructions.contains(descPath.path))
    }
}
