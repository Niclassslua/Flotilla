import AppKit
import XCTest

/// Captures the deterministic UI-testing fixtures used by
/// `docs/ui-vocabulary.md`.
///
/// This is a documentation pipeline rather than a visual-regression test: it
/// deliberately makes no pixel assertions. Each screenshot is kept as an
/// xcresult attachment and written to the UI-test runner's sandbox. The
/// dedicated `UI Vocabulary Screenshots` scheme publishes the completed set to
/// the documentation after the test action succeeds.
@MainActor
final class VocabularyScreenshotUITests: XCTestCase {
    /// The runner's sandbox container, not the developer's real Documents
    /// directory. It is the stable handoff point to the scheme post-action.
    nonisolated private static let outputDirectory: URL = {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("flotilla-vocab-shots", isDirectory: true)
    }()

    /// Only captures consumed by the visual appendix are required for a
    /// publishable run. Additional captures can be added without changing the
    /// publisher contract.
    nonisolated private static let requiredCaptureNames: Set<String> = [
        "01-home-dashboard",
        "07-sessions-focus",
        "10-presentation-grid",
        "11-grid-view",
        "13-presentation-board",
        "15-presentation-focus",
        "20-new-session-command-bar",
        "21-command-palette",
        "22-delete-session-sheet",
        "24-settings-terminal",
        "25-settings-git",
        "26-settings-agents",
        "30-project-overview",
        "34-diff-panel-populated",
        "36-project-git-commits",
        "37-project-files",
        "39-project-skills",
        "41-knowledge-detail",
    ]

    nonisolated(unsafe) private static var capturedNames: Set<String> = []
    nonisolated(unsafe) private static var log: [String] = []

    override class func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: outputDirectory)
        capturedNames = []

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )
            log = ["SCHEMA    1", "OUTPUT    \(outputDirectory.path)"]
        } catch {
            log = ["SCHEMA    1", "UNUSABLE  \(error.localizedDescription)"]
        }
        print("[vocab-shots] \(log.joined(separator: "\n[vocab-shots] "))")
    }

    override class func tearDown() {
        let missing = requiredCaptureNames.subtracting(capturedNames).sorted()
        if missing.isEmpty {
            log.append("COMPLETE  schema=1 captures=\(capturedNames.count)")
        } else {
            log.append("INCOMPLETE missing=\(missing.joined(separator: ","))")
        }

        let manifest = log.joined(separator: "\n") + "\n"
        try? manifest.write(
            to: outputDirectory.appendingPathComponent("manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
        print("[vocab-shots] ==== manifest ====\n\(manifest)")
        super.tearDown()
    }

    override func setUp() {
        super.setUp()
        // A missed surface should not prevent the remaining documentation
        // captures from being attempted in the same run.
        continueAfterFailure = true
    }

    private static func note(_ line: String) {
        log.append(line)
        print("[vocab-shots] \(line)")
    }

    // MARK: - Harness

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TEST_SETTINGS_SECTION"] = "general"
        app.launch()

        let window = app.windows.firstMatch
        if fastWait(window, timeout: 8) {
            let frame = window.frame
            let placement = frame.minX < 1 ? "PRIMARY" : "SECONDARY"
            Self.note(
                "WINDOW    x=\(Int(frame.minX)) y=\(Int(frame.minY)) "
                    + "\(Int(frame.width))x\(Int(frame.height)) \(placement)"
            )
        }
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    /// Lets SwiftUI's short selection and presentation transitions settle.
    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func save(_ screenshot: XCUIScreenshot, named name: String, note: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = Self.outputDirectory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url, options: .atomic)
            Self.capturedNames.insert(name)
            Self.note("OK        \(name).png — \(note)")
        } catch {
            Self.note("ATTACHONLY \(name) — \(note) [\(error.localizedDescription)]")
        }
    }

    private func shootWindow(
        _ app: XCUIApplication,
        _ name: String,
        _ note: String,
        containing identifier: String? = nil
    ) {
        settle()

        if let identifier {
            _ = fastWait(element(app, identifier), timeout: 4)
        }
        let windows = app.windows.allElementsBoundByIndex.filter(\.exists)
        let window: XCUIElement?
        if let identifier {
            window = windows.first {
                $0.descendants(matching: .any)[identifier].firstMatch.exists
            }
        } else {
            window = windows.first
        }

        guard let window else {
            Self.note("NOWINDOW  \(name) — \(note)")
            return
        }
        save(window.screenshot(), named: name, note: note)
    }

    private func shootElement(_ app: XCUIApplication, id: String, _ name: String, _ note: String) {
        guard let target = largestMatch(app, id, timeout: 3) else {
            Self.note("MISSING   \(name) — no element '\(id)' [\(note)]")
            return
        }
        settle(0.3)
        save(target.screenshot(), named: name, note: "\(note) [element \(id)]")
    }

    private func shootElement(_ app: XCUIApplication, id: AXID, _ name: String, _ note: String) {
        shootElement(app, id: id.rawValue, name, note)
    }

    /// SwiftUI can propagate an accessibility identifier to descendants. The
    /// largest match is generally the actual tappable container.
    private func largestMatch(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        guard fastWait(matches.firstMatch, timeout: timeout) else { return nil }
        return matches.allElementsBoundByIndex
            .filter(\.exists)
            .max {
                ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height)
            }
    }

    private func largestMatch(
        _ app: XCUIApplication,
        _ id: AXID,
        timeout: TimeInterval
    ) -> XCUIElement? {
        largestMatch(app, id.rawValue, timeout: timeout)
    }

    @discardableResult
    private func click(
        _ app: XCUIApplication,
        _ identifier: String,
        timeout: TimeInterval = 4
    ) -> Bool {
        guard let target = largestMatch(app, identifier, timeout: timeout) else {
            Self.note("NAVFAIL   could not find '\(identifier)' to click")
            return false
        }
        target.click()
        settle(0.5)
        return true
    }

    @discardableResult
    private func click(
        _ app: XCUIApplication,
        _ id: AXID,
        timeout: TimeInterval = 4
    ) -> Bool {
        click(app, id.rawValue, timeout: timeout)
    }

    /// Falls back to the visible button title because AppKit occasionally
    /// exposes only the label, rather than the SwiftUI identifier, to XCTest.
    @discardableResult
    private func clickButton(
        _ app: XCUIApplication,
        title: String,
        identifier: String,
        timeout: TimeInterval = 4
    ) -> Bool {
        if let target = largestMatch(app, identifier, timeout: timeout) {
            target.click()
            settle(0.5)
            return true
        }

        let button = app.buttons[title].firstMatch
        if fastWait(button, timeout: 2) {
            button.click()
            settle(0.5)
            return true
        }

        Self.note("NAVFAIL   could not find '\(identifier)' or button '\(title)'")
        return false
    }

    @discardableResult
    private func clickButton(
        _ app: XCUIApplication,
        title: String,
        id: AXID,
        timeout: TimeInterval = 4
    ) -> Bool {
        clickButton(app, title: title, identifier: id.rawValue, timeout: timeout)
    }

    private func goToOverview(_ app: XCUIApplication) {
        let radio = app.radioButtons["Projects"].firstMatch
        if fastWait(radio, timeout: 2) {
            radio.click()
            settle(0.5)
            return
        }
        click(app, .sidebarOverview)
    }

    private func goToSessions(_ app: XCUIApplication) {
        let radio = app.radioButtons["Sessions"].firstMatch
        if fastWait(radio, timeout: 2) {
            radio.click()
            settle(0.5)
            return
        }
        // All Sessions left the navigator with the smart lists; the Go menu's
        // ⌘2 is the destination's entry point now.
        app.typeKey("2", modifierFlags: .command)
        settle(0.5)
    }

    /// Grid and Board are their own always-present buttons in the global bar
    /// now, not segments of a picker that only appeared in some scopes.
    private func choosePresentation(_ app: XCUIApplication, _ title: String) {
        let button = element(app, AXID.toolbarShow(title))
        if fastWait(button, timeout: 3) {
            button.click()
            settle(0.6)
            return
        }
        Self.note("NAVFAIL   no presentation button '\(title)'")
    }

    /// The grid always launches empty — membership is explicit and nothing is
    /// a member on a fresh launch. Fill it from the lit group; if the toolbar
    /// control is still animating in, fall back to the documented sidebar
    /// gesture (a single click toggles grid membership while the grid is up).
    private func fillGrid(_ app: XCUIApplication) {
        if let addAll = largestMatch(app, .gridAddAllButton, timeout: 8) {
            addAll.click()
            settle(0.8)
        }
        if largestMatch(app, .gridView, timeout: 2) == nil {
            for title in ["Fix login bug", "Refactor sidebar", "Autonomous workflow loop"] {
                _ = click(app, AXID.sessionRow(title), timeout: 2)
            }
            settle(0.8)
        }
    }

    /// Opening a surface (Git / Files / Skills / Rules) swaps the masthead —
    /// and the surface links it carries — for the return breadcrumb, so the
    /// next surface has to be reached back through Overview. Silent when the
    /// workspace is already on Overview.
    private func returnToProjectOverview(_ app: XCUIApplication) {
        guard let bar = largestMatch(app, .projectReturnToOverview, timeout: 2) else { return }
        bar.click()
        settle(0.6)
    }

    private func assertCaptured(_ names: [String]) {
        let missing = names.filter { !Self.capturedNames.contains($0) }
        XCTAssertTrue(missing.isEmpty, "Missing documentation captures: \(missing.joined(separator: ", "))")
    }

    // MARK: - Shell, Home, and fleet presentations

    func testCaptureShellAndFleetSurfaces() {
        let app = launchedApp()
        XCTAssertTrue(
            fastWait(element(app, .homeDashboard), timeout: 12),
            "app never reached the home dashboard"
        )

        shootWindow(app, "01-home-dashboard", "Shell and Home dashboard")
        shootElement(app, id: .homeDashboard, "02-home-dashboard-element", "Home dashboard")
        shootElement(app, id: .homeStats, "03-home-activity-stats", "Activity stats")
        shootElement(app, id: .homeRecentProjects, "05-home-projects-gallery", "Project cards")

        goToSessions(app)
        shootWindow(app, "07-sessions-focus", "Sessions facet and Focus presentation")
        shootElement(app, id: .sidebarList, "08-session-list", "Session list")
        shootElement(app, id: AXID.sessionRow("Fix login bug"), "09-session-sidebar-row", "Session row")

        choosePresentation(app, "Grid")
        fillGrid(app)
        settle(1.0)
        shootWindow(app, "10-presentation-grid", "Grid presentation")
        shootElement(app, id: .gridView, "11-grid-view", "Mission control grid")

        choosePresentation(app, "Board")
        shootWindow(app, "13-presentation-board", "Board presentation")
        shootElement(app, id: .kanbanBoard, "14-kanban-board", "Kanban board")

        goToSessions(app)
        click(app, AXID.sessionRow("Fix login bug"))
        shootWindow(app, "15-presentation-focus", "Focused terminal presentation")

        assertCaptured([
            "01-home-dashboard", "07-sessions-focus", "10-presentation-grid",
            "11-grid-view", "13-presentation-board", "15-presentation-focus",
        ])
    }

    // MARK: - Launchers, sheets, and settings

    func testCaptureLaunchersAndModals() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, .homeDashboard), timeout: 12))

        goToSessions(app)
        if click(app, AXID.sessionRow("Fix login bug")) {
            app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
            settle(1.0)
            shootWindow(app, "22-delete-session-sheet", "Delete session sheet")
            click(app, .deleteSessionCancel)
        }

        goToOverview(app)
        app.typeKey("n", modifierFlags: .command)
        settle(1.0)
        shootWindow(app, "20-new-session-command-bar", "New Session command bar")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(1.0)

        app.typeKey("k", modifierFlags: .command)
        settle(1.0)
        shootWindow(app, "21-command-palette", "Command palette")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(1.0)

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(fastWait(element(app, .settingsView), timeout: 6))
        shootWindow(app, "23-settings-general", "Settings General pane", containing: AXID.settingsView.rawValue)

        if clickButton(app, title: "Terminal", identifier: AXID.settingsSidebarTab("terminal")) {
            shootWindow(app, "24-settings-terminal", "Settings Terminal pane", containing: AXID.settingsView.rawValue)
        }
        if clickButton(app, title: "Git & Worktrees", identifier: AXID.settingsSidebarTab("git")) {
            shootWindow(app, "25-settings-git", "Settings Git & Worktrees pane", containing: AXID.settingsView.rawValue)
        }
        if clickButton(app, title: "Coding Agents", identifier: AXID.settingsSidebarTab("agents")) {
            shootWindow(app, "26-settings-agents", "Settings Coding Agents pane", containing: AXID.settingsView.rawValue)
        }

        assertCaptured([
            "20-new-session-command-bar", "21-command-palette", "22-delete-session-sheet",
            "24-settings-terminal", "25-settings-git", "26-settings-agents",
        ])
    }

    // MARK: - Project workspace

    func testCaptureProjectWorkspace() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, .homeDashboard), timeout: 12))

        goToOverview(app)
        clickButton(app, title: "Flotilla", identifier: AXID.projectRow("Flotilla"))
        settle(1.0)
        shootWindow(app, "30-project-overview", "Project Overview tab")

        if clickButton(app, title: "Git", id: .projectTabGit) {
            shootWindow(app, "33-project-git-changes", "Git Changes sub-tab")
            if clickButton(app, title: "Simulate Edit", id: .diffPanelSimulateEditButton) {
                settle(1.0)
                shootWindow(app, "34-diff-panel-populated", "Populated diff panel")
            }
            if clickButton(app, title: "Commits", identifier: AXID.projectGitSubTab("Commits")) {
                settle(1.0)
                shootWindow(app, "36-project-git-commits", "Commit graph and history")
            }
        }

        returnToProjectOverview(app)
        if clickButton(app, title: "Files", id: .projectTabFiles) {
            settle(1.0)
            shootWindow(app, "37-project-files", "File tree and editor pane")
        }
        returnToProjectOverview(app)
        if clickButton(app, title: "Skills", id: .projectTabSkills) {
            settle(1.0)
            shootWindow(app, "39-project-skills", "Knowledge catalog ledger")
        }
        returnToProjectOverview(app)
        if clickButton(app, title: "Rules", id: .projectTabRules) {
            settle(1.0)
            shootWindow(app, "40-project-rules", "Rules knowledge catalog")
            if click(app, AXID.knowledgeItem("CLAUDE.md")) {
                settle(0.8)
                shootWindow(app, "41-knowledge-detail", "Knowledge detail pane")
            }
        }

        assertCaptured([
            "30-project-overview", "34-diff-panel-populated", "36-project-git-commits",
            "37-project-files", "39-project-skills", "41-knowledge-detail",
        ])
    }
}
