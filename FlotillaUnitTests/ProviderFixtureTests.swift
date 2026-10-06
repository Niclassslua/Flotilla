import XCTest
import SessionKit
@testable import HooksKit

/// Replays sanitized hook payloads and terminal screens captured from the real
/// provider CLIs (`FlotillaUnitTests/ProviderFixtures/<provider>/`) through the
/// same classifiers the app runs, so a provider update that changes a payload
/// or a screen shows up here as a named fixture rather than as a session stuck
/// in the wrong column.
///
/// Each provider's `manifest.json` lists its fixtures with the CLI version and
/// date they were captured on, and the observation they must produce (`null`
/// for "no observation"). An entry with `knownGap` records a case Flotilla
/// currently gets wrong: `currentlyObserved` pins today's behavior, and the
/// desired `expect` runs under `XCTExpectFailure`, so fixing the gap surfaces
/// as an unexpected pass that prompts updating the manifest. What each fixture
/// means, and how to capture new ones, is in `docs/providers/`.
final class ProviderFixtureTests: XCTestCase {
    private struct Manifest: Decodable {
        let agent: AgentKind
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        enum Source: String, Decodable {
            case hook
            case screen
        }

        let file: String
        let source: Source
        let capturedOn: String
        let cliVersion: String?
        let expect: Expectation?
        let currentlyObserved: Expectation?
        let knownGap: String?
    }

    private struct Expectation: Decodable, Equatable, CustomStringConvertible {
        let status: SessionStatus
        let reason: SessionWaitingReason?

        init(status: SessionStatus, reason: SessionWaitingReason?) {
            self.status = status
            self.reason = reason
        }

        init(_ observation: SessionStatusObservation) {
            self.init(status: observation.status, reason: observation.waitingReason)
        }

        var description: String {
            reason.map { "\(status.rawValue)/\($0.rawValue)" } ?? status.rawValue
        }
    }

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("ProviderFixtures", isDirectory: true)

    private func manifests() throws -> [(directory: URL, manifest: Manifest)] {
        let directories = try FileManager.default.contentsOfDirectory(
            at: Self.root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        return try directories.sorted { $0.path < $1.path }.map { directory in
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            return (directory, try JSONDecoder().decode(Manifest.self, from: data))
        }
    }

    func testEveryAgentHasCapturedFixtures() throws {
        let covered = Set(try manifests().filter { !$0.manifest.fixtures.isEmpty }.map(\.manifest.agent))
        XCTAssertEqual(
            covered,
            Set(AgentKind.allCases),
            "Every provider needs captured fixtures in FlotillaUnitTests/ProviderFixtures (see docs/providers/README.md)"
        )
    }

    func testCapturedHookPayloadsMapToTheDocumentedStatus() throws {
        for (directory, manifest) in try manifests() {
            for fixture in manifest.fixtures where fixture.source == .hook {
                let data = try Data(contentsOf: directory.appendingPathComponent(fixture.file))
                // The provider writes one compact JSON object per line; the
                // fixture is pretty-printed for review.
                let object = try JSONSerialization.jsonObject(with: data)
                let line = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                let observation = HookEventReceiver.observation(forLine: line, agent: manifest.agent)
                check(observation, against: fixture, agent: manifest.agent)
            }
        }
    }

    func testCapturedScreensClassifyAsDocumented() throws {
        let heuristic = TerminalScreenHeuristic()
        for (directory, manifest) in try manifests() {
            for fixture in manifest.fixtures where fixture.source == .screen {
                let screen = try String(contentsOf: directory.appendingPathComponent(fixture.file), encoding: .utf8)
                check(heuristic.observation(forScreen: screen), against: fixture, agent: manifest.agent)
            }
        }
    }

    private func check(_ observation: SessionStatusObservation?, against fixture: Fixture, agent: AgentKind) {
        let actual = observation.map(Expectation.init)
        let label = "\(agent.rawValue)/\(fixture.file) (captured \(fixture.capturedOn), CLI \(fixture.cliVersion ?? "unknown"))"
        let message = "\(label): got \(actual?.description ?? "no observation") ← \(observation?.cause ?? "no cause")"
        if let gap = fixture.knownGap {
            XCTAssertEqual(actual, fixture.currentlyObserved, "\(message); known gap changed behavior: \(gap)")
            XCTExpectFailure("Known gap — \(gap)") {
                XCTAssertEqual(actual, fixture.expect, message)
            }
        } else {
            XCTAssertEqual(actual, fixture.expect, message)
        }
    }
}
