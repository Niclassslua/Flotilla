import Foundation
import SessionKit
import CompanionKit

/// Cursor Agent CLI companion control. The interactive TUI stays in tmux and
/// owns every decision: the phone mirrors the dialog Cursor itself shows and
/// answers it with the keys a person would press (docs/probe-cursor-companion.md).
///
/// Cursor's hooks can't stand in for that dialog. A hook `allow` doesn't skip
/// it, and nothing on the Mac answers a held hook, so the hooks only record.
@MainActor
final class CursorCompanionAdapter: CompanionSessionAdapter {
    var session: Session
    private let plans: URL
    private let screen: (UUID) async -> String?
    private let send: (Data) -> Void
    /// tmux-backed delivery (`AppStore.deliverMessage`): the only path
    /// confirmed to actually *submit* — a raw PTY write types the text into
    /// the composer but the TUI treats the trailing `\r` in the same bulk
    /// write as paste content, so it never submits (see
    /// `TmuxGoalDelivering`'s docstring).
    private let deliver: (String) async throws -> Void
    private var open: (dialog: Dialog, card: PendingInteraction)?
    private(set) var transcript = SessionTranscript()
    var pending: [PendingInteraction] { open.map { [$0.card] } ?? [] }

    init(
        session: Session,
        plans: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cursor/plans", isDirectory: true),
        screen: @escaping (UUID) async -> String?,
        send: @escaping (Data) -> Void,
        deliver: @escaping (String) async throws -> Void
    ) {
        self.session = session
        self.plans = plans
        self.screen = screen
        self.send = send
        self.deliver = deliver
    }

    // MARK: - Screen

    /// What Cursor is waiting on, read from the bottom of the pane.
    enum Dialog: Equatable {
        /// "Run this command?", "Allow this web fetch?": `y` runs, Tab runs
        /// and allowlists, `n` skips.
        case approval(question: String, subject: String, canAlwaysAllow: Bool)
        /// "Ready to build?": `b` builds, `p` asks for a revision.
        case plan(path: String?)
        /// Someone at the Mac is typing a skip reason or plan revision.
        case typing
    }

    nonisolated static func dialog(in screen: String) -> Dialog? {
        let lines = screen.components(separatedBy: "\n").suffix(60).map {
            $0.trimmingCharacters(in: CharacterSet(charactersIn: "│┃ "))
        }
        if lines.contains(where: {
            $0.hasPrefix("→ Tell the agent what to do instead") || $0.hasPrefix("→ Describe how to revise the plan")
        }) {
            return .typing
        }
        if let ask = lines.lastIndex(where: { $0 == "Ready to build?" }),
           lines[ask...].contains(where: { $0.hasSuffix("(b)") }) {
            return .plan(path: planPath(in: Array(lines[..<ask])))
        }
        guard let yes = lines.lastIndex(where: { $0.hasSuffix("(y)") }),
              lines[yes...].contains(where: { $0.hasSuffix("(esc or n)") }),
              let question = lines[..<yes].lastIndex(where: { $0.hasSuffix("?") })
        else { return nil }
        let top = lines[..<question].lastIndex(where: { $0.hasPrefix("──") }) ?? question - 1
        let subject = lines[(top + 1)..<question]
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return .approval(
            question: lines[question],
            subject: subject,
            canAlwaysAllow: lines[yes...].contains { $0.hasSuffix("(tab)") }
        )
    }

    /// `Saved to Users/…/.cursor/plans/Name-1a2b.plan.md`, wrapped over as
    /// many lines as the pane needs and printed without its leading slash.
    nonisolated static func planPath(in lines: [String]) -> String? {
        guard let start = lines.lastIndex(where: { $0.hasPrefix("Saved to ") }) else { return nil }
        var path = String(lines[start].dropFirst("Saved to ".count))
        var next = start + 1
        while !path.hasSuffix(".plan.md"), next < lines.count, !lines[next].isEmpty {
            path += lines[next]
            next += 1
        }
        guard path.hasSuffix(".plan.md") else { return nil }
        return path.hasPrefix("/") ? path : "/" + path
    }

    /// The composer row — the last `→` line — while no dialog covers it.
    nonisolated static func composerLine(in screen: String) -> String? {
        screen.split(separator: "\n").last {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("→ ")
        }.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The text typed into Cursor's composer, or `nil` when it only shows its
    /// placeholder.
    nonisolated static func composerDraft(in screen: String) -> String? {
        guard let line = composerLine(in: screen) else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        let placeholders = ["Add a follow-up", "Plan, search, build anything"]
        return text.isEmpty || placeholders.contains(where: text.hasPrefix) ? nil : text
    }

    /// Cursor offers "ctrl+c to stop" beside the composer only mid-turn.
    nonisolated static func isWorking(_ screen: String) -> Bool {
        composerLine(in: screen)?.contains("ctrl+c") == true
    }

    private func card(for dialog: Dialog) -> PendingInteraction? {
        switch dialog {
        case .typing:
            return nil
        case let .approval(question, subject, canAlwaysAllow):
            let tool: String
            var summary = subject
            if subject.hasPrefix("$") {
                tool = "Shell"
                summary = String(subject.drop { $0 == "$" || $0 == " " })
                // `$  npm test in .` — the trailing directory is Cursor's.
                if let range = summary.range(of: " in ", options: .backwards),
                   summary[range.upperBound...].first.map({ "/~.".contains($0) }) == true {
                    summary = String(summary[..<range.lowerBound])
                }
            } else if let range = subject.range(of: "Web Fetch: ") {
                tool = "WebFetch"
                summary = String(subject[range.upperBound...])
            } else {
                tool = question.hasSuffix("?") ? String(question.dropLast()) : question
            }
            return PendingInteraction(kind: .permission(PermissionRequest(
                tool: tool,
                summary: summary.isEmpty ? question : summary,
                allowsAlwaysAllow: canAlwaysAllow,
                allowsDenyAndStop: true
            )))
        case let .plan(path):
            // A path wrapped at a space loses that space on screen.
            let saved = path.map(URL.init(fileURLWithPath:)).flatMap {
                FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
            }
            let markdown = Self.planMarkdown(at: saved ?? newestPlan())
            return PendingInteraction(kind: .plan(PlanProposal(
                title: ClaudePermissionPayload.planTitle(markdown),
                markdown: markdown
            )))
        }
    }

    private func newestPlan() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: plans, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files.filter { $0.pathExtension == "md" }.max {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
    }

    /// The plan body without Cursor's id comment and todo frontmatter.
    nonisolated static func planMarkdown(at url: URL?) -> String {
        guard let url, var text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        if text.hasPrefix("<!--"), let end = text.range(of: "-->") {
            text = String(text[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Refresh

    func refresh() async throws {
        guard let current = await screen(session.id) else { return }
        let dialog = Self.dialog(in: current)
        if let dialog, dialog == open?.dialog {
            // Same dialog still open: keep the card the phone already shows.
        } else if let dialog, let card = card(for: dialog) {
            open = (dialog, card)
        } else {
            open = nil
        }
    }

    // MARK: - Actions

    func sendPrompt(_ text: String) async throws {
        if let current = await currentScreen() {
            if Self.dialog(in: current) != nil {
                throw ProviderConnectionError.rejected("Answer the terminal dialog first.")
            }
            // Cursor has no draft stash (Ctrl-S types a literal "s"), and
            // anything already in the composer would be sent glued to the
            // phone's prompt.
            if Self.composerDraft(in: current) != nil {
                throw ProviderConnectionError.rejected("Send or clear the unsent text in the Mac terminal first.")
            }
        }
        try await deliver(text)
    }

    func stop() async throws {
        guard let current = await currentScreen(),
              Self.isWorking(current) || Self.dialog(in: current) != nil else { return }
        await interrupt(current)
    }

    /// Escape doesn't interrupt Cursor — in a dialog it only flips to the
    /// skip-reason prompt. Ctrl-C does, but on an idle composer it arms
    /// "Press Ctrl+C again to exit", so it is only sent mid-turn. In a dialog
    /// Ctrl-C just rejects the tool call and the turn goes on, so a second
    /// one follows once Cursor is working again.
    private func interrupt(_ current: String) async {
        open = nil
        if Self.dialog(in: current) != nil {
            send(Data([0x03]))
            guard await waitForScreen(where: { Self.dialog(in: $0) == nil && Self.isWorking($0) }) else { return }
        }
        send(Data([0x03]))
        try? await Task.sleep(for: .milliseconds(800))
        // The interrupted prompt comes back into the composer, where it would
        // block (and later prefix) the next phone prompt.
        await clearComposer()
    }

    func answer(_ id: UUID, with answer: InteractionAnswer) async throws -> AnswerOutcome {
        guard let current = await currentScreen() else { throw ProviderConnectionError.disconnected }
        // Last check before typing: a Mac answer must not send these keys
        // into the ordinary composer.
        guard let request = open, request.card.id == id, Self.dialog(in: current) == request.dialog else {
            return .alreadyAnswered
        }
        open = nil
        switch (request.dialog, answer) {
        case (.approval, .allow):
            send(Data("y".utf8))
        case (.approval, .allowWithNote(let note)):
            send(Data("y".utf8))
            if !note.isEmpty { try await deliver(note) }
        case (.approval(_, _, true), .alwaysAllow):
            send(Data("\t".utf8))
        case (.approval, .deny):
            try await skip(note: "")
        case (.approval, .denyWithNote(let note)):
            try await skip(note: note)
        case (.approval, .denyAndStop):
            await interrupt(current)
        case (.plan, .approvePlan):
            send(Data("b".utf8))
        case (.plan, .revisePlan(let note)):
            send(Data("p".utf8))
            guard await waitForScreen(containing: "Describe how to revise the plan") else {
                throw ProviderConnectionError.rejected("Cursor didn't open the revision prompt.")
            }
            try await deliver(note)
        default:
            throw ProviderConnectionError.rejected("This dialog doesn't offer that action.")
        }
        return .accepted
    }

    /// `n` skips. Shell commands then ask what to do instead (empty Enter
    /// just skips); a web fetch skips at once, so its note follows as a prompt.
    private func skip(note: String) async throws {
        send(Data("n".utf8))
        if await waitForScreen(containing: "Tell the agent what to do instead") {
            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                send(Data("\r".utf8))
            } else {
                try await deliver(note)
            }
        } else if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try await deliver(note)
        }
    }

    /// A pane capture occasionally times out under load; one miss shouldn't
    /// fail a phone action that a person is waiting on.
    private func currentScreen() async -> String? {
        for attempt in 0..<3 {
            if let current = await screen(session.id) { return current }
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(200)) }
        }
        return nil
    }

    private func waitForScreen(containing text: String) async -> Bool {
        await waitForScreen { $0.contains(text) }
    }

    private func waitForScreen(timeout: Duration = .seconds(2), where matches: (String) -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let current = await screen(session.id), matches(current) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    /// Ctrl-U empties the current line; Backspace then joins the line above.
    /// One key per write: Cursor drops a burst of editing keys.
    private func clearComposer() async {
        for _ in 0..<40 {
            guard let current = await screen(session.id),
                  Self.dialog(in: current) == nil,
                  Self.composerDraft(in: current) != nil else { return }
            send(Data([0x15]))
            try? await Task.sleep(for: .milliseconds(120))
            send(Data([0x7F]))
            try? await Task.sleep(for: .milliseconds(120))
        }
    }

    func close() { }
}
