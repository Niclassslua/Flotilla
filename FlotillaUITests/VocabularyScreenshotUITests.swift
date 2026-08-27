import XCTest

/// Screenshot harness for `docs/ui-vocabulary.md` — **not an assertion test.**
///
/// Walks the app to each surface the vocabulary document names and writes a PNG
/// per surface to `/tmp/flotilla-vocab-shots`, plus a `manifest.txt` recording
/// what was captured and what could not be reached. Nothing here asserts on
/// visuals (see CLAUDE.md's testing scope) — it exists purely to produce
/// illustrations for the doc, and can be deleted once they're captured.
///
/// Run only this class:
/// ```
/// xcodebuild -project Flotilla.xcodeproj -scheme Flotilla -destination 'platform=macOS' \
///   -derivedDataPath build/DerivedData test \
///   -only-testing:FlotillaUITests/VocabularyScreenshotUITests
/// ```
@MainActor
final class VocabularyScreenshotUITests: XCTestCase {
    private static let outputDirectory = URL(fileURLWithPath: "/tmp/flotilla-vocab-shots")
    private static var log: [String] = []

    override class func setUp() {
        try? FileManager.default.removeItem(at: outputDirectory)
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        log = []
    }

    override class func tearDown() {
        let manifest = log.joined(separator: "\n") + "\n"
        try? manifest.write(
            to: outputDirectory.appendingPathComponent("manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
    }

    // MARK: - Harness

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    /// Lets SwiftUI's transitions land before the frame is grabbed. The shell
    /// animates selection (0.22s) and presentation (0.18s) changes.
    private func settle(_ seconds: TimeInterval = 0.6) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func write(_ screenshot: XCUIScreenshot, named name: String, note: String) {
        let url = Self.outputDirectory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            Self.log.append("OK       \(name).png — \(note)")
        } catch {
            Self.log.append("WRITEFAIL \(name).png — \(error.localizedDescription)")
        }
    }

    /// Captures the app's main window. Never fails the test — a surface that
    /// can't be reached is recorded in the manifest instead.
    private func shootWindow(_ app: XCUIApplication, _ name: String, _ note: String) {
        settle()
        guard let window = app.windows.allElementsBoundByIndex.first(where: { $0.exists }) else {
            Self.log.append("NOWINDOW \(name).png — \(note)")
            return
        }
        write(window.screenshot(), named: name, note: note)
    }

    /// Captures one element by accessibility identifier, cropped to its bounds.
    private func shootElement(_ app: XCUIApplication, id: String, _ name: String, _ note: String) {
        let target = element(app, id)
        guard fastWait(target, timeout: 3) else {
            Self.log.append("MISSING  \(name).png — no element '\(id)' (\(note))")
            return
        }
        settle(0.3)
        write(target.screenshot(), named: name, note: "\(note) [element \(id)]")
    }

    /// Clicks an element if it's there; reports and moves on if it isn't.
    @discardableResult
    private func click(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 4) -> Bool {
        let target = element(app, identifier)
        guard fastWait(target, timeout: timeout) else {
            Self.log.append("NAVFAIL  could not find '\(identifier)' to click")
            return false
        }
        target.click()
        settle(0.4)
        return true
    }

    private func goToOverview(_ app: XCUIApplication) { click(app, "Sidebar.Overview") }
    private func goToSessions(_ app: XCUIApplication) { click(app, "Sidebar.AllSessions") }

    /// The presentation picker is a segmented control; its segments surface as
    /// buttons on some macOS versions and radio buttons on others.
    private func choosePresentation(_ app: XCUIApplication, _ title: String) {
        let segment = element(app, "Toolbar.PresentationPicker").buttons[title].firstMatch
        if fastWait(segment, timeout: 2) {
            segment.click()
            settle(0.5)
            return
        }
        let radio = app.radioButtons[title].firstMatch
        if fastWait(radio, timeout: 2) {
            radio.click()
            settle(0.5)
            return
        }
        Self.log.append("NAVFAIL  no presentation segment '\(title)'")
    }

    private func openProject(_ app: XCUIApplication) {
        goToOverview(app)
        if !click(app, "ProjectRow-Flotilla") {
            click(app, "Home.Project-Flotilla")
        }
    }

    // MARK: - 1. Shell, Home, and the fleet presentations

    func testCaptureShellAndFleetSurfaces() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, "HomeDashboard"), timeout: 12), "app never reached the home dashboard")

        // §1 Window shell + §2 Home / Overview
        shootWindow(app, "01-home-dashboard", "Shell: rail + detail column showing the Home dashboard")
        shootElement(app, id: "HomeDashboard", "02-home-dashboard-element", "Home dashboard on its own")
        shootElement(app, id: "Home.AttentionQueue", "03-home-attention-queue", "Attention queue")
        shootElement(app, id: "Home.RecentSessions", "04-home-recent-sessions", "Recent sessions list")
        shootElement(app, id: "Home.RecentProjects", "05-home-projects-gallery", "Projects gallery")
        shootElement(app, id: "Home.LaunchSummary", "06-composer-summary-line", "Composer's summary line")

        // §1 Session list — the Sessions facet is the only one with a sidebar column
        goToSessions(app)
        shootWindow(app, "07-sessions-focus", "Sessions facet: rail + session list + Focus presentation")
        shootElement(app, id: "SidebarList", "08-session-list", "Session list (sidebar column)")
        shootElement(app, id: "SessionRow-Fix login bug", "09-session-sidebar-row", "Session sidebar row / session card, row variant")

        // §3 Grid
        choosePresentation(app, "Grid")
        shootWindow(app, "10-presentation-grid", "Grid presentation with the grid toolbar controls")
        shootElement(app, id: "GridView", "11-grid-view", "Mission control grid")
        shootElement(app, id: "GridTile-Fix login bug", "12-session-tile", "Session tile / session card, tile variant")

        // §3 Board
        choosePresentation(app, "Board")
        shootWindow(app, "13-presentation-board", "Board presentation")
        shootElement(app, id: "KanbanBoard", "14-kanban-board", "Kanban board")

        // §3 Focus — a single session's terminal filling the detail column
        goToSessions(app)
        click(app, "SessionRow-Fix login bug")
        shootWindow(app, "15-presentation-focus", "Focus presentation: one terminal host filling the detail column")
    }

    // MARK: - 2. Launchers and modals

    func testCaptureLaunchersAndModals() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, "HomeDashboard"), timeout: 12))

        // §7 New Session window — the command bar design
        app.typeKey("n", modifierFlags: .command)
        settle(0.8)
        shootWindow(app, "20-new-session-command-bar", "New Session window (CommandBarDesign) over its scrim")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(0.5)

        // §7 Command palette
        app.typeKey("k", modifierFlags: .command)
        settle(0.8)
        shootWindow(app, "21-command-palette", "Command palette overlay")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(0.5)

        // §7 Delete session sheet — a real AppKit sheet, not an overlay
        goToSessions(app)
        if click(app, "SessionRow-Refactor sidebar") {
            app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
            settle(0.8)
            shootWindow(app, "22-delete-session-sheet", "Delete session sheet")
            click(app, "DeleteSessionDialog.Cancel")
        }

        // §8 Settings — a separate window
        app.typeKey(",", modifierFlags: .command)
        settle(1.0)
        shootWindow(app, "23-settings-general", "Settings window, General pane")
        if click(app, "Settings.TerminalTab") {
            shootWindow(app, "24-settings-terminal", "Settings window, Terminal pane")
        }
        if click(app, "Settings.AgentsTab") {
            shootWindow(app, "25-settings-agents", "Settings window, Agent pane")
        }
    }

    // MARK: - 3. Project workspace

    func testCaptureProjectWorkspace() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, "HomeDashboard"), timeout: 12))

        openProject(app)
        shootWindow(app, "30-project-overview", "Project detail: header, mode tabs, Overview tab")
        shootElement(app, id: "ProjectOverview", "31-project-overview-element", "Project overview tab content")
        shootElement(app, id: "ProjectWorktreesSection", "32-worktree-section", "Worktree section")

        // §5 Git tab — Changes sub-tab hosts the diff panel
        if click(app, "ProjectDetail.ModeTab-Git") {
            shootWindow(app, "33-project-git-changes", "Git tab, Changes sub-tab, with the scope picker")
            // Seed a change so the diff panel has file rows rather than its empty state.
            if click(app, "DiffPanel.SimulateEditButton", timeout: 3) {
                settle(0.8)
                shootWindow(app, "34-diff-panel-populated", "Diff panel with a changed file")
                shootElement(app, id: "DiffPanel", "35-diff-panel-element", "Diff panel")
            }
            if click(app, "ProjectGit.SubTab-Commits") {
                settle(1.0)
                shootWindow(app, "36-project-git-commits", "Git tab, Commits sub-tab: the commit graph")
            }
        }

        // §5 Files tab — the file browser
        if click(app, "ProjectDetail.ModeTab-Files") {
            settle(0.8)
            shootWindow(app, "37-project-files", "Files tab: file tree + editor pane")
            shootElement(app, id: "FileBrowser", "38-file-browser-element", "File browser")
        }

        // §5 Skills and Rules tabs — both are the knowledge catalog
        if click(app, "ProjectDetail.ModeTab-Skills") {
            settle(0.8)
            shootWindow(app, "39-project-skills", "Skills tab: knowledge catalog, ledger design")
        }
        if click(app, "ProjectDetail.ModeTab-Rules") {
            settle(0.8)
            shootWindow(app, "40-project-rules", "Rules tab: knowledge catalog with the Add Template menu")
            if click(app, "Knowledge.Item-CLAUDE.md") {
                settle(0.6)
                shootWindow(app, "41-knowledge-detail", "Knowledge detail pane rendering a rules file")
            }
        }
    }
}
