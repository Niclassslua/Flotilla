import XCTest
import SessionKit
@testable import Flotilla

/// `ProjectChoice` replaced the old `isGeneralSession: Bool` + `selectedFolder:
/// URL?` pair, which could represent the contradictory state "project session
/// with no folder". These cover the parts the designs depend on.
final class ProjectChoiceTests: XCTestCase {
    private func project(_ name: String, _ path: String) -> Project {
        Project(name: name, rootPath: URL(fileURLWithPath: path, isDirectory: true))
    }

    func testGeneralHasNoFolderSoCreateSessionTreatsItAsProjectless() {
        XCTAssertNil(ProjectChoice.general.folder)
        XCTAssertTrue(ProjectChoice.general.isGeneral)
    }

    func testKnownAndCustomBothSurfaceTheirFolder() {
        let known = ProjectChoice.known(project("Atlas", "/Users/dev/atlas"))
        let custom = ProjectChoice.custom(URL(fileURLWithPath: "/Users/dev/spike", isDirectory: true))

        XCTAssertEqual(known.folder?.path, "/Users/dev/atlas")
        XCTAssertEqual(custom.folder?.path, "/Users/dev/spike")
        XCTAssertFalse(known.isGeneral)
        XCTAssertFalse(custom.isGeneral)
    }

    func testCustomChoiceIsNamedForItsLastPathComponent() {
        let custom = ProjectChoice.custom(URL(fileURLWithPath: "/Users/dev/spike", isDirectory: true))
        XCTAssertEqual(custom.displayName, "spike")
    }

    func testFilterMatchesOnNameCaseInsensitively() {
        let choices: [ProjectChoice] = [
            .general,
            .known(project("Flotilla", "/Users/dev/Projects/flotilla")),
            .known(project("Atlas", "/Users/dev/Projects/atlas"))
        ]

        let matches = ProjectChoiceCatalog.filter(choices, query: "flot")
        XCTAssertEqual(matches.map(\.displayName), ["Flotilla"])
    }

    func testFilterAlsoMatchesOnPathSoYouCanSearchByDirectory() {
        let choices: [ProjectChoice] = [
            .known(project("Flotilla", "/Users/dev/work/flotilla")),
            .known(project("Atlas", "/Users/dev/personal/atlas"))
        ]

        let matches = ProjectChoiceCatalog.filter(choices, query: "personal")
        XCTAssertEqual(matches.map(\.displayName), ["Atlas"])
    }

    func testBlankQueryReturnsEverythingRatherThanNothing() {
        let choices: [ProjectChoice] = [.general, .known(project("Atlas", "/a"))]
        XCTAssertEqual(ProjectChoiceCatalog.filter(choices, query: "   ").count, 2)
    }
}
