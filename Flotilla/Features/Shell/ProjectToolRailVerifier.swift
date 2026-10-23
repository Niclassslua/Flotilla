#if DEBUG || FLOTILLA_EPHEMERAL
import AppKit
import Foundation
import SessionKit
import DesignSystem

/// End-to-end rail walkthrough for issue #7. Runs inside the app process so it
/// can read its own accessibility tree and capture its own window without TCC,
/// which is what lets it run while the installed Flotilla (same bundle ID as
/// the UI-test target) is open.
///
/// Rail buttons, menu items, toolbar Back/Forward, and palette rows are
/// pressed through accessibility — their real actions. List clicks are
/// simulated by writing `sidebarSelection`, which is exactly what the List's
/// selection binding does on a click.
///
/// `FLOTILLA_VERIFY_RAIL=1` runs it; `FLOTILLA_VERIFY_RAIL_SHOTS=<dir>` also
/// saves a window capture per step; `FLOTILLA_VERIFY_RAIL_EXIT=1` quits after.
@MainActor
enum ProjectToolRailVerifier {
    private static let reportURL = URL(fileURLWithPath: "/tmp/flotilla-rail-verify.json")
    private static let tools: [(tool: ProjectTool, surface: (String) -> Bool)] = [
        (.git, { $0.hasPrefix("ProjectGit.") }),
        (.issues, { $0.hasPrefix("ProjectIssues.") }),
        (.files, { $0.hasPrefix(AXID.fileBrowser.rawValue) }),
        (.skills, { $0.hasPrefix("Knowledge.") }),
        (.rules, { $0 == AXID.rulesPanel.rawValue || $0.hasPrefix("Knowledge.") }),
    ]

    static func runIfRequested(navigator: WorkspaceNavigator, store: AppStore, settings: SettingsViewModel) async {
        let env = ProcessInfo.processInfo.environment
        guard env["FLOTILLA_VERIFY_RAIL"] == "1" else { return }
        try? await Task.sleep(for: .milliseconds(1500))
        let shots = env["FLOTILLA_VERIFY_RAIL_SHOTS"].map { URL(fileURLWithPath: $0) }
        let report = await verify(navigator: navigator, store: store, settings: settings, shots: shots)
        write(report)
        if env["FLOTILLA_VERIFY_RAIL_EXIT"] == "1" {
            try? await Task.sleep(for: .milliseconds(200))
            NSApp.terminate(nil)
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    private static func verify(
        navigator: WorkspaceNavigator,
        store: AppStore,
        settings: SettingsViewModel,
        shots: URL?
    ) async -> Report {
        var checks: [Check] = []
        func record(_ name: String, _ ok: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: ok, detail: detail))
        }
        func shot(_ name: String) {
            guard let shots else { return }
            capture(to: shots.appendingPathComponent("\(name).png"))
        }
        let toolIDs = ProjectTool.allCases.map { AXID.projectToolRailItem($0.title) }
        func toolsEnabled() -> [Bool?] { toolIDs.map(axEnabled) }
        func selectedRailItems() -> [String] {
            ([AXID.sidebarOverview.rawValue] + toolIDs).filter { axSelected($0) == true }
        }
        let originalLabels = settings.settings.workspace.sidebarRailLabels
        settings.settings.workspace.sidebarRailLabels = false
        await settle()

        // MARK: Structure
        let rail = findElement(identifier: AXID.projectToolRail.rawValue)
        record("rail_present", rail != nil)
        let ys = ([AXID.sidebarOverview.rawValue] + toolIDs).map { axFrame($0)?.minY }
        let knownYs = ys.compactMap { $0 }
        record(
            "rail_order_home_git_issues_files_skills_rules",
            knownYs.count == ys.count && knownYs == knownYs.sorted(),
            "\(ys.map { $0.map { Int($0) } ?? -1 })"
        )
        let homeInRail = rail.flatMap { search($0) { $0 == AXID.sidebarOverview.rawValue } } != nil
        record("home_lives_in_rail", homeInRail)
        record("home_only_once", countElements(identifier: AXID.sidebarOverview.rawValue) == 1)
        let railFrame = axFrame(AXID.projectToolRail.rawValue)
        let listFrame = axFrame(AXID.sidebarSearch.rawValue)
        record(
            "rail_left_of_session_list",
            railFrame != nil && listFrame != nil && railFrame!.maxX <= listFrame!.minX,
            "rail=\(String(describing: railFrame)) search=\(String(describing: listFrame))"
        )

        // MARK: Home — always enabled; disables the project tools
        navigator.showHomeDashboard()
        await settle()
        shot("01-home")
        record("home_selected_on_home", selectedRailItems() == [AXID.sidebarOverview.rawValue], "\(selectedRailItems())")
        record("home_tools_disabled", toolsEnabled().allSatisfy { $0 == false }, "\(toolsEnabled())")

        guard let project = store.projects.first(where: { p in store.sessions.contains { $0.projectID == p.id } })
            ?? store.projects.first
        else {
            record("has_project", false, "no projects — launch with FLOTILLA_DEMO_DATA=1")
            return Report(passed: false, checks: checks)
        }
        record("has_project", true, project.name)

        // MARK: Project header click → overview, tools enabled, none active
        navigator.sidebarSelection = [.project(project.id)]
        await settle()
        record("project_click_opens_overview", navigator.selection == .project(project.id), "\(navigator.selection)")
        record("project_tools_enabled", toolsEnabled().allSatisfy { $0 == true }, "\(toolsEnabled())")
        record("project_nothing_highlighted", selectedRailItems().isEmpty, "\(selectedRailItems())")
        record("project_home_enabled", axEnabled(AXID.sidebarOverview.rawValue) == true)

        // MARK: Every tool from the overview, one click each
        for (tool, surface) in tools {
            press(AXID.projectToolRailItem(tool.title))
            await settle()
            let name = tool.title.lowercased()
            shot("02-\(name)")
            record("\(name)_opens_from_overview", navigator.selection == .projectTool(project.id, tool), "\(navigator.selection)")
            record("\(name)_surface_shown", findElement(matching: surface) != nil)
            record(
                "\(name)_only_it_highlighted",
                selectedRailItems() == [AXID.projectToolRailItem(tool.title)],
                "\(selectedRailItems())"
            )
            record("\(name)_names_project", findElement(label: "\(project.name), \(tool.title)") != nil)
            record("\(name)_home_enabled", axEnabled(AXID.sidebarOverview.rawValue) == true)
        }
        press(AXID.projectToolRailItem(ProjectTool.rules.title))
        await settle()
        record("reclick_active_tool_stays", navigator.selection == .projectTool(project.id, .rules), "\(navigator.selection)")

        // MARK: Tool → project header click → overview
        navigator.sidebarSelection = [.project(project.id)]
        await settle()
        record("tool_then_project_click_opens_overview", navigator.selection == .project(project.id), "\(navigator.selection)")

        // MARK: Session context
        if let session = store.sessions.first(where: { $0.projectID == project.id }) {
            navigator.sidebarSelection = [.session(session.id)]
            await settle()
            shot("03-session")
            record("session_click_opens_terminal", navigator.selection == .session(session.id), "\(navigator.selection)")
            record("session_tools_enabled", toolsEnabled().allSatisfy { $0 == true }, "\(toolsEnabled())")
            record("session_nothing_highlighted", selectedRailItems().isEmpty, "\(selectedRailItems())")
            record("session_folder_button_removed", findElement(identifier: AXID.toolbarOpenProjectFiles.rawValue) == nil)
            record("session_git_sidebar_toggle", findElement(identifier: AXID.sessionBarGitSidebarToggle.rawValue) != nil)
            // Screenshots only appear once the agent has taken some; Review is
            // the cluster's standing member.
            record("session_review_button", findElement(identifier: AXID.sessionBarReview(session.title)) != nil)

            for (tool, surface) in tools {
                navigator.sidebarSelection = [.session(session.id)]
                await settle()
                press(AXID.projectToolRailItem(tool.title))
                await settle()
                let name = tool.title.lowercased()
                record("\(name)_opens_from_session", navigator.selection == .projectTool(project.id, tool), "\(navigator.selection)")
                record("\(name)_surface_from_session", findElement(matching: surface) != nil)
            }

            // Tool open → session click returns to that session's terminal.
            navigator.sidebarSelection = [.session(session.id)]
            await settle()
            record("tool_then_session_click_opens_terminal", navigator.selection == .session(session.id), "\(navigator.selection)")

            // Menu items resolve from the session to its project.
            for (title, tool) in [("Git", ProjectTool.git), ("Files", .files), ("Rules", .rules)] {
                navigator.sidebarSelection = [.session(session.id)]
                await settle()
                let pressed = pressMenuItem(title)
                await settle()
                record(
                    "menu_\(title.lowercased())_from_session",
                    pressed && navigator.selection == .projectTool(project.id, tool),
                    "pressed=\(pressed) \(navigator.selection)"
                )
            }

            // Selecting another session must not reset the large Git view.
            navigator.openProjectTool(.git, projectID: project.id)
            await settle()
            let root = navigator.projectGitScope(for: project.id) ?? project.rootPath
            let graph = navigator.projectGraphViewModel(for: root, gitService: store.gitService)
            graph.selectedBranchFilter = "verifier/branch"
            if let other = store.sessions.first(where: { $0.projectID == project.id && $0.id != session.id }) {
                navigator.sidebarSelection = [.session(other.id)]
                await settle()
            }
            navigator.sidebarSelection = [.session(session.id)]
            await settle()
            press(AXID.projectToolRailItem(ProjectTool.git.title))
            await settle()
            let kept = navigator.projectGraphViewModel(for: root, gitService: store.gitService).selectedBranchFilter
            record("git_branch_filter_survives_sessions", kept == "verifier/branch", kept ?? "nil")
            graph.selectedBranchFilter = nil
        } else {
            record("project_session", false, "no session in \(project.name)")
        }

        // MARK: Back / Forward through tools
        navigator.sidebarSelection = [.project(project.id)]
        await settle()
        press(AXID.projectToolRailItem(ProjectTool.git.title))
        await settle()
        press(AXID.projectToolRailItem(ProjectTool.files.title))
        await settle()
        press(AXID.toolbarBack.rawValue)
        await settle()
        record("toolbar_back_to_previous_tool", navigator.selection == .projectTool(project.id, .git), "\(navigator.selection)")
        press(AXID.toolbarForward.rawValue)
        await settle()
        record("toolbar_forward_to_next_tool", navigator.selection == .projectTool(project.id, .files), "\(navigator.selection)")
        let backPressed = pressMenuItem("Back")
        await settle()
        record(
            "menu_back_to_previous_tool",
            backPressed && navigator.selection == .projectTool(project.id, .git),
            "pressed=\(backPressed) \(navigator.selection)"
        )

        // MARK: Command palette resolves to the same destination
        navigator.sidebarSelection = [.project(project.id)]
        await settle()
        navigator.presentedSheet = .commandPalette
        await settle()
        press("CommandPalette.Row-Open Git")
        await settle()
        record("palette_open_git", navigator.selection == .projectTool(project.id, .git), "\(navigator.selection)")
        record("palette_dismissed", navigator.presentedSheet == nil)
        navigator.presentedSheet = nil
        await settle()

        // MARK: Home from a tool
        press(AXID.sidebarOverview.rawValue)
        await settle()
        record("home_press_from_tool", navigator.selection == .overview, "\(navigator.selection)")
        record("home_press_disables_tools", toolsEnabled().allSatisfy { $0 == false }, "\(toolsEnabled())")
        let menuGitPressedOnHome = pressMenuItem("Git")
        await settle()
        record("menu_git_inert_on_home", navigator.selection == .overview, "pressed=\(menuGitPressedOnHome) \(navigator.selection)")

        // MARK: General session
        if let general = store.sessions.first(where: { $0.projectID == nil }) {
            navigator.sidebarSelection = [.session(general.id)]
            await settle()
            record("general_tools_disabled", toolsEnabled().allSatisfy { $0 == false }, "\(toolsEnabled())")
            record("general_home_enabled", axEnabled(AXID.sidebarOverview.rawValue) == true)
        } else {
            record("general_session", true, "SKIPPED — no General session in this data")
        }

        // MARK: Collections
        navigator.selection = .allSessions
        navigator.presentation = .grid
        navigator.sessionGroup = .project(project.id)
        await settle()
        shot("04-grid-one-project")
        record("grid_one_project_enables", toolsEnabled().allSatisfy { $0 == true }, "\(toolsEnabled())")
        navigator.sessionGroup = .all
        await settle()
        record("grid_all_disables", toolsEnabled().allSatisfy { $0 == false }, "\(toolsEnabled())")
        record("grid_home_enabled", axEnabled(AXID.sidebarOverview.rawValue) == true)

        // MARK: Labels preference + minimum window size
        navigator.sidebarSelection = [.project(project.id)]
        await settle()
        press(AXID.projectToolRailItem(ProjectTool.git.title))
        await settle()
        let window = NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }
        let savedFrame = window?.frame
        for labels in [false, true] {
            settings.settings.workspace.sidebarRailLabels = labels
            await settle()
            let tag = labels ? "labels" : "icons"
            let expected = labels ? FlotillaLayoutWidth.toolRailLabeledWidth : FlotillaLayoutWidth.toolRailWidth
            let width = axFrame(AXID.projectToolRail.rawValue)?.width ?? 0
            record("rail_width_\(tag)", abs(width - expected) < 1, "\(width) vs \(expected)")
            // SwiftUI folds a button's label text into the button, so the
            // label shows up as height under the 40pt glyph, not as an element.
            let heights = ([AXID.sidebarOverview.rawValue] + toolIDs).map { axFrame($0)?.height ?? 0 }
            record(
                "rail_labels_\(tag)",
                heights.allSatisfy { labels ? $0 > 48 : $0 <= 44 },
                "\(heights)"
            )
            if let window {
                window.setContentSize(NSSize(width: 1, height: 1)) // clamps to the window's minimum
                await settle()
                let content = window.contentLayoutRect.size
                let screenTop = NSScreen.screens.first?.frame.maxY ?? 0
                // AX frames are top-left based; convert the window to match.
                let frame = window.frame
                let windowAX = CGRect(x: frame.minX, y: screenTop - frame.maxY, width: frame.width, height: frame.height)
                let items = ([AXID.sidebarOverview.rawValue] + toolIDs).compactMap(axFrame)
                record(
                    "min_window_rail_visible_\(tag)",
                    items.count == 6 && items.allSatisfy { windowAX.insetBy(dx: -1, dy: -1).contains($0) },
                    "content=\(Int(content.width))x\(Int(content.height))"
                )
                let search = axFrame(AXID.sidebarSearch.rawValue)
                record("min_window_session_list_visible_\(tag)", (search?.width ?? 0) > 120, "search.width=\(search?.width ?? 0)")
                record("min_window_tool_surface_\(tag)", findElement(matching: tools[0].surface) != nil)
                shot("05-min-window-\(tag)")
            }
        }
        if let window, let savedFrame { window.setFrame(savedFrame, display: true) }
        settings.settings.workspace.sidebarRailLabels = originalLabels
        await settle()

        // MARK: Deleted project leaves no stale tool target
        navigator.openProjectTool(.files, projectID: project.id)
        navigator.pruneProjectDestinations(against: [])
        record("deleted_project_prunes_tool", navigator.selection == .overview, "\(navigator.selection)")

        return Report(passed: checks.allSatisfy(\.passed), checks: checks)
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(450))
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

    // MARK: Window capture

    private typealias WindowImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// `CGWindowListCreateImage` is unavailable in the current SDK but still
    /// exported; capturing the process's own window needs no permission.
    private static func capture(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }),
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage")
        else { return }
        let create = unsafeBitCast(symbol, to: WindowImage.self)
        // .null bounds = the window's own; 8 = optionIncludingWindow; 1 = boundsIgnoreFraming.
        guard let image = create(.null, 8, UInt32(window.windowNumber), 1)?.takeRetainedValue() else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Accessibility

    /// What a click does, minus the cursor: the button's own action.
    private static func press(_ identifier: String) {
        guard let element = findElement(identifier: identifier) else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
    }

    /// Presses an enabled menu-bar item by title. False when missing or disabled.
    private static func pressMenuItem(_ title: String) -> Bool {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        let menuBar = unsafeDowncast(bar, to: AXUIElement.self)
        guard let item = searchTree(menuBar, where: {
            string($0, kAXRoleAttribute) == kAXMenuItemRole && string($0, kAXTitleAttribute) == title
        }), bool(item, kAXEnabledAttribute) == true else { return false }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private static func axEnabled(_ identifier: String) -> Bool? {
        findElement(identifier: identifier).flatMap { bool($0, kAXEnabledAttribute) }
    }

    private static func axSelected(_ identifier: String) -> Bool? {
        findElement(identifier: identifier).flatMap { bool($0, kAXSelectedAttribute) }
    }

    private static func axFrame(_ identifier: String) -> CGRect? {
        guard let element = findElement(identifier: identifier) else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size
        else { return nil }
        var point = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(unsafeDowncast(position, to: AXValue.self), .cgPoint, &point)
        AXValueGetValue(unsafeDowncast(size, to: AXValue.self), .cgSize, &extent)
        return CGRect(origin: point, size: extent)
    }

    private static func findElement(identifier: String) -> AXUIElement? {
        findElement { $0 == identifier }
    }

    private static func findElement(matching: (String) -> Bool) -> AXUIElement? {
        search(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier), matching: matching)
    }

    private static func findElement(label: String) -> AXUIElement? {
        searchTree(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)) {
            string($0, kAXDescriptionAttribute) == label
        }
    }

    private static func countElements(identifier: String) -> Int {
        var count = 0
        func walk(_ element: AXUIElement) {
            if string(element, kAXIdentifierAttribute) == identifier { count += 1 }
            children(element).forEach(walk)
        }
        walk(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
        return count
    }

    private static func search(_ element: AXUIElement, matching: (String) -> Bool) -> AXUIElement? {
        searchTree(element) { string($0, kAXIdentifierAttribute).map(matching) ?? false }
    }

    private static func searchTree(_ element: AXUIElement, where predicate: (AXUIElement) -> Bool) -> AXUIElement? {
        if predicate(element) { return element }
        for child in children(element) {
            if let match = searchTree(child, where: predicate) { return match }
        }
        return nil
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
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
