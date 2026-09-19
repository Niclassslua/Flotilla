import AppKit
import Foundation
import Observation
import SessionKit
import CompanionKit

/// The newest agent-sent screenshots across every session active in the
/// last 24 hours, for the Agent screenshots widget. Separate from
/// `AgentScreenshotMonitor`, which only ever follows the one focused
/// session — this scans however many recent sessions the widget's project
/// and agent filters leave, so it owns its own `CompanionTranscriptReader`
/// rather than sharing the focused one.
@MainActor
@Observable
final class HomeScreenshotFeed {
    struct Shot: Identifiable, Equatable {
        static func == (lhs: Shot, rhs: Shot) -> Bool { lhs.id == rhs.id }

        let id: String
        let sessionID: UUID
        let agent: AgentKind
        let sessionTitle: String
        let timestamp: Date
        let image: NSImage
    }

    private(set) var shots: [Shot] = []
    private(set) var isLoading = false
    private let reader: CompanionTranscriptReader
    private var lastKey: String?
    private var lastCompleted: Date?

    static let lookback: TimeInterval = 24 * 60 * 60
    static let freshness: TimeInterval = 60

    init(reader: CompanionTranscriptReader = CompanionTranscriptReader(registry: .flotilla())) {
        self.reader = reader
    }

    func refresh(store: AppStore, projectID: UUID?, agent: AgentKind?, limit: Int = 4) async {
        let key = "\(projectID?.uuidString ?? "all")|\(agent?.rawValue ?? "all")"
        if key == lastKey, let lastCompleted, Date().timeIntervalSince(lastCompleted) < Self.freshness {
            return
        }
        isLoading = true
        defer { isLoading = false }

        let cutoff = Date().addingTimeInterval(-Self.lookback)
        let candidates = store.sessions.filter { session in
            session.lastActiveAt >= cutoff
                && (projectID == nil || session.projectID == projectID)
                && (agent == nil || session.agent == agent)
        }

        var collected: [Shot] = []
        for session in candidates {
            guard !Task.isCancelled else { return }
            let transcript = await reader.read(session)
            for item in AgentScreenshotMonitor.agentImages(in: transcript.events) {
                guard let data = Data(base64Encoded: item.base64), let image = NSImage(data: data) else { continue }
                collected.append(Shot(id: item.id, sessionID: session.id, agent: session.agent, sessionTitle: session.title, timestamp: item.timestamp, image: image))
            }
        }
        shots = Array(collected.sorted { $0.timestamp > $1.timestamp }.prefix(limit))
        lastKey = key
        lastCompleted = Date()
    }
}
