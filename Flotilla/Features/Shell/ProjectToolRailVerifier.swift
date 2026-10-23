#if DEBUG || FLOTILLA_EPHEMERAL
import AppKit
import Foundation
import SessionKit

/// End-to-end rail walkthrough for issue #7. Runs inside the app process so it
/// can read its own accessibility tree without TCC, and drives the same
/// navigator APIs the rail buttons use.
@MainActor
enum ProjectToolRailVerifier {
    private static let reportURL = URL(fileURLWithPath: "/tmp/flotilla-rail-verify.json")

    static func runIfRequested(navigator: WorkspaceNavigator, store: AppStore) async {
        guard ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_RAIL"] == "1" else { return }
        try? await Task.sleep(for: .milliseconds(900))
        let report = await verify(navigator: navigator, store: store)
        write(report)
        if ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_RAIL_EXIT"] == "1" {
            // Give stderr a moment to flush before quit.
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }

    private static func verify(navigator: WorkspaceNavigator, store: AppStore) async -> Report {
        var checks: [Check] = []

        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: ok, detail: detail))
        }

        record("rail_present", findElement(identifier: AXID.projectToolRail.rawValue) != nil)
        for title in ["Git", "Issues", "Files", "Skills", "Rules"] {
            record("rail_item_\(title)", findElement(identifier: "ProjectToolRail.\(title)") != nil)
        }

        navigator.showHomeDashboard()
        await settle()
        record("home_git_disabled", axEnabled("ProjectToolRail.Git") == false)

        guard let project = store.projects.first else {
            record("has_project", false, "no projects — launch with FLOTILLA_DEMO_DATA=1")
            return Report(passed: false, checks: checks)
        }
        record("has_project", true, project.name)

        navigator.selection = .project(project.id)
        await settle()
        record("project_git_enabled", axEnabled("ProjectToolRail.Git") == true)
        record("project_no_active_tool", navigator.activeRailTool == nil)

        press("ProjectToolRail.Git")
        await settle()
        record("git_active", navigator.activeRailTool == .git, "\(navigator.selection)")
        record(
            "git_surface",
            findElement(identifier: "ProjectGit.SubTab-Commits") != nil
                || findElement(identifier: "ProjectGit.SubTab-Changes") != nil
        )

        press("ProjectToolRail.Git")
        await settle()
        record("git_reclick_stays", navigator.selection == .projectTool(project.id, .git))

        press("ProjectToolRail.Files")
        await settle()
        record("files_active", navigator.activeRailTool == .files, "\(navigator.selection)")
        record("files_destination", navigator.selection == .projectTool(project.id, .files))

        if let session = store.sessions.first(where: { $0.projectID == project.id }) {
            navigator.selection = .session(session.id)
            store.selectedSessionID = session.id
            await settle()
            record("session_tools_enabled", axEnabled("ProjectToolRail.Git") == true)
            record("session_no_active_tool", navigator.activeRailTool == nil)
            record(
                "folder_button_removed",
                findElement(identifier: AXID.toolbarOpenProjectFiles.rawValue) == nil
            )
            record(
                "git_sidebar_toggle_present",
                findElement(identifier: AXID.sessionBarGitSidebarToggle.rawValue) != nil
            )
            record(
                "review_or_screenshots_cluster",
                findElement(identifier: AXID.sessionBarScreenshotsToggle.rawValue) != nil
                    || findElement(identifierPrefix: "SessionBar") != nil
            )
            press("ProjectToolRail.Rules")
            await settle()
            record("rules_from_session", navigator.selection == .projectTool(project.id, .rules), "\(navigator.selection)")
        } else {
            record("project_session", false, "no project session")
        }

        if let general = store.sessions.first(where: { $0.projectID == nil }) {
            navigator.selection = .session(general.id)
            store.selectedSessionID = general.id
            await settle()
            record("general_git_disabled", axEnabled("ProjectToolRail.Git") == false)
        } else {
            record("general_session", false, "no general session")
        }

        navigator.selection = .allSessions
        navigator.presentation = .grid
        navigator.sessionGroup = .project(project.id)
        await settle()
        record("grid_project_filter_enables", axEnabled("ProjectToolRail.Git") == true
            || navigator.railProjectID(sessions: store.sessions) == project.id)

        navigator.sessionGroup = .all
        await settle()
        record(
            "grid_all_disables",
            navigator.railProjectID(sessions: store.sessions) == nil
        )

        let passed = checks.allSatisfy(\.passed)
        return Report(passed: passed, checks: checks)
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func write(_ report: Report) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report) else { return }
        try? data.write(to: reportURL, options: .atomic)
        let summary = report.checks
            .map { "\($0.passed ? "PASS" : "FAIL")  \($0.name)\($0.detail.isEmpty ? "" : " — \($0.detail)")" }
            .joined(separator: "\n")
        fputs("ProjectToolRailVerifier: \(report.passed ? "PASSED" : "FAILED")\n\(summary)\n→ \(reportURL.path)\n", stderr)
    }

    /// What a click does, minus the cursor: the button's own action.
    private static func press(_ identifier: String) {
        guard let element = findElement(identifier: identifier) else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    private static func axEnabled(_ identifier: String) -> Bool? {
        guard let element = findElement(identifier: identifier) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &value) == .success,
              let enabled = value as? Bool else { return nil }
        return enabled
    }

    private static func findElement(identifier: String) -> AXUIElement? {
        let root = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        return search(root, matching: { id in id == identifier })
    }

    private static func findElement(identifierPrefix: String) -> AXUIElement? {
        let root = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        return search(root, matching: { id in id.hasPrefix(identifierPrefix) })
    }

    private static func search(_ element: AXUIElement, matching: (String) -> Bool) -> AXUIElement? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &value) == .success,
           let id = value as? String, matching(id) {
            return element
        }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list {
            if let match = search(child, matching: matching) { return match }
        }
        return nil
    }

    private struct Check: Codable {
        let name: String
        let passed: Bool
        let detail: String
    }

    private struct Report: Codable {
        let passed: Bool
        let checks: [Check]
    }
}
#endif
