import Foundation
import Observation
import SessionKit
import HooksKit

@Observable
@MainActor
final class SessionActivityStore {
    private var activity: [UUID: String] = [:]
    private var watchTasks: [UUID: Task<Void, Never>] = [:]
    private let screenReader: any SessionScreenReading

    init(screenReader: any SessionScreenReading) {
        self.screenReader = screenReader
    }

    func watch(_ sessionID: UUID) {
        guard watchTasks[sessionID] == nil else { return }
        watchTasks[sessionID] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await self?.refresh(sessionID)
            }
        }
    }

    func unwatch(_ sessionID: UUID) {
        watchTasks[sessionID]?.cancel()
        watchTasks[sessionID] = nil
    }

    func lastOutputLine(for sessionID: UUID) -> String? {
        activity[sessionID]
    }

    private func refresh(_ sessionID: UUID) async {
        let screen = await screenReader.readScreen(for: sessionID) ?? ""
        let lines = screen.split(separator: "\n").map(String.init)
        let lastNonEmpty = lines.last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let line = lastNonEmpty {
            activity[sessionID] = String(line.prefix(120))
        }
    }
}