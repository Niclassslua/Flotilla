import XCTest
@testable import Flotilla

final class SessionNameGeneratorTests: XCTestCase {
    func testAllLowercasePhraseIsPromotedToSentenceCase() {
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("session naming pipeline"),
            "Session naming pipeline"
        )
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("oauth token refresh"),
            "Oauth token refresh"
        )
    }

    func testMixedCaseAndIdentifiersPreserveCasing() {
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("Session naming pipeline"),
            "Session naming pipeline"
        )
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("OAuth token refresh"),
            "OAuth token refresh"
        )
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.applySentenceCaseIfNeeded("WaitingNotificationGate"),
            "WaitingNotificationGate"
        )
    }

    func testPromptEchoTitlesAreRejected() {
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("coding-agent sessions"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("Coding Agent Sessions"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("name coding-agent sessions"))
    }

    func testRequestShapedTitlesAreRejected() {
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("I would like to build"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("please document the hooks"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("Can you fix auth"))
        XCTAssertNil(
            AppleIntelligenceSessionNameGenerator.validated(
                "I would like to build",
                against: "I would like to build a comprehensive documentation of hooks"
            )
        )
    }

    func testGoalPrefixEchoIsRejected() {
        let goal = "I would like to build a comprehensive documentation of hooks"
        XCTAssertNil(
            AppleIntelligenceSessionNameGenerator.validated(
                "I would like to build a comprehensive",
                against: goal
            )
        )
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("Hooks documentation", against: goal),
            "Hooks documentation"
        )
    }

    func testQuotedContextNameIsRejectedAsTitle() {
        let goal = #"Why don't we display the screenshots in our right sidebar from session "Modal Design"? Check the transcript."#
        XCTAssertNil(
            AppleIntelligenceSessionNameGenerator.validated("Modal Design", against: goal)
        )
        XCTAssertNil(
            AppleIntelligenceSessionNameGenerator.validated("modal design", against: goal)
        )
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("Display screenshots", against: goal),
            "Display screenshots"
        )
    }

    func testOverlongSuggestionIsClippedToFiveWords() {
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated(
                "Hooks documentation for the entire fleet overview"
            ),
            "Hooks documentation for the entire"
        )
    }

    func testNormalNounPhraseStillAccepted() {
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("Login button styling"),
            "Login button styling"
        )
    }

    func testInvalidTitlesAreRejected() {
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("solo"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("Auth: login button"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("   "))

        if case .rejected(_, let reason) = AppleIntelligenceSessionNameGenerator.validate("solo") {
            XCTAssertTrue(reason.contains("2…5 words"), reason)
        } else {
            XCTFail("expected a word-count rejection")
        }
        if case .rejected(_, let reason) = AppleIntelligenceSessionNameGenerator.validate(
            "I would like to build",
            against: "I would like to build a comprehensive documentation of hooks"
        ) {
            XCTAssertTrue(
                reason.contains("request-shaped") || reason.contains("echoes"),
                reason
            )
        } else {
            XCTFail("expected a request/echo rejection")
        }
    }
}
