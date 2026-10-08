import Foundation
import HooksKit

/// Reads a session's screen from whichever source can answer.
///
/// The live renderer is preferred: `TerminalManager` already keeps an
/// emulator per session for the life of the app, so reading it costs nothing
/// and is exactly what the user is looking at. A session whose terminal has
/// never been opened has no renderer, and for those tmux is asked directly —
/// `capture-pane` prints the real pane contents whether or not anything is
/// displaying it, which is what makes status work for the whole fleet rather
/// than only the tab in front of you.
///
/// `@unchecked Sendable` for the same reason as `TerminalController`: the
/// only non-`Sendable` thing it holds is the main-actor `TerminalManager`,
/// and every access to it hops to the main actor first.
final class SessionScreenReader: SessionScreenReading, @unchecked Sendable {
    private let terminalManager: TerminalManager
    private let tmuxExecutable: URL?
    private let capture: any TmuxPaneCapturing

    init(
        terminalManager: TerminalManager,
        tmuxExecutable: URL?,
        capture: any TmuxPaneCapturing = ProcessTmuxPaneCapture()
    ) {
        self.terminalManager = terminalManager
        self.tmuxExecutable = tmuxExecutable
        self.capture = capture
    }

    func readScreen(for sessionID: UUID) async -> String? {
        if let rendered = await MainActor.run(body: { terminalManager.screenText(for: sessionID) }) {
            return rendered
        }
        guard let tmuxExecutable else { return nil }
        let name = TmuxSessionWrapping.sessionName(for: sessionID)
        let capture = self.capture
        // `capture-pane` blocks on a subprocess; it must never run on the
        // main actor, where it would stall the very UI it is reporting on.
        return await Task.detached(priority: .utility) {
            capture.capturePane(sessionNamed: name, tmuxExecutable: tmuxExecutable)
        }.value
    }
}

/// Seam for reading a tmux pane's contents, mirroring the other tmux
/// protocols in `TmuxSessionWrapping` so tests never spawn a real server.
protocol TmuxPaneCapturing: Sendable {
    func capturePane(sessionNamed name: String, tmuxExecutable: URL) -> String?
}

struct ProcessTmuxPaneCapture: TmuxPaneCapturing {
    func capturePane(sessionNamed name: String, tmuxExecutable: URL) -> String? {
        guard FileManager.default.fileExists(atPath: ProcessTmuxServerProbe.defaultSocketPath()) else {
            return nil
        }
        let process = ChildProcessEnvironment.makeProcess()
        process.executableURL = tmuxExecutable
        process.arguments = TmuxSessionWrapping.socketArguments()
            + ["capture-pane", "-p", "-t", name]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        let exited: DispatchSemaphore
        do {
            exited = try process.runSignalingExit()
        } catch {
            return nil
        }

        guard exited.wait(timeout: .now() + 2) == .success else {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
