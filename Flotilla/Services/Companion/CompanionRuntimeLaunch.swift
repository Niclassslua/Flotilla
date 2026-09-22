import Foundation
import Darwin
import AgentKit
import SessionKit

struct CompanionRuntimeDescriptor: Codable, Sendable {
    var agent: AgentKind
    var endpoint: String
    var password: String?
    var createdAt: Date

    static func file(_ id: UUID, support: URL) -> URL {
        support.appendingPathComponent("companion-runtimes/\(id.uuidString).json")
    }

    static func read(_ id: UUID, support: URL) -> Self? {
        guard let data = try? Data(contentsOf: file(id, support: support)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// A provider's control endpoint belongs to the same tmux runtime as its TUI.
/// Credentials are local-only and never enter companion snapshots.
enum CompanionRuntimeLaunch {
    /// Rewrites `plan` so the agent's control endpoint starts with its TUI,
    /// and returns the executable to launch. `reattaching` keeps the
    /// descriptor of a pane that is still running, whose endpoint is live.
    static func prepare(plan: inout AgentLaunchPlan, session: Session, executable: URL, support: URL, reattaching: Bool) throws -> URL {
        guard executable.lastPathComponent == plan.binaryName else { return executable }
        let directory = support.appendingPathComponent("companion-runtimes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var descriptor = reattaching ? CompanionRuntimeDescriptor.read(session.id, support: support).flatMap { $0.agent == session.agent ? $0 : nil } : nil
        var launched = executable
        switch session.agent {
        case .codexCLI:
            plan.environment["FLOTILLA_CODEX_REMOTE"] = "1"
            let sockets = URL(fileURLWithPath: "/tmp/flotilla-cx-\(getuid())")
            try FileManager.default.createDirectory(at: sockets, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            descriptor = descriptor ?? .init(agent: .codexCLI, endpoint: sockets.appendingPathComponent(session.id.uuidString + ".sock").path, createdAt: .now)
            guard let descriptor else { return executable }
            // Both processes are children of the pane. Reattaching leaves them
            // intact; killing/restarting the pane tears down the control server.
            let wrapper = directory.appendingPathComponent(session.id.uuidString + ".codex.sh")
            var config: [String] = []
            var index = 0
            while index < plan.arguments.count {
                if ["-c", "--config", "--enable", "--disable"].contains(plan.arguments[index]), index + 1 < plan.arguments.count {
                    config += Array(plan.arguments[index...index + 1]); index += 2
                } else { index += 1 }
            }
            plan.arguments += ["--remote", "unix://" + descriptor.endpoint]
            let server = ([executable.path, "app-server", "--listen", "unix://" + descriptor.endpoint] + config).map(quote).joined(separator: " ")
            let client = ([executable.path] + plan.arguments).map(quote).joined(separator: " ")
            let script = """
            #!/bin/sh
            rm -f \(quote(descriptor.endpoint))
            \(server) >\(quote(wrapper.path + ".log")) 2>&1 &
            server_pid=$!
            trap \"kill $server_pid 2>/dev/null\" EXIT HUP INT TERM
            i=0
            while [ ! -S \(quote(descriptor.endpoint)) ]; do
                kill -0 $server_pid 2>/dev/null || exit 1
                i=$((i + 1)); [ $i -lt 100 ] || exit 1
                sleep 0.1
            done
            \(client)
            """ + "\n"
            try Data(script.utf8).write(to: wrapper, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
            plan.arguments = ["-c", quote(wrapper.path)]
            launched = URL(fileURLWithPath: "/bin/sh")
        case .openCode:
            if descriptor == nil {
                let fd = socket(AF_INET, SOCK_STREAM, 0)
                guard fd >= 0 else { throw ProviderConnectionError.disconnected }
                defer { Darwin.close(fd) }
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let bound = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
                }
                guard bound == 0 else { throw ProviderConnectionError.disconnected }
                _ = withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
                }
                descriptor = .init(agent: .openCode, endpoint: "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))", password: UUID().uuidString + UUID().uuidString, createdAt: .now)
            }
            guard let descriptor, let port = URL(string: descriptor.endpoint)?.port else { return executable }
            plan.arguments += ["--hostname", "127.0.0.1", "--port", String(port)]
            plan.environment["OPENCODE_SERVER_USERNAME"] = "opencode"
            plan.environment["OPENCODE_SERVER_PASSWORD"] = descriptor.password
            var config = (plan.environment["OPENCODE_CONFIG_CONTENT"].flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]) ?? [:]
            config["autoupdate"] = false
            plan.environment["OPENCODE_CONFIG_CONTENT"] = String(decoding: try JSONSerialization.data(withJSONObject: config), as: UTF8.self)
        case .antigravity:
            descriptor = descriptor ?? .init(agent: .antigravity, endpoint: directory.appendingPathComponent(session.id.uuidString + ".agy.log").path, createdAt: .now)
            plan.arguments += ["--log-file", descriptor!.endpoint]
        case .claudeCode, .cursorAgent:
            // No companion control-endpoint rewrite — launch the binary as-is.
            return executable
        }
        try JSONEncoder().encode(descriptor!).write(to: CompanionRuntimeDescriptor.file(session.id, support: support), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: CompanionRuntimeDescriptor.file(session.id, support: support).path)
        return launched
    }

    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
