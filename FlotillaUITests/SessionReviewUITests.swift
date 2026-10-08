import XCTest

/// Two contracts a human cannot check by glancing at the window: that
/// selecting a layout actually re-renders the diff (rather than only lighting
/// up a button), and that a comment written against one scope is still there
/// after switching scopes. Both fail silently — the review still looks right.
@MainActor
final class SessionReviewUITests: XCTestCase {
    private static let sessionTitle = "Retry the uploader"
    private static let reviewedFile = "Uploader.swift"

    private func launchedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments.append(contentsOf: ["-ApplePersistenceIgnoreState", "YES"])
        app.launchEnvironment["UI_TESTING"] = "1"
        app.launchEnvironment["UI_TESTING_SIMULATE_REVIEW_SESSION"] = "1"
        app.launch()
        return app
    }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any)[identifier].firstMatch
    }

    private func element(_ app: XCUIApplication, _ id: AXID) -> XCUIElement {
        element(app, id.rawValue)
    }

    /// Opens the review window for the seeded Ready-for-Review session.
    private func openReview(_ app: XCUIApplication) -> XCUIElement {
        let row = element(app, AXID.sessionRow(Self.sessionTitle))
        XCTAssertTrue(fastWait(row, timeout: 5), "seeded review session should be listed")
        row.click()

        let reviewButton = element(app, AXID.sessionBarReview(Self.sessionTitle))
        XCTAssertTrue(fastWait(reviewButton, timeout: 5), "Ready for Review sessions should offer Review")
        reviewButton.click()

        let window = element(app, .reviewWindow)
        XCTAssertTrue(fastWait(window, timeout: 10), "the review window should open")
        return window
    }

    func testSideBySideAndInlineButtonsSwapTheRenderedLayout() {
        let app = launchedApp()
        _ = openReview(app)

        let fileRow = element(app, AXID.reviewFileRow(Self.reviewedFile))
        XCTAssertTrue(fastWait(fileRow, timeout: 10), "the changed file should be listed")

        // Side by Side is the default, so its layout must already be on screen.
        XCTAssertTrue(
            fastWait(element(app, .reviewHunkSideBySide), timeout: 5),
            "the review should open in Side by Side"
        )

        element(app, .reviewModeInline).click()
        XCTAssertTrue(
            fastWait(element(app, .reviewHunkInline), timeout: 5),
            "choosing Inline should render the inline layout"
        )
        XCTAssertFalse(
            element(app, .reviewHunkSideBySide).exists,
            "the two-column layout should be gone, not merely covered"
        )

        element(app, .reviewModeSideBySide).click()
        XCTAssertTrue(
            fastWait(element(app, .reviewHunkSideBySide), timeout: 5),
            "choosing Side by Side should bring the two-column layout back"
        )
        XCTAssertFalse(element(app, .reviewHunkInline).exists)
    }

    func testACommentSurvivesSwitchingScope() {
        let app = launchedApp()
        _ = openReview(app)

        // The diff pane is lazy: on a short display the reviewed file's
        // section isn't built until it's scrolled to. Select it in the file
        // list, as a reviewer would, which scrolls the pane there.
        let fileRow = element(app, AXID.reviewFileRow(Self.reviewedFile))
        XCTAssertTrue(fastWait(fileRow, timeout: 10), "the changed file should be listed")
        fileRow.click()

        let commentButton = element(app, AXID.reviewCommentOnFile(Self.reviewedFile))
        XCTAssertTrue(fastWait(commentButton, timeout: 10), "the file section should offer a file comment")
        commentButton.click()

        let editor = element(app, .reviewCommentEditor)
        XCTAssertTrue(fastWait(editor, timeout: 5))
        editor.click()
        let body = "Only retry 5xx"
        editor.typeText(body)

        let submit = element(app, .reviewCommentSubmit)
        XCTAssertTrue(fastWait(submit, timeout: 3))
        submit.click()

        let comment = app.staticTexts[body].firstMatch
        XCTAssertTrue(fastWait(comment, timeout: 5), "the comment should be recorded")

        // The same file carries a different diff under each scope; the comment
        // belongs to the file, so it has to survive the switch and the reload.
        element(app, .reviewScopeUncommitted).click()
        XCTAssertTrue(
            fastWait(element(app, AXID.reviewFileRow(Self.reviewedFile)), timeout: 10),
            "the file should still be listed under the uncommitted scope"
        )
        XCTAssertTrue(
            fastWait(app.staticTexts[body].firstMatch, timeout: 5),
            "the comment should survive the scope switch"
        )

        element(app, .reviewScopeBranch).click()
        XCTAssertTrue(
            fastWait(app.staticTexts[body].firstMatch, timeout: 10),
            "the comment should still be there on the way back"
        )
    }
}
