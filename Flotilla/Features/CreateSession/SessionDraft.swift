import Foundation
import SwiftUI
import AppKit
import SessionKit
import AgentKit
import SettingsKit
import GitKit

/// The session being configured, shared by all four designs.
///
/// The designs are independent views with nothing else in common — but they all
/// edit *one* draft, which is what makes the ⌘1–⌘4 switcher useful: type a goal
/// in Composer, hit ⌘4, and the goal is still there in Launchpad. Without a
/// shared draft the switcher could only compare empty windows.
@Observable
@MainActor
final class SessionDraft {
    var goal: String
    var projectChoice: ProjectChoice {
        // An issue belongs to one repository; carrying it to another project
        // would launch with a goal and branch named for the wrong codebase.
        didSet {
            if linkedIssue != nil, projectChoice.folder != oldValue.folder {
                clearIssue()
            }
        }
    }
    /// The GitHub issue the goal was filled from. Survives edits to the goal —
    /// adding a note to an issue's text is still working on that issue.
    private(set) var linkedIssue: IssueLink?
    /// What the user had typed before choosing an issue, so unlinking gives it
    /// back instead of leaving the issue text behind.
    private var goalBeforeIssue: String?
    var agent: AgentKind
    var model = ""
    var effort: AgentEffort = .medium
    var initialMode: SessionMode = .act
    var createWorktree: Bool
    /// Images sent alongside the goal; see `SessionAttachment`.
    private(set) var attachments: [SessionAttachment] = []
    private(set) var isCreating = false

    let openCodeSubscription: OpenCodeSubscription
    /// Whether an empty goal blocks launching. The modal launcher allows it —
    /// opening a bare interactive agent in a checkout is a real thing to want,
    /// and you had to deliberately open the window to get there. The home
    /// composer is always on screen and a stray ⌘↩ is far too easy, so it
    /// insists on an objective.
    private let requiresGoal: Bool
    private let fetchBeforeCreatingWorktree: Bool
    private let store: AppStore

    init(
        store: AppStore,
        initialProject: Project?,
        initialGoal: String,
        createWorktreeByDefault: Bool,
        fetchBeforeCreatingWorktree: Bool,
        defaultAgent: AgentKind,
        openCodeSubscription: OpenCodeSubscription,
        requiresGoal: Bool = false
    ) {
        self.store = store
        self.requiresGoal = requiresGoal
        self.goal = initialGoal
        self.projectChoice = initialProject.map { ProjectChoice.known($0) } ?? .general
        self.agent = defaultAgent
        self.createWorktree = createWorktreeByDefault
        self.fetchBeforeCreatingWorktree = fetchBeforeCreatingWorktree
        self.openCodeSubscription = openCodeSubscription
    }

    // MARK: - Derived state

    /// A general session has nothing to isolate — worktree choice only applies
    /// once a folder is picked.
    var supportsWorktree: Bool { !projectChoice.isGeneral }

    var effectiveCheckoutMode: CheckoutMode {
        createWorktree && supportsWorktree ? .newWorktree : .mainCheckout
    }

    var canLaunch: Bool {
        guard !isCreating else { return false }
        return requiresGoal ? !effectiveGoal.isEmpty || !attachments.isEmpty : true
    }

    var trimmedGoal: String {
        goal.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModel: String? {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var title: String {
        SessionLaunchPreview.derivedTitle(goal: effectiveGoal, projectChoice: projectChoice)
    }

    var preview: SessionLaunchPreview {
        SessionLaunchPreview.resolve(
            goal: effectiveGoal,
            projectChoice: projectChoice,
            agent: agent,
            model: trimmedModel,
            effort: agent.supportsEffortSelection ? effort : nil,
            createWorktree: createWorktree && supportsWorktree,
            namingSource: store.namingSource,
            worktreeBaseDirectory: store.worktreeBaseDirectory,
            generalSessionDirectory: store.generalSessionDirectory,
            linkedIssue: linkedIssue
        )
    }

    // MARK: - Issues

    /// The repository issues are listed from; `nil` for a general session.
    var issueRepository: URL? { projectChoice.folder }

    /// Fills the goal from `issue` (which should carry its body) and links it,
    /// so the session is titled `#<n> <title>` and branched `issue-<n>-…`.
    func apply(issue: GhIssue) {
        if linkedIssue == nil {
            goalBeforeIssue = goal
        }
        linkedIssue = IssueLink(number: issue.number, title: issue.title, url: issue.url)
        goal = Self.goal(for: issue)
    }

    func clearIssue() {
        guard linkedIssue != nil else { return }
        linkedIssue = nil
        goal = goalBeforeIssue ?? ""
        goalBeforeIssue = nil
    }

    /// The issue's own words, framed so the agent links its work back to it.
    static func goal(for issue: GhIssue) -> String {
        var text = "#\(issue.number) \(issue.title)"
        let body = issue.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !body.isEmpty {
            text += "\n\n\(body)"
        }
        text += "\n\nThis is GitHub issue #\(issue.number) (\(issue.url.absoluteString)). Reference it in the pull request (\"Closes #\(issue.number)\")."
        return text
    }

    /// Known projects newest-first, with the general option pinned at the top
    /// and any ad-hoc folder the user picked or dropped kept visible so the
    /// current selection is never missing from its own list.
    var choices: [ProjectChoice] {
        var result: [ProjectChoice] = [.general]
        result.append(contentsOf: ProjectChoiceCatalog.recentChoices(store: store))
        if case .custom = projectChoice, !result.contains(projectChoice) {
            result.append(projectChoice)
        }
        return result
    }

    func filteredChoices(query: String) -> [ProjectChoice] {
        ProjectChoiceCatalog.filter(choices, query: query)
    }

    /// Filtering searches everything; an empty query shows only the most
    /// recent few. The home composer renders these as tiles inside a dashboard
    /// that already scrolls, so an unbounded grid would push the rest of the
    /// page off screen for anyone with a lot of projects.
    func filteredChoices(query: String, restingLimit: Int) -> [ProjectChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty else { return filteredChoices(query: trimmed) }
        return Array(choices.prefix(restingLimit))
    }

    /// How many known projects the resting list is hiding, for a "+N more" hint.
    func hiddenChoiceCount(restingLimit: Int) -> Int {
        max(0, choices.count - restingLimit)
    }

    // MARK: - Attachments

    func attach(_ newAttachments: [SessionAttachment]) {
        attachments.append(contentsOf: newAttachments)
    }

    func removeAttachment(_ id: SessionAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Mutation

    /// Resolves a folder to a known project when one already tracks that path —
    /// the same match `AppStore.createSession` makes — so a dropped folder
    /// shows its real project name instead of appearing as a stranger.
    func select(folder: URL) {
        if let existing = store.projects.first(where: { $0.rootPath == folder }) {
            projectChoice = .known(existing)
        } else {
            projectChoice = .custom(folder)
        }
    }

    /// A model chosen for one agent is almost never valid for another, so
    /// switching agents resets it rather than carrying a stale value forward.
    /// Effort is clamped by `EffortLevelPicker` against the new agent's catalog.
    func selectAgent(_ newAgent: AgentKind) {
        guard newAgent != agent else { return }
        agent = newAgent
        model = ""
    }

    /// Called from each design's `onChange(of: draft.goal)`. Auto-promotes to
    /// plan mode when the user types `/plan`; never auto-demotes (use the chip
    /// to switch back to Act, or clear the goal).
    func syncModeFromGoal() {
        if trimmedGoal.hasPrefix("/plan") {
            initialMode = .plan
        }
    }

    // MARK: - Launch

    /// Returns the created session's ID, or `nil` if creation failed — in which
    /// case `store.lastCreationError` carries the reason and the window stays
    /// open so the user can correct and retry.
    func launch(opensSession: Bool = true) async -> UUID? {
        isCreating = true
        defer { isCreating = false }

        // Strip a leading /plan command that the user typed as a shortcut.
        // The command is preserved in the text field while typing so keyboard
        // synthesis never sees the field change under it; normalization happens
        // here at launch time so the delivered goal is clean.
        let normalizedGoal = effectiveGoal
        let effectiveMode = initialMode
        return await store.createSession(
            title: SessionLaunchPreview.derivedTitle(goal: normalizedGoal, projectChoice: projectChoice),
            goal: normalizedGoal,
            agent: agent,
            model: trimmedModel,
            effort: agent.supportsEffortSelection ? effort : nil,
            initialMode: effectiveMode,
            projectFolder: projectChoice.folder,
            checkoutMode: effectiveCheckoutMode,
            deliverGoal: !normalizedGoal.isEmpty || !attachments.isEmpty,
            fetchBeforeCreatingWorktree: fetchBeforeCreatingWorktree,
            selectAfterCreating: opensSession,
            linkedIssue: linkedIssue,
            attachments: attachments
        )
    }

    /// Goal with the leading `/plan ` trigger stripped, used at launch time.
    var effectiveGoal: String {
        let t = trimmedGoal
        if t.hasPrefix("/plan ") {
            return String(t.dropFirst(6))
        }
        if t == "/plan" {
            return ""
        }
        return t
    }

    /// Clears the objective and its attachments while keeping agent, model, effort and workspace.
    /// The composer that stays on screen after launching should be ready for
    /// the next task, not reset to factory defaults the user already changed.
    func clearGoal() {
        goal = ""
        attachments = []
        initialMode = .act
        linkedIssue = nil
        goalBeforeIssue = nil
    }

    // MARK: - Folder panel

    /// The `NSOpenPanel` escape hatch, now a fallback rather than the only way
    /// in. A folder chosen here is registered as a project so it appears in the
    /// recents list next time instead of demanding another browse.
    func chooseFolderFromPanel() {
        if store.isUITestingFixtureMode {
            select(folder: AppEnvironment.uiTestFixtureProjectPath)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Project"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.addProject(at: url)
        select(folder: url)
    }
}
