import XCTest

/// The Home widget grid's edit interactions, end to end: the sequences that
/// silently broke once already (no hit area in edit mode meant no drag and
/// no context menu). No assertions on styling — only on what moved where.
@MainActor
final class HomeWidgetsUITests: XCTestCase {
    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launch()
        return app
    }

    private func fastWait(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return true }
            usleep(50_000)
        }
        return element.exists
    }

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        app.descendants(matching: .any)[id.rawValue].firstMatch
    }

    private func widget(_ app: XCUIApplication, _ kind: String) -> XCUIElement {
        app.descendants(matching: .any)[AXID.homeWidget.rawValue + kind].firstMatch
    }

    private func openHome(_ app: XCUIApplication) {
        let home = element(app, .sidebarOverview)
        XCTAssertTrue(fastWait(home, timeout: 8))
        home.click()
        XCTAssertTrue(fastWait(element(app, .homeWidgetGrid), timeout: 5))
    }

    func testContextMenuResizesAWidget() {
        let app = launchedApp()
        openHome(app)
        // Contributions defaults to Wide and also offers Medium.
        let contributions = widget(app, "contributions")
        XCTAssertTrue(fastWait(contributions))
        let before = contributions.frame.width

        contributions.rightClick()
        let medium = app.menuItems["Medium"]
        XCTAssertTrue(fastWait(medium, timeout: 3), "context menu should offer the widget's sizes")
        medium.click()

        let deadline = Date().addingTimeInterval(3)
        while contributions.frame.width > before * 0.75, Date() < deadline { usleep(50_000) }
        XCTAssertLessThan(contributions.frame.width, before * 0.75, "Medium should no longer span the full row")
    }

    func testEditModeEntersAndEscapeDiscards() {
        let app = launchedApp()
        openHome(app)
        let edit = element(app, .homeWidgetEditButton)
        XCTAssertTrue(fastWait(edit))
        edit.click()
        XCTAssertTrue(fastWait(element(app, .homeWidgetDoneButton)))

        let removeShare = app.descendants(matching: .any)[AXID.homeWidgetRemoveBadge.rawValue + "agentShare"].firstMatch
        XCTAssertTrue(fastWait(removeShare))
        removeShare.click()
        XCTAssertFalse(widget(app, "agentShare").exists)

        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(fastWait(edit), "Esc should leave edit mode")
        XCTAssertTrue(fastWait(widget(app, "agentShare")), "Esc should discard the removal")
    }

    // Reorders through the context menu, the same `editor.move` path the
    // drag gesture uses: XCUITest's synthesized drags never reach the grid's
    // SwiftUI DragGesture, so the gesture itself stays a manual check.
    func testReorderingAWidgetMovesItAndDoneKeepsIt() {
        let app = launchedApp()
        openHome(app)
        element(app, .homeWidgetEditButton).click()
        XCTAssertTrue(fastWait(element(app, .homeWidgetDoneButton)))

        let rhythm = widget(app, "weeklyRhythm")
        let contributions = widget(app, "contributions")
        XCTAssertTrue(fastWait(rhythm) && fastWait(contributions))
        XCTAssertGreaterThan(rhythm.frame.minY, contributions.frame.minY)

        rhythm.rightClick()
        let moveEarlier = app.menuItems["Move Earlier"]
        XCTAssertTrue(fastWait(moveEarlier, timeout: 3))
        moveEarlier.click()
        element(app, .homeWidgetDoneButton).click()

        XCTAssertTrue(fastWait(element(app, .homeWidgetEditButton)))
        XCTAssertLessThan(rhythm.frame.minY, contributions.frame.minY, "Weekly rhythm should now come first")
    }
}
