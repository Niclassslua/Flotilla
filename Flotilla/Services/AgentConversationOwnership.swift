import Foundation
import SessionKit

/// Checks whether a native agent conversation is already attached elsewhere.
///
/// Antigravity refuses a second CLI for the same conversation. tmux-backed
/// Flotilla sessions are safe because Flotilla reconnects to their existing
/// pane; this guard covers the fallback path, where a new CLI would otherwise
/// be launched with `agy --conversation <id>`.
protocol AgentConversationOwnershipChecking: Sendable {
    func isConversationActive(agent: AgentKind, conversationID: String) -> Bool
}

struct ProcessAgentConversationOwnershipChecker: AgentConversationOwnershipChecking {
    func isConversationActive(agent: AgentKind, conversationID: String) -> Bool {
        guard agent == .antigravity,
              !conversationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return false }
            let commands = String(decoding: data, as: UTF8.self)
            return commands.split(separator: "\n").contains {
                Self.isAntigravityResumeCommand(String($0), conversationID: conversationID)
            }
        } catch {
            // A failed ownership check must not prevent a normal launch. The
            // agent itself remains the final authority and reports conflicts.
            return false
        }
    }

    static func isAntigravityResumeCommand(_ command: String, conversationID: String) -> Bool {
        let arguments = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = arguments.first,
              URL(fileURLWithPath: executable).lastPathComponent == "agy" else {
            return false
        }

        for index in arguments.indices {
            if arguments[index] == "--conversation",
               arguments.indices.contains(index + 1),
               arguments[index + 1] == conversationID {
                return true
            }
            if arguments[index] == "--conversation=\(conversationID)" {
                return true
            }
        }
        return false
    }
}
