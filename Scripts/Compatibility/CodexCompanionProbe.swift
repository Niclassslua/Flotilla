import Foundation
import SessionKit
import CompanionKit
import Darwin

@main struct Verify {
    @MainActor static func main() async {
        do { try await run() }
        catch { log("FAIL \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        if CommandLine.arguments.count == 3 {
            var s = Session(title: "Read-only attach", goal: "Test", agent: .codexCLI, projectID: nil, workingDirectory: URL(fileURLWithPath: "/tmp"), status: .working)
            s.agentSessionID = CommandLine.arguments[2]
            let a = CodexCompanionAdapter(session: s, endpoint: CommandLine.arguments[1])
            defer { a.close() }
            try await a.refresh()
            log("ATTACH PASS \(a.threadID ?? "") pending=\(a.pending.map(\.attentionSummary))")
            return
        }
        let model = ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_MODEL"] ?? "gpt-6-astra"
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_ROOT"] ?? "/tmp/flotilla-codex-live-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let auth = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json")
        if FileManager.default.fileExists(atPath: auth.path) { try FileManager.default.copyItem(at: auth, to: home.appendingPathComponent("auth.json")) }
        let socket = root.appendingPathComponent("server.sock").path
        let server = Process()
        server.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_CODEX"] ?? "/opt/homebrew/bin/codex")
        server.arguments = ["app-server", "--listen", "unix://" + socket, "-c", "model=\"\(model)\"", "-c", "model_reasoning_effort=\"low\"", "-c", "features.code_mode=false", "-c", "features.default_mode_request_user_input=false", "-c", "sandbox_mode=\"workspace-write\"", "-c", "approval_policy=\"on-request\"", "-c", "notice.hide_rate_limit_model_nudge=true"]
        var env = ProcessInfo.processInfo.environment
        env["CODEX_HOME"] = home.path
        server.environment = env
        server.currentDirectoryURL = work
        let logURL = root.appendingPathComponent("server.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        server.standardOutput = logHandle; server.standardError = logHandle
        try server.run()
        defer {
            if server.isRunning { server.terminate() }
            try? FileManager.default.removeItem(at: home.appendingPathComponent("auth.json"))
            try? logHandle.close()
        }
        log("ARTIFACTS \(root.path)")
        try await wait("socket", seconds: 10) { FileManager.default.fileExists(atPath: socket) }
        let mac = ProviderRPC()
        var messages: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: messages, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: root.appendingPathComponent("events.json")) }
        }
        mac.onMessage = { message in
            messages.append(message)
            if let method = message["method"] as? String, let p = message["params"] as? [String: Any] {
                if method == "item/completed", let item = p["item"] as? [String: Any] {
                    log("ITEM \(item["type"] ?? "") \(item["text"] ?? "") \(item["questions"] ?? "")")
                } else if ["turn/started", "turn/completed", "error"].contains(method) || message["id"] != nil {
                    log("EVENT \(method)")
                }
            }
        }
        try await mac.connect(socketPath: socket)
        defer { mac.close() }
        let started = try await mac.request("thread/start", params: ["cwd": work.path, "model": model, "approvalPolicy": "on-request", "sandbox": "workspace-write"])
        guard let thread = started["thread"] as? [String: Any], let threadID = thread["id"] as? String else { throw Failure("No thread") }
        var session = Session(title: "Companion verification", goal: "Test", agent: .codexCLI, projectID: nil, workingDirectory: work, status: .working)
        session.agentSessionID = threadID; session.model = model; session.effort = .low
        var adapter = CodexCompanionAdapter(session: session, endpoint: socket)
        defer { adapter.close() }
        let poll = Task { @MainActor in
            while !Task.isCancelled {
                try? await adapter.refresh()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { poll.cancel() }
        try await adapter.refresh()
        func start(_ text: String, plan: Bool = false, approvalPolicy: String? = nil) async throws {
            var params: [String: Any] = ["threadId": threadID, "input": [["type": "text", "text": text, "text_elements": []]]]
            if let approvalPolicy { params["approvalPolicy"] = approvalPolicy }
            if plan { params["collaborationMode"] = ["mode": "plan", "settings": ["model": model, "reasoning_effort": "low", "developer_instructions": NSNull()]] }
            _ = try await mac.request("turn/start", params: params)
            try await adapter.refresh()
        }
        var completionCursor: String?
        var allowImplementationPermissions = false
        func settled() async throws {
            func latestCompleted() -> String? {
                messages.last(where: { $0["method"] as? String == "turn/completed" && ($0["params"] as? [String: Any])?["threadId"] as? String == threadID }).flatMap { $0["params"] as? [String: Any] }.flatMap { $0["turn"] as? [String: Any] }?["id"] as? String
            }
            let deadline = Date().addingTimeInterval(120)
            while latestCompleted() == nil || latestCompleted() == completionCursor || adapter.transcript.streamingText != nil {
                if Date() > deadline { throw Failure("Timed out: turn completion") }
                if allowImplementationPermissions, let card = adapter.pending.first, case .permission(let permission) = card.kind {
                    guard permission.summary.contains("greeting.txt") || permission.tool == "Edit" else { throw Failure("Unexpected implementation permission: \(permission.summary)") }
                    _ = try await adapter.answer(card.id, with: .allow)
                    log("PASS implementation permission")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            completionCursor = latestCompleted()
            try await Task.sleep(for: .milliseconds(250))
        }
        if CommandLine.arguments.contains("--edits") {
            for (name, answer, allowed): (String, InteractionAnswer, Bool) in [("allow", .allow, true), ("deny", .deny, false)] {
                let target = work.appendingPathComponent("edit-" + name + ".txt")
                let prompt = "Use apply_patch directly to create \(target.path) containing EDIT-FIXTURE. Do not use a shell or another tool. If the file-change approval is denied, do not retry. Finish with EDIT-DONE if allowed or EDIT-DENIED if refused."
                _ = try await mac.request("turn/start", params: ["threadId": threadID, "sandboxPolicy": ["type": "readOnly"], "input": [["type": "text", "text": prompt, "text_elements": []]]])
                try await adapter.refresh()
                try await wait("file-change approval " + name, seconds: 120) { !adapter.pending.isEmpty }
                let card = adapter.pending.first!
                guard case .permission(let permission) = card.kind, permission.tool == "Edit" else { throw Failure("Expected native file-change approval") }
                try check(permission.summary.contains(target.path), "File-change card identifies the path")
                try check(permission.detail?.contains("EDIT-FIXTURE") == true, "File-change card contains the proposed patch")
                _ = try await adapter.answer(card.id, with: answer)
                try await settled()
                try check(FileManager.default.fileExists(atPath: target.path) == allowed, "File-change consequence " + name)
                log("PASS file-change " + name)
            }
            return
        }
        if CommandLine.arguments.contains("--blocking") {
            try await start("Call request_user_input (the blocking tool) with exactly two questions: Language? with Python and Ruby options; Project name? with no options. Wait for my answer. After I answer, reply BLOCKING=<language>;NAME=<project name>.", plan: true)
            try await wait("blocking question", seconds: 120) { adapter.pending.contains { if case .question = $0.kind { true } else { false } } }
            let card = adapter.pending.first!
            guard case .question(let steps) = card.kind, steps.count == 2 else { throw Failure("Expected two blocking questions") }
            let ruby = steps[0].options.first { $0.label.contains("Ruby") }!.label
            _ = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: steps[0].id, selected: [ruby]), .init(stepID: steps[1].id, selected: [], other: "LegacyPhone")]))
            try await settled()
            try check(adapter.transcript.events.contains { if case .assistantMessage(let text, _) = $0.content { text.contains("BLOCKING=Ruby;NAME=LegacyPhone") } else { false } }, "Blocking answers reached model")
            log("PASS blocking questions and free text")
            return
        }
        if !CommandLine.arguments.contains("--remaining") {
            try await start("This is a question-tool compatibility test. Call request_user_input_async now, asking 'Which language?' with options Python and Ruby. Do not answer the question yourself. After I answer, reply exactly LANGUAGE=<my answer> and do nothing else.")
            try await wait("async question card", seconds: 120) { adapter.pending.contains { if case .question = $0.kind { true } else { false } } }
            let card = adapter.pending.first!
            guard case .question(let steps) = card.kind else { throw Failure("Wrong card") }
            try check(steps.first?.allowsFreeText == true, "Async allows free text")
            let result = try await adapter.answer(card.id, with: .questionAnswers([.init(stepID: steps[0].id, selected: [steps[0].options[0].label])]))
            try check(result == .accepted, "Async answer accepted")
            try await settled()
            try check(adapter.transcript.events.contains { if case .assistantMessage(let text, _) = $0.content { text.contains("LANGUAGE=Python") } else { false } }, "Model received async answer")
            log("PASS async question option reaches model")
            try await start("Call request_user_input_async with TWO questions: 'Choose a color' with options Red and Blue, and 'What project name?' with no options. After I answer, reply exactly COLOR=<color>;PROJECT=<name>.")
            try await wait("multiple questions", seconds: 120) { adapter.pending.contains { if case .question = $0.kind { true } else { false } } }
            let multi = adapter.pending.first!
            guard case .question(let multiSteps) = multi.kind, multiSteps.count == 2 else { throw Failure("Expected two questions") }
            _ = try await adapter.answer(multi.id, with: .questionAnswers([.init(stepID: multiSteps[0].id, selected: ["Blue"]), .init(stepID: multiSteps[1].id, selected: [], other: "PhoneProject")]))
            try await settled()
            try check(adapter.transcript.events.contains { if case .assistantMessage(let text, _) = $0.content { text.contains("COLOR=Blue;PROJECT=PhoneProject") } else { false } }, "Multiple and free-text answers reached model")
            log("PASS multi-step and free-text questions")
            try await start("Call request_user_input_async asking 'Tea or coffee?' with Tea and Coffee options, and wait for my answer.")
            try await wait("question before reconnect", seconds: 120) { !adapter.pending.isEmpty }
            try await adapter.stop()
            try await settled()
            adapter.close()
            adapter = CodexCompanionAdapter(session: session, endpoint: socket)
            try await adapter.refresh()
            try check(!adapter.pending.isEmpty, "Reconnect restores question")
            let restored = adapter.pending.first!.id
            try await start("Coffee. Reply exactly MAC-ANSWERED.")
            try await settled()
            try check(adapter.pending.isEmpty, "Mac answer clears phone question")
            try check(try await adapter.answer(restored, with: .questionAnswers([])) == .alreadyAnswered, "Late phone answer ignored")
            log("PASS reconnect and Mac-first question")
            for (name, answer, allowed): (String, InteractionAnswer, Bool) in [("allow", .allow, true), ("deny", .deny, false), ("allow-note", .allowWithNote("Reply PHONE-ALLOW-NOTE after completing the command."), true), ("deny-note", .denyWithNote("Reply PHONE-DENY-NOTE. Do not retry the command."), false), ("deny-stop", .denyAndStop, false)] {
                let target = root.appendingPathComponent("approval-" + name)
                try await start("Permission compatibility test. Use exec_command with sandbox_permissions=require_escalated and justification='Companion permission test' to run /usr/bin/touch \(target.path). Wait for approval. Do not run the command without approval. If denied, do not retry or use another tool. Then reply APPROVAL=allowed or APPROVAL=denied. No other commands.")
                try await wait("permission " + name, seconds: 120) { adapter.pending.contains { if case .permission = $0.kind { true } else { false } } }
                let permission = adapter.pending.first!
                _ = try await adapter.answer(permission.id, with: answer)
                try await settled()
                try check(FileManager.default.fileExists(atPath: target.path) == allowed, "Permission file consequence " + name)
                if name == "allow-note" || name == "deny-note" {
                    let marker = name == "allow-note" ? "PHONE-ALLOW-NOTE" : "PHONE-DENY-NOTE"
                    try check(adapter.transcript.events.contains { if case .assistantMessage(let text, _) = $0.content { text.contains(marker) } else { false } }, "Permission note reached model " + name)
                }
                log("PASS permission " + name)
            }
        }
        let alwaysTarget = work.appendingPathComponent("session-allowed.txt")
        let alwaysPrompt = "Use exec_command to run /usr/bin/touch \(alwaysTarget.path), then reply SESSION-ALLOWED. Do not request sandbox escalation."
        try await start(alwaysPrompt, approvalPolicy: "untrusted")
        try await wait("session approval", seconds: 120) { !adapter.pending.isEmpty }
        let sessionApproval = adapter.pending.first!
        _ = try await adapter.answer(sessionApproval.id, with: .alwaysAllow)
        try await settled()
        try check(FileManager.default.fileExists(atPath: alwaysTarget.path), "Always Allow executed command")
        try await start(alwaysPrompt, approvalPolicy: "untrusted")
        try await wait("repeat command", seconds: 120) { !adapter.pending.isEmpty || messages.last(where: { $0["method"] as? String == "turn/completed" }).flatMap { $0["params"] as? [String: Any] }.flatMap { $0["turn"] as? [String: Any] }?["id"] as? String != completionCursor }
        if let repeated = adapter.pending.first {
            _ = try await adapter.answer(repeated.id, with: .denyAndStop)
            throw Failure("acceptForSession did not suppress repeated approval")
        } else { log("PASS native acceptForSession cache") }
        try await settled()
        _ = try await mac.request("thread/resume", params: ["threadId": threadID, "approvalPolicy": "on-request", "excludeTurns": true])
        let tmux = "flotilla-codex-plan-" + UUID().uuidString.prefix(8)
        try String(tmux).write(to: root.appendingPathComponent("tmux-socket"), atomically: true, encoding: .utf8)
        let tui = ["/usr/bin/env", "CODEX_HOME=" + home.path, ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_CODEX"] ?? "/opt/homebrew/bin/codex", "--remote", "unix://" + socket, "--no-alt-screen", "resume", threadID]
        try cli(["-L", tmux, "-f", "/dev/null", "new-session", "-d", "-s", "plan", "-x", "140", "-y", "45", "-c", work.path, "/bin/sh"])
        try cli(["-L", tmux, "set-option", "-t", "plan", "remain-on-exit", "on"])
        try cli(["-L", tmux, "respawn-pane", "-k", "-t", "plan"] + tui)
        defer { _ = try? cli(["-L", tmux, "kill-server"]) }
        try await Task.sleep(for: .seconds(3))
        adapter.close()
        adapter = CodexCompanionAdapter(session: session, endpoint: socket, screen: { try? cli(["-L", tmux, "capture-pane", "-p", "-t", "plan"]) }, send: { _ in _ = try? cli(["-L", tmux, "send-keys", "-t", "plan", "Escape"]) })
        try await adapter.refresh()
        try await start("Propose a plan to create a file hello.txt containing hello. Do not implement it yet. Finish by emitting a proposed_plan block with real line breaks, with opening and closing tags each on a separate line. Do not write literal backslash-n characters. No questions are necessary.", plan: true)
        try await wait("plan card", seconds: 120) { adapter.pending.contains { if case .plan = $0.kind { true } else { false } } }
        try await settled()
        let plan = adapter.pending.first!
        try await wait("TUI plan dialog", seconds: 10) { (try? cli(["-L", tmux, "capture-pane", "-p", "-t", "plan"]).contains("Yes, implement this plan")) == true }
        let beforePlan = try cli(["-L", tmux, "capture-pane", "-p", "-t", "plan"])
        try beforePlan.write(to: root.appendingPathComponent("tui-plan-before.txt"), atomically: true, encoding: .utf8)
        log("TUI PLAN BEFORE \(beforePlan)")
        _ = try await adapter.answer(plan.id, with: .revisePlan("Revise the plan: use greeting.txt containing PHONE-PLAN instead. Do not implement; emit a proposed_plan block."))
        try await wait("revised plan", seconds: 120) { adapter.pending.contains { if case .plan(let p) = $0.kind { p.markdown.contains("greeting.txt") } else { false } } }
        try await settled()
        try check(!FileManager.default.fileExists(atPath: work.appendingPathComponent("greeting.txt").path), "Revision stayed in plan mode")
        try await wait("TUI revised plan dialog", seconds: 10) { (try? cli(["-L", tmux, "capture-pane", "-p", "-t", "plan"]).contains("Yes, implement this plan")) == true }
        let revised = adapter.pending.first!
        allowImplementationPermissions = true
        _ = try await adapter.answer(revised.id, with: .approvePlan(nil))
        try await settled()
        try check((try? String(contentsOf: work.appendingPathComponent("greeting.txt"), encoding: .utf8))?.contains("PHONE-PLAN") == true, "Plan approval implemented file")
        allowImplementationPermissions = false
        log("PASS plan revision and approval")
        let afterPlan = try cli(["-L", tmux, "capture-pane", "-p", "-t", "plan"])
        try afterPlan.write(to: root.appendingPathComponent("tui-plan-after.txt"), atomically: true, encoding: .utf8)
        log("TUI PLAN AFTER \(afterPlan)")
        try check(!afterPlan.contains("Yes, implement this plan"), "Phone answer dismisses the TUI plan dialog")
        try await adapter.sendPrompt("Reply exactly PHONE-PROMPT.")
        try await settled()
        try check(adapter.transcript.events.contains { if case .assistantMessage(let text, _) = $0.content { text.contains("PHONE-PROMPT") } else { false } }, "Phone prompt reached model")
        log("PASS phone prompt")
        try await start("Run sleep 20 using a shell command, then reply SLEEP-DONE.")
        try await wait("working turn", seconds: 15) { messages.last(where: { ["turn/started", "turn/completed"].contains($0["method"] as? String ?? "") })?["method"] as? String == "turn/started" }
        try await adapter.stop()
        try await settled()
        try check(messages.last(where: { $0["method"] as? String == "turn/completed" }).flatMap { $0["params"] as? [String: Any] }.flatMap { $0["turn"] as? [String: Any] }?["status"] as? String == "interrupted", "Stop interrupted turn")
        log("PASS stop")
        log("ALL PASS")
    }
    @MainActor @discardableResult static func cli(_ args: [String]) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["FLOTILLA_VERIFY_TMUX"] ?? "/opt/homebrew/bin/tmux"); p.arguments = args
        let output = Pipe(); p.standardOutput = output; p.standardError = output
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        if p.terminationStatus != 0 { throw Failure("tmux \(args): \(text)") }
        return text
    }
    static func log(_ text: String) { try? FileHandle.standardOutput.write(contentsOf: Data((text + "\n").utf8)) }
    struct Failure: Error { let message: String; init(_ s: String) { message = s } }
    static func check(_ value: Bool, _ label: String) throws { if !value { throw Failure(label) } }
    @MainActor static func wait(_ label: String, seconds: Double, until: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !until() { if Date() > deadline { throw Failure("Timed out: \(label)") }; try await Task.sleep(for: .milliseconds(100)) }
    }
}
