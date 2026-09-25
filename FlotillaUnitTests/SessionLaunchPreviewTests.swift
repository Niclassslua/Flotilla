import XCTest
import SessionKit
@testable import Flotilla

/// `SessionLaunchPreview` is what the launcher promises the user *before* a
/// session exists. These tests pin it to the same `BranchNaming` /
/// `WorktreePlanner` behaviour `AppStore.createSession` uses, so the preview
/// cannot quietly drift from what actually happens.
final class SessionLaunchPreviewTests: XCTestCase {
    private let worktreeBase = URL(fileURLWithPath: "/tmp/flotilla-worktrees", isDirectory: true)
    private let generalDirectory = URL(fileURLWithPath: "/tmp/flotilla-general", isDirectory: true)
    private let projectRoot = URL(fileURLWithPath: "/Users/dev/Repos/flotilla", isDirectory: true)

    private func resolve(
        goal: String,
        choice: ProjectChoice,
        agent: AgentKind = .claudeCode,
        model: String? = nil,
        effort: AgentEffort? = nil,
        createWorktree: Bool
    ) -> SessionLaunchPreview {
        SessionLaunchPreview.resolve(
            goal: goal,
            projectChoice: choice,
            agent: agent,
            model: model,
            effort: effort,
            createWorktree: createWorktree,
            worktreeBaseDirectory: worktreeBase,
            generalSessionDirectory: generalDirectory
        )
    }

    private func project(named name: String = "flotilla") -> Project {
        Project(name: name, rootPath: projectRoot)
    }

    func testWorkingDirectoryAndBranchForEachDestination() {
        let general = resolve(goal: "Look something up", choice: .general, createWorktree: true)
        XCTAssertNil(general.branchSlug)
        XCTAssertFalse(general.isWorktree)
        XCTAssertEqual(general.workingDirectory, generalDirectory)
        XCTAssertNil(general.sharedCheckoutWarning)

        let shared = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: false)
        XCTAssertNil(shared.branchSlug)
        XCTAssertEqual(shared.workingDirectory, projectRoot)
        XCTAssertNotNil(shared.sharedCheckoutWarning, "A shared checkout must state that concurrent sessions can conflict")

        let worktree = resolve(goal: "Dark mode", choice: .known(project()), createWorktree: true)
        XCTAssertTrue(worktree.isWorktree)
        XCTAssertTrue(
            worktree.workingDirectory.path.hasPrefix(worktreeBase.path),
            "Expected \(worktree.workingDirectory.path) under \(worktreeBase.path)"
        )
        XCTAssertNil(worktree.sharedCheckoutWarning)
        XCTAssertEqual(worktree.branchSlug, "dark-mode")

        let folder = URL(fileURLWithPath: "/Users/dev/Scratch/spike", isDirectory: true)
        let custom = resolve(goal: "", choice: .custom(folder), createWorktree: false)
        XCTAssertEqual(custom.workingDirectory, folder)
        XCTAssertEqual(custom.title, "spike", "An empty goal falls back to the folder name")
    }

    func testTitleDerivation() {
        let long = resolve(goal: String(repeating: "a", count: 120), choice: .general, createWorktree: false)
        XCTAssertEqual(long.title.count, 60)

        let multiline = resolve(
            goal: "First line of objective\nSecond line with details\nThird line",
            choice: .general,
            createWorktree: false
        )
        XCTAssertEqual(multiline.title, "First line of objective")

        XCTAssertEqual(
            resolve(goal: "   ", choice: .known(project(named: "Atlas")), createWorktree: false).title,
            "Atlas"
        )
        XCTAssertEqual(
            resolve(goal: "", choice: .general, createWorktree: false).title,
            "General session"
        )
    }

    func testCommandIncludesModelAndOmitsUnsupportedEffort() {
        let withEffort = resolve(
            goal: "Anything",
            choice: .general,
            agent: .claudeCode,
            model: "opus",
            effort: .high,
            createWorktree: false
        )
        XCTAssertTrue(withEffort.command.hasPrefix("claude "))
        XCTAssertTrue(withEffort.command.contains("opus"), withEffort.command)
        XCTAssertTrue(withEffort.command.contains("high"), withEffort.command)

        let openCode = resolve(
            goal: "Anything",
            choice: .general,
            agent: .openCode,
            effort: .high,
            createWorktree: false
        )
        XCTAssertFalse(
            openCode.command.contains("high"),
            "OpenCode exposes no effort knob — \(openCode.command) must not imply one"
        )
    }
}
