import Foundation
import SessionKit
import ProcessKit
import TranscriptKit

extension TranscriptCodecRegistry {
    enum CodecSetupError: LocalizedError {
        case openCodeNotInstalled
        case cursorAgentNotInstalled
        case importFailed(String)

        var errorDescription: String? {
            switch self {
            case .openCodeNotInstalled:
                return "OpenCode is not installed, so a session cannot be handed off to it."
            case .cursorAgentNotInstalled:
                return "Cursor Agent is not installed, so a session cannot be handed off to it."
            case let .importFailed(detail):
                return "The destination agent refused the handed-off session: \(detail)"
            }
        }
    }

    /// The codecs Flotilla actually ships.
    ///
    /// Assembled here rather than inside `TranscriptKit` because one
    /// destination is written by running a CLI, and shelling out belongs to
    /// `ProcessKit` in the app layer — the codec package stays free of
    /// subprocess dependencies and remains testable as pure encoding.
    ///
    /// The resulting capability matrix, which the type system enforces rather
    /// than any list of rules:
    ///
    /// | agent | source | destination |
    /// |---|---|---|
    /// | Claude Code | yes | yes |
    /// | Codex CLI | yes | yes |
    /// | Antigravity | yes | yes — via a reverse-engineered format, see `FORMAT.md` |
    /// | Cursor Agent | yes | yes — JSONL + `agent --print` store seed |
    /// | OpenCode | no — no supported way to release a session | yes |
    static func flotilla(
        commandRunner: any CommandRunning = ProcessCommandRunner(),
        locator: any ExecutableLocating = PATHExecutableLocator()
    ) -> TranscriptCodecRegistry {
        let openCode = OpenCodeTranscriptCodec { file in
            guard let executable = locator.locate("opencode") else {
                throw CodecSetupError.openCodeNotInstalled
            }
            let result = try await commandRunner.run(
                ["import", file.path],
                executable: executable,
                workingDirectory: file.deletingLastPathComponent()
            )
            guard result.exitCode == 0 else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                throw CodecSetupError.importFailed(
                    detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        }

        let cursor = CursorTranscriptCodec(seedStore: { sessionID, workingDirectory, entries in
            guard let executable = locator.locate("agent") ?? locator.locate("cursor-agent") else {
                throw CodecSetupError.cursorAgentNotInstalled
            }
            let prompt = CursorTranscriptCodec.handoffPrompt(from: entries)
            let result = try await commandRunner.run(
                [
                    "--print",
                    "--output-format", "text",
                    "--resume", sessionID,
                    "--trust",
                    "--force",
                    prompt
                ],
                executable: executable,
                workingDirectory: workingDirectory
            )
            guard result.exitCode == 0 else {
                let detail = result.stderr.isEmpty ? result.stdout : result.stderr
                throw CodecSetupError.importFailed(
                    detail.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        })

        return TranscriptCodecRegistry(
            readers: [
                ClaudeTranscriptCodec(),
                CodexTranscriptCodec(),
                AntigravityTranscriptCodec(),
                CursorTranscriptCodec()
            ],
            writers: [
                ClaudeTranscriptCodec(),
                CodexTranscriptCodec(),
                AntigravityTranscriptCodec(),
                cursor,
                openCode
            ]
        )
    }
}
