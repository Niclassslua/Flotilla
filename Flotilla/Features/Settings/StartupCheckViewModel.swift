import Foundation
import AgentKit
import Observation
import ProcessKit
import SessionKit
import SettingsKit

/// Runs the (non-blocking) startup environment check for optional
/// dependencies. `UI_TESTING_SIMULATE_MISSING_TOOLS` (comma-separated, or
/// the literal `none`) lets a UI test force specific tools to appear
/// missing — or force none missing — deterministically, since the real
/// machine running the test may or may not actually have tmux/gh
/// installed. Unset means "run the real check".
@Observable
@MainActor
final class StartupCheckViewModel {
    private(set) var missingOptionalTools: [String] = []
    private(set) var missingRequiredTools: [String] = []
    private(set) var missingAgents: [AgentKind] = []
    private(set) var foundToolPaths: [String: URL] = [:]
    var isDismissed = false

    var warningItems: [String] {
        missingRequiredTools
            + missingOptionalTools
            // opencode and antigravity are optional bonus agents — their absence is detected
            // (visible in the check summary) but not warned about, so a
            // missing opencode/antigravity never blocks or nags.
            + missingAgents.filter { $0 != .openCode && $0 != .antigravity }.map(\.displayName)
    }

    init(
        settings: AppSettings = AppSettings(),
        locator: any ExecutableLocating = PATHExecutableLocator()
    ) {
        let optionalTools = ["tmux", "gh"]
        let checker = StartupEnvironmentChecker(locator: locator)
        let requiredReport = checker.check(tools: ["git"])
        missingRequiredTools = requiredReport.missingTools.sorted()
        foundToolPaths.merge(requiredReport.foundTools) { current, _ in current }

        switch ProcessInfo.processInfo.environment["UI_TESTING_SIMULATE_MISSING_TOOLS"] {
        case "none":
            missingOptionalTools = []
        case .some(let simulated) where !simulated.isEmpty:
            missingOptionalTools = simulated.split(separator: ",").map(String.init)
        default:
            let optionalReport = checker.check(tools: optionalTools)
            missingOptionalTools = optionalReport.missingTools.sorted()
            foundToolPaths.merge(optionalReport.foundTools) { current, _ in current }
        }

        let registry = AgentProviderRegistry()
        for agent in AgentKind.allCases {
            let plan = registry.provider(for: agent).launchPlan(
                goal: nil,
                settings: settings,
                baseEnvironment: [:]
            )
            let resolved: URL?
            if !plan.configuredPath.isEmpty,
               FileManager.default.isExecutableFile(atPath: plan.configuredPath) {
                resolved = URL(fileURLWithPath: plan.configuredPath)
            } else {
                resolved = locator.locate(plan.binaryName)
            }
            if let resolved {
                foundToolPaths[plan.binaryName] = resolved
            } else {
                missingAgents.append(agent)
            }
        }
    }
}
