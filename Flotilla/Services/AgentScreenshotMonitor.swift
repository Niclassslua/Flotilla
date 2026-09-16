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

    @ObservationIgnored private let reader: CompanionTranscriptReader
    @ObservationIgnored private var session: Session?
    /// Highest image event index already accounted for; only images past it
    /// are new.
    @ObservationIgnored private var baseline = -1
    @ObservationIgnored private var isBaselined = false
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    init(reader: CompanionTranscriptReader = CompanionTranscriptReader(registry: .flotilla())) {
        self.reader = reader
    }

    /// Follows the session on screen. Switching sessions drops anything still
    /// pending, and the new session's existing images become the baseline.
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
        baseline = -1
        isBaselined = false
        refreshTask?.cancel()
        Task { [reader] in
            if let previous { await reader.unwatch(previous.id) }
            guard let newSession else { return }
            await reader.watch(newSession)
        }
        guard newSession != nil else { return }
        // The transcript may not exist yet; an empty read still sets a
        // baseline of "nothing", so the first image the agent sends appears.
        refresh(debounce: .zero)
    }

    func dismiss() {
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
        let found = Self.agentImages(in: events, after: baseline)
        if let last = found.last?.index {
            baseline = max(baseline, last)
        }
        guard isBaselined else {
            isBaselined = true
            return
        }
        let screenshots = found.compactMap { item -> AgentScreenshot? in
            guard let data = Data(base64Encoded: item.base64),
                  let image = NSImage(data: data) else { return nil }
            return AgentScreenshot(
                id: String(item.index),
                sessionID: session.id,
                agent: session.agent,
                image: image,
                data: data,
                timestamp: item.timestamp
            )
        }
        pending.append(contentsOf: screenshots)
    }

    struct ImageEvent: Equatable {
        let index: Int
        let base64: String
        let timestamp: Date
    }

    /// Image events past `baseline` that the agent sent. An image whose record
    /// also holds a user message is one the human pasted: every block of a
    /// record shares its timestamp, so the two are matched on it.
    nonisolated static func agentImages(in events: [TranscriptEvent], after baseline: Int) -> [ImageEvent] {
        let userTimestamps = Set(events.compactMap { event -> Date? in
            if case .userMessage(_, let timestamp) = event.content { return timestamp }
            return nil
        })
        return events.compactMap { event in
            guard case .image(_, let base64, let timestamp) = event.content,
                  let index = Int(event.id), index > baseline,
                  !userTimestamps.contains(timestamp) else { return nil }
            return ImageEvent(index: index, base64: base64, timestamp: timestamp)
        }
    }
}
