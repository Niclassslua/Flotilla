import XCTest

/// Screenshot harness for `docs/ui-vocabulary.md` — **not an assertion test.**
///
/// Walks the app to each surface the vocabulary document names and captures it
/// two ways, because the UI-test runner is sandboxed:
///
/// 1. As an `XCTAttachment` with `.keepAlways`, which lands in the `.xcresult`
///    bundle and always survives. Extract with
///    `xcrun xcresulttool export attachments --path <run>.xcresult --output-path <dir>`.
/// 2. As a PNG under the runner's own container `Documents` directory — the
///    only filesystem location the sandbox permits. Writing to `/tmp` is
///    silently denied, which is why an earlier version of this file produced a
///    green run and no files at all.
///
/// The resolved output directory and a per-surface result line are printed to
/// the test log, so a run is legible even if both storage paths fail.
///
/// Nothing here asserts on visuals (see CLAUDE.md's testing scope) — it exists
/// purely to produce illustrations for the doc, and can be deleted once they're
/// captured.
@MainActor
final class VocabularyScreenshotUITests: XCTestCase {
    /// The runner's sandbox container, not the real `~/Documents`.
    private static let outputDirectory: URL = {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("flotilla-vocab-shots", isDirectory: true)
    }()

    private static var log: [String] = []

    override class func setUp() {
        super.setUp()
        try? FileManager.default.removeItem(at: outputDirectory)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            log = ["output directory: \(outputDirectory.path)"]
        } catch {
            log = ["output directory UNUSABLE (\(error.localizedDescription)) — rely on xcresult attachments"]
        }
        print("[vocab-shots] \(log[0])")
    }

    override class func tearDown() {
        let manifest = log.joined(separator: "\n") + "\n"
        try? manifest.write(
            to: outputDirectory.appendingPathComponent("manifest.txt"),
            atomically: true,
            encoding: .utf8
        )
        print("[vocab-shots] ==== manifest ====\n\(manifest)")
        super.tearDown()
    }

    private static func note(_ line: String) {
        log.append(line)
        print("[vocab-shots] \(line)")
    }

    // MARK: - Harness

    /// A failed capture raises a test failure rather than throwing, so without
    /// this the first unreachable surface aborts the whole walk and every later
    /// surface goes uncaptured. Letting it continue turns one run into a full
    /// report of what worked and what didn't.
    override func setUp() {
        super.setUp()
        continueAfterFailure = true
    }

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

    private func save(_ screenshot: XCUIScreenshot, named name: String, note: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let url = Self.outputDirectory.appendingPathComponent("\(name).png")
        do {
            try screenshot.pngRepresentation.write(to: url)
            Self.note("OK        \(name).png — \(note)")
        } catch {
            Self.note("ATTACHONLY \(name) — \(note) [file write failed: \(error.localizedDescription)]")
        }
    }

    private func shootWindow(_ app: XCUIApplication, _ name: String, _ note: String) {
        settle()
        guard let window = app.windows.allElementsBoundByIndex.first(where: { $0.exists }) else {
            Self.note("NOWINDOW  \(name) — \(note)")
            return
        }
        save(window.screenshot(), named: name, note: note)
    }

    private func shootElement(_ app: XCUIApplication, id: String, _ name: String, _ note: String) {
        guard let target = largestMatch(app, id, timeout: 3) else {
            Self.note("MISSING   \(name) — no element '\(id)' (\(note))")
            return
        }
        settle(0.3)
        save(target.screenshot(), named: name, note: "\(note) [element \(id)]")
    }

    /// SwiftUI propagates an `accessibilityIdentifier` to descendants, so a
    /// query can match both a container and the text inside it. The container
    /// is the one carrying the tap gesture and the one worth photographing —
    /// and it's always the largest by area.
    private func largestMatch(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval) -> XCUIElement? {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        guard fastWait(matches.firstMatch, timeout: timeout) else { return nil }
        let candidates = matches.allElementsBoundByIndex.filter(\.exists)
        guard !candidates.isEmpty else { return nil }
        return candidates.max { lhs, rhs in
            (lhs.frame.width * lhs.frame.height) < (rhs.frame.width * rhs.frame.height)
        }
    }

    /// Clicks the container carrying an identifier. Reports and moves on if
    /// it isn't there — a missed step must not abort the rest of the walk.
    @discardableResult
    private func click(_ app: XCUIApplication, _ identifier: String, timeout: TimeInterval = 4) -> Bool {
        guard let target = largestMatch(app, identifier, timeout: timeout) else {
            Self.note("NAVFAIL   could not find '\(identifier)' to click")
            return false
        }
        target.click()
        settle(0.5)
        return true
    }

    private func goToOverview(_ app: XCUIApplication) { click(app, "Sidebar.Overview") }
    private func goToSessions(_ app: XCUIApplication) { click(app, "Sidebar.AllSessions") }

    /// The presentation picker is a segmented control; its segments surface as
    /// radio buttons on this macOS version and as buttons on others.
    private func choosePresentation(_ app: XCUIApplication, _ title: String) {
        let radio = app.radioButtons[title].firstMatch
        if fastWait(radio, timeout: 2) {
            radio.click()
            settle(0.6)
            return
        }
        let segment = element(app, "Toolbar.PresentationPicker").buttons[title].firstMatch
        if fastWait(segment, timeout: 2) {
            segment.click()
            settle(0.6)
            return
        }
        Self.note("NAVFAIL   no presentation segment '\(title)'")
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

        // §3 Grid. The grid starts empty — without adding sessions it renders
        // GridEmptyState and there are no tiles to photograph.
        choosePresentation(app, "Grid")
        click(app, "Grid.AddAllButton")
        settle(1.0)
        shootWindow(app, "10-presentation-grid", "Grid presentation with the grid toolbar controls")
        shootElement(app, id: "GridView", "11-grid-view", "Mission control grid")
        shootElement(app, id: "GridTile-Fix login bug", "12-session-tile", "Session tile / session card, tile variant")

        // §3 Board
        choosePresentation(app, "Board")
        shootWindow(app, "13-presentation-board", "Board presentation")
        shootElement(app, id: "KanbanBoard", "14-kanban-board", "Kanban board")

        // §3 Focus — a single session's terminal filling the detail column
        goToSessions(app)
        choosePresentation(app, "Focus")
        click(app, "SessionRow-Fix login bug")
        shootWindow(app, "15-presentation-focus", "Focus presentation: one terminal host filling the detail column")
    }

    // MARK: - 2. Launchers and modals

    func testCaptureLaunchersAndModals() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, "HomeDashboard"), timeout: 12))

        // §7 New Session window — the command bar design
        app.typeKey("n", modifierFlags: .command)
        settle(1.0)
        shootWindow(app, "20-new-session-command-bar", "New Session window (CommandBarDesign) over its scrim")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(1.2)

        // §7 Command palette
        app.typeKey("k", modifierFlags: .command)
        settle(1.0)
        shootWindow(app, "21-command-palette", "Command palette overlay")
        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        settle(1.2)

        // §7 Delete session sheet — a real AppKit sheet, not an overlay
        goToSessions(app)
        if click(app, "SessionRow-Fix login bug") {
            app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: .command)
            settle(1.0)
            shootWindow(app, "22-delete-session-sheet", "Delete session sheet")
            click(app, "DeleteSessionDialog.Cancel")
        }

        // §8 Settings — a separate window. The sidebar rows are identified by
        // `settings.sidebar.<rawValue>`, not the stale `Settings.*Tab` names in AXID.
        app.typeKey(",", modifierFlags: .command)
        settle(1.4)
        shootWindow(app, "23-settings-general", "Settings window, General pane")
        if click(app, "settings.sidebar.terminal") {
            shootWindow(app, "24-settings-terminal", "Settings window, Terminal & Editor pane")
        }
        if click(app, "settings.sidebar.git") {
            shootWindow(app, "25-settings-git", "Settings window, Git & Worktrees pane")
        }
        if click(app, "settings.sidebar.agents") {
            shootWindow(app, "26-settings-agents", "Settings window, Agents pane")
        }
    }

    // MARK: - 3. Project workspace

    func testCaptureProjectWorkspace() {
        let app = launchedApp()
        XCTAssertTrue(fastWait(element(app, "HomeDashboard"), timeout: 12))

        // The project card drills in via `.onTapGesture` on its container, so
        // the click has to land on the container rather than a StaticText child.
        goToOverview(app)
        click(app, "ProjectRow-Flotilla")
        settle(1.0)

        shootWindow(app, "30-project-overview", "Project detail: header, mode tabs, Overview tab")
        shootElement(app, id: "ProjectOverview", "31-project-overview-element", "Project overview tab content")
        shootElement(app, id: "ProjectWorktreesSection", "32-worktree-section", "Worktree section")

        // §5 Git tab — Changes sub-tab hosts the diff panel
        if click(app, "ProjectDetail.ModeTab-Git") {
            shootWindow(app, "33-project-git-changes", "Git tab, Changes sub-tab, with the scope picker")
            // Seed a change so the diff panel shows file rows, not its empty state.
            if click(app, "DiffPanel.SimulateEditButton", timeout: 3) {
                settle(1.0)
                shootWindow(app, "34-diff-panel-populated", "Diff panel with a changed file")
                shootElement(app, id: "DiffPanel", "35-diff-panel-element", "Diff panel")
            }
            if click(app, "ProjectGit.SubTab-Commits") {
                settle(1.2)
                shootWindow(app, "36-project-git-commits", "Git tab, Commits sub-tab: the commit graph")
            }
        }

        // §5 Files tab — the file browser
        if click(app, "ProjectDetail.ModeTab-Files") {
            settle(1.0)
            shootWindow(app, "37-project-files", "Files tab: file tree + editor pane")
            shootElement(app, id: "FileBrowser", "38-file-browser-element", "File browser")
        }

        // §5 Skills and Rules tabs — both are the knowledge catalog
        if click(app, "ProjectDetail.ModeTab-Skills") {
            settle(1.0)
            shootWindow(app, "39-project-skills", "Skills tab: knowledge catalog, ledger design")
        }
        if click(app, "ProjectDetail.ModeTab-Rules") {
            settle(1.0)
            shootWindow(app, "40-project-rules", "Rules tab: knowledge catalog with the Add Template menu")
            if click(app, "Knowledge.Item-CLAUDE.md") {
                settle(0.8)
                shootWindow(app, "41-knowledge-detail", "Knowledge detail pane rendering a rules file")
            }
        }
    }
}
