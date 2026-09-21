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
    /// Absolute position in the native transcript. The companion reader keeps
    /// a rolling event window, so this remains the ordering authority after
    /// the event that introduced an image has fallen out of that window.
    let position: AgentScreenshotMonitor.EventPosition
    let sessionID: UUID
    let agent: AgentKind
    let image: NSImage
    let data: Data
    /// The name the agent gave the file, when it sent one; `nil` for pasted
    /// or tool-captured images.
    let filename: String?
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["UI_TESTING"] == "1", let s = newSession {
            let img = NSImage(size: NSSize(width: 400, height: 300), flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                return true
            }
            let shot = AgentScreenshot(
                id: "ui-test-shot",
                position: EventPosition(line: 1, entry: 1),
                sessionID: s.id,
                agent: s.agent,
                image: img,
                data: Data(),
                filename: "preview.png",
                timestamp: Date()
            )
            screenshots = [shot]
            return
        }
        #endif
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
                position: item.position,
                sessionID: session.id,
                agent: session.agent,
                image: image,
                data: data,
                filename: item.filename,
                timestamp: item.timestamp
            )
        }
        // `CompanionTranscriptReader` caps its rendered event window at 400
        // entries. Replacing this list with just that window made screenshots
        // disappear after enough later Claude messages arrived. Keep images
        // already decoded for this focused session, then merge in images that
        // are still present in the newest window. Native positions are stable
        // across the reader's trimming, so they also give the merged list its
        // correct chronological order.
        self.screenshots = Self.merging(self.screenshots, with: loadedScreenshots)

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
        let filename: String?
        let timestamp: Date
    }

    static func merging(
        _ existing: [AgentScreenshot],
        with currentWindow: [AgentScreenshot]
    ) -> [AgentScreenshot] {
        var byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for screenshot in currentWindow {
            byID[screenshot.id] = screenshot
        }
        return byID.values.sorted { $0.position < $1.position }
    }

    nonisolated private static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "heic"
    ]

    nonisolated private static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return imageExtensions.contains(ext)
    }

    /// Checks if a candidate image path or filename was attached or mentioned in any user message.
    nonisolated static func isImageReferencedByUser(
        toolPath: String?,
        filename: String?,
        in userTexts: [String]
    ) -> Bool {
        guard !userTexts.isEmpty else { return false }

        var candidates: [String] = []

        if let rawPath = toolPath {
            var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if path.hasPrefix("file://") {
                path = String(path.dropFirst(7))
            }
            if let decoded = path.removingPercentEncoding {
                path = decoded
            }
            if !path.isEmpty {
                candidates.append(path)
                let home = NSHomeDirectory()
                if path.hasPrefix(home) {
                    candidates.append("~" + path.dropFirst(home.count))
                }
                let baseName = (path as NSString).lastPathComponent
                if isImagePath(baseName) {
                    candidates.append(baseName)
                }
            }
        }

        if let filename = filename {
            let clean = filename.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
            if isImagePath(clean) && !candidates.contains(clean) {
                candidates.append(clean)
            }
        }

        guard !candidates.isEmpty else { return false }

        for userText in userTexts {
            let unescapedUserText = userText.replacingOccurrences(of: "\\ ", with: " ")

            for candidate in candidates {
                if candidate.contains("/") || candidate.hasPrefix("~") {
                    if userText.localizedCaseInsensitiveContains(candidate)
                        || unescapedUserText.localizedCaseInsensitiveContains(candidate) {
                        return true
                    }
                } else {
                    if containsFilename(candidate, in: userText)
                        || containsFilename(candidate, in: unescapedUserText) {
                        return true
                    }
                }
            }
        }

        return false
    }

    nonisolated private static func containsFilename(_ filename: String, in text: String) -> Bool {
        guard !filename.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let match = text.range(of: filename, options: .caseInsensitive, range: searchRange) {
            let isPrefixValid = match.lowerBound == text.startIndex || {
                let prevChar = text[text.index(before: match.lowerBound)]
                return prevChar.isWhitespace || "\"'`([{</\\:;,=".contains(prevChar)
            }()
            let isSuffixValid = match.upperBound == text.endIndex || {
                let nextChar = text[match.upperBound]
                return nextChar.isWhitespace || "\"'`)]}>:;,!?".contains(nextChar)
            }()
            if isPrefixValid && isSuffixValid {
                return true
            }
            searchRange = match.upperBound..<text.endIndex
        }
        return false
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
        let userTexts = events.compactMap { event -> String? in
            guard case let .userMessage(text, _) = event.content else { return nil }
            return text
        }

        var toolUseInputs: [String: [String: String]] = [:]
        for event in events {
            if case let .toolUse(id, _, input, _) = event.content {
                toolUseInputs[id] = input
            }
        }

        var toolUseIDByRecordLine: [Substring: String] = [:]
        var toolUseIDByTimestamp: [Date: String] = [:]
        var toolUseIDForImage: [String: String] = [:]

        var lastToolUseID: String?
        var lastToolResultTimestamp: Date?

        for event in events {
            switch event.content {
            case let .toolResult(toolUseID, _, _, timestamp):
                lastToolUseID = toolUseID
                lastToolResultTimestamp = timestamp
                if event.id.contains(":") {
                    let line = event.id.split(separator: ":", maxSplits: 1)[0]
                    toolUseIDByRecordLine[line] = toolUseID
                }
                toolUseIDByTimestamp[timestamp] = toolUseID

            case let .image(_, _, _, timestamp):
                if event.id.contains(":") {
                    let line = event.id.split(separator: ":", maxSplits: 1)[0]
                    if let useID = toolUseIDByRecordLine[line] {
                        toolUseIDForImage[event.id] = useID
                    }
                }
                if toolUseIDForImage[event.id] == nil {
                    if let lastToolResultTimestamp, lastToolResultTimestamp == timestamp, let lastToolUseID {
                        toolUseIDForImage[event.id] = lastToolUseID
                    } else if let useID = toolUseIDByTimestamp[timestamp] {
                        toolUseIDForImage[event.id] = useID
                    }
                }

            default:
                break
            }
        }

        return events.enumerated().compactMap { offset, event in
            guard case .image(_, let base64, let filename, let timestamp) = event.content,
                  !userRecordIDs.contains(event.id.split(separator: ":", maxSplits: 1)[0]),
                  !userTimestamps.contains(timestamp) else { return nil }

            if let toolUseID = toolUseIDForImage[event.id],
               let input = toolUseInputs[toolUseID] {
                let candidatePaths = [
                    input["file_path"],
                    input["path"],
                    input["filePath"],
                    input["url"]
                ].compactMap { $0 } + input.values.filter { isImagePath($0) }

                let isUserProvided = candidatePaths.contains { path in
                    isImageReferencedByUser(toolPath: path, filename: filename, in: userTexts)
                } || isImageReferencedByUser(toolPath: nil, filename: filename, in: userTexts)

                if isUserProvided {
                    return nil
                }
            } else if filename != nil && isImageReferencedByUser(toolPath: nil, filename: filename, in: userTexts) {
                return nil
            }

            let parts = event.id.split(separator: ":", maxSplits: 1)
            let position = EventPosition(line: Int(parts[0]) ?? offset,
                                         entry: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
            guard baseline.map({ position > $0 }) ?? true else { return nil }
            return ImageEvent(id: event.id, position: position, base64: base64, filename: filename, timestamp: timestamp)
        }
    }
}
