import AppKit
import SwiftUI

/// Notices when the app's bundle on disk is replaced while it runs.
///
/// An agent running `make install` from inside a session swaps
/// `/Applications/Flotilla.app` without quitting it (quitting would end that
/// session and every other one). The running process keeps its old code, so
/// the user is offered the relaunch instead of having it forced on them.
@MainActor
@Observable
final class InstalledBuildMonitor {
    private(set) var isOutdated = false
    private let executableURL: URL?
    private let launchedIdentity: FileIdentity?

    private struct FileIdentity: Equatable {
        let inode: UInt64
        let modified: Date
    }

    init(bundle: Bundle = .main) {
        executableURL = bundle.executableURL
        launchedIdentity = executableURL.flatMap(Self.identity(of:))
    }

    func check() {
        guard !isOutdated, let executableURL, let launchedIdentity else { return }
        // A missing file is mid-swap, not an update; the next check sees it.
        guard let current = Self.identity(of: executableURL) else { return }
        isOutdated = current != launchedIdentity
    }

    /// Waits for this process to exit, then opens the bundle path again —
    /// launching it while this instance is still alive would only activate it.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c",
            "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; exec /usr/bin/open \"$0\"",
            Bundle.main.bundlePath
        ]
        do {
            try process.run()
        } catch {
            return
        }
        NSApp.terminate(nil)
    }

    private static func identity(of url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return FileIdentity(inode: inode, modified: modified)
    }
}

struct RelaunchToUpdateBanner: View {
    @State private var monitor = InstalledBuildMonitor()
    @State private var isDismissed = false

    var body: some View {
        Group {
            if monitor.isOutdated && !isDismissed {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("A new build of \(ProcessInfo.processInfo.processName) was installed")
                            .fontWeight(.semibold)
                        Text("Relaunch to use it. Sessions running in tmux continue where they left off.")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Spacer()
                    Button("Later") { isDismissed = true }
                        .buttonStyle(.bordered)
                    Button("Relaunch") { monitor.relaunch() }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("RelaunchToUpdateBanner.RelaunchButton")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task {
            while !Task.isCancelled {
                monitor.check()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}
