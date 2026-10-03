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

    func testNormalNounPhraseStillAccepted() {
        XCTAssertEqual(
            AppleIntelligenceSessionNameGenerator.validated("Login button styling"),
            "Login button styling"
        )
    }

    func testInvalidTitlesAreRejected() {
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("solo"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("Auth: login button"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("one two three four five six"))
        XCTAssertNil(AppleIntelligenceSessionNameGenerator.validated("   "))
    }
}
