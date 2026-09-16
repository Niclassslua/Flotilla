import AppKit
import Foundation
import Observation
import SessionKit
import CompanionKit

/// One image the agent sent — Claude's `SendUserFile` or a tool result carrying
/// an image, Codex's `view_image`.
struct AgentScreenshot: Identifiable {
    /// The transcript event id, stable for the life of the transcript.
    let id: String
    let sessionID: UUID
    let agent: AgentKind
    let image: NSImage
    let data: Data
    let timestamp: Date
}

/// Watches the focused session's transcript and collects screenshots the agent
/// sends from now on, so the detail column can surface them in the inspector.
///
/// Detection is the same `TranscriptKit` parsing the companion feed uses; this
/// keeps its own reader so its watchers never interfere with the phone's.
@MainActor
@Observable
final class AgentScreenshotMonitor {
    /// Screenshots that arrived since the panel was last dismissed, oldest first.
    private(set) var pending: [AgentScreenshot] = []
    /// All screenshots for the current session, oldest first.
    private(set) var screenshots: [AgentScreenshot] = []

    @ObservationIgnored private let reader: CompanionTranscriptReader
    @ObservationIgnored private var session: Session?
    /// Highest native transcript position already accounted for per session.
    @ObservationIgnored private var baselines: [UUID: EventPosition] = [:]
    @ObservationIgnored private var dismissedIDs: [UUID: Set<String>] = [:]
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(reader: CompanionTranscriptReader = CompanionTranscriptReader(registry: .flotilla())) {
        self.reader = reader
    }

    /// Follows the session on screen.
    func focus(_ newSession: Session?) {
        guard newSession?.id != session?.id else { return }
        // Started here rather than in `init`: SwiftUI builds a throwaway
        // instance each time the owning view's initializer runs.
        if changesTask == nil {
            changesTask = Task { [weak self, reader] in
                for await _ in reader.changes {
                    guard let self else { return }
                    self.scheduleRefresh()
                }
            }
        }
        let previous = session
        session = newSession
        pending = []
        screenshots = []
        refreshTask?.cancel()
        Task { [reader] in
            if let previous { await reader.unwatch(previous.id) }
            guard let newSession else { return }
            await reader.watch(newSession)
        }
        guard newSession != nil else { return }
        refresh(debounce: .zero)
    }

    func dismiss() {
        if let session {
            dismissedIDs[session.id, default: []].formUnion(pending.map(\.id))
        }
        pending = []
    }

    private func scheduleRefresh() {
        refresh(debounce: .milliseconds(250))
    }

    private func refresh(debounce: Duration) {
        guard let session else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self, reader] in
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
            let transcript = await reader.read(session)
            guard !Task.isCancelled else { return }
            self?.apply(transcript.events, for: session)
        }
    }

    private func apply(_ events: [TranscriptEvent], for session: Session) {
        guard session.id == self.session?.id else { return }
        let allFound = Self.agentImages(in: events)
        let loadedScreenshots = allFound.compactMap { item -> AgentScreenshot? in
            guard let data = Data(base64Encoded: item.base64),
                  let image = NSImage(data: data) else { return nil }
            return AgentScreenshot(
                id: item.id,
                sessionID: session.id,
                agent: session.agent,
                image: image,
                data: data,
                timestamp: item.timestamp
            )
        }
        self.screenshots = loadedScreenshots

        let previousBaseline = baselines[session.id]
        if let currentMax = allFound.last?.position {
            baselines[session.id] = max(previousBaseline ?? currentMax, currentMax)
        }

        if let previousBaseline {
            let positions = Dictionary(uniqueKeysWithValues: allFound.map { ($0.id, $0.position) })
            let newScreenshots = loadedScreenshots.filter {
                (positions[$0.id].map { $0 > previousBaseline } ?? false)
                    && !(dismissedIDs[session.id]?.contains($0.id) ?? false)
            }
            for item in newScreenshots where !pending.contains(where: { $0.id == item.id }) {
                pending.append(item)
            }
        } else {
            // First time loading this session: surface screenshots taken within the last 10 minutes
            // that the user has not dismissed.
            let recent = loadedScreenshots.filter {
                abs($0.timestamp.timeIntervalSinceNow) < 600
                    && !(dismissedIDs[session.id]?.contains($0.id) ?? false)
            }
            self.pending = recent
        }
    }

    struct EventPosition: Comparable {
        let line: Int
        let entry: Int

        static func < (lhs: Self, rhs: Self) -> Bool {
            (lhs.line, lhs.entry) < (rhs.line, rhs.entry)
        }
    }

    struct ImageEvent: Equatable {
        let id: String
        let position: EventPosition
        let base64: String
        let timestamp: Date
    }

    /// Event positions come from the native transcript line and entry numbers,
    /// which remain stable when the companion reader trims its 400-event window.
    nonisolated static func agentImages(in events: [TranscriptEvent], after baseline: EventPosition? = nil) -> [ImageEvent] {
        let userRecordIDs = Set(events.compactMap { event -> Substring? in
            guard case .userMessage = event.content, event.id.contains(":") else { return nil }
            return event.id.split(separator: ":", maxSplits: 1).first
        })
        let userTimestamps = Set(events.compactMap { event -> Date? in
            if case .userMessage(_, let timestamp) = event.content, !event.id.contains(":") { return timestamp }
            return nil
        })
        return events.enumerated().compactMap { offset, event in
            guard case .image(_, let base64, let timestamp) = event.content,
                  !userRecordIDs.contains(event.id.split(separator: ":", maxSplits: 1)[0]),
                  !userTimestamps.contains(timestamp) else { return nil }
            let parts = event.id.split(separator: ":", maxSplits: 1)
            let position = EventPosition(line: Int(parts[0]) ?? offset,
                                         entry: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
            guard baseline.map({ position > $0 }) ?? true else { return nil }
            return ImageEvent(id: event.id, position: position, base64: base64, timestamp: timestamp)
        }
    }
}
