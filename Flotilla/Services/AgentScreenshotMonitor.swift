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

    nonisolated private static let assetOrDocDirectoryNames: Set<String> = [
        "logos", "assets", "icons", "images", "img", "static",
        "res", "resources", "drawables", "media", "fixtures",
        "docs", "documentation", "doc", "public"
    ]

    nonisolated static func isLikelyAgentScreenshot(
        tool: String?,
        candidatePaths: [String],
        filename: String?
    ) -> Bool {
        // 1. Explicit user-facing deliveries via SendUserFile are always visual attachments to present.
        if let tool, tool.caseInsensitiveCompare("SendUserFile") == .orderedSame {
            return true
        }

        // 2. Dedicated screenshot or screen capture tools.
        if let tool, isScreenshotToolName(tool) {
            return true
        }

        // 3. Synthetic unit test fixtures with no path or filename metadata are kept for test compatibility.
        if candidatePaths.isEmpty && filename == nil {
            return true
        }

        // 4. Check candidate paths and filename.
        var allCandidates = candidatePaths
        if let filename, !allCandidates.contains(filename) {
            allCandidates.append(filename)
        }

        for path in allCandidates {
            if isScreenshotPath(path) {
                return true
            }
        }

        return false
    }

    nonisolated static func isScreenshotPath(_ rawPath: String) -> Bool {
        var path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
        if path.hasPrefix("file://") {
            path = String(path.dropFirst(7))
        }
        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        path = path.replacingOccurrences(of: "\\ ", with: " ")
        guard !path.isEmpty else { return false }

        let lower = path.lowercased()

        // 1. Temporary, scratch, or capture directories where agents generate images at runtime.
        if lower.hasPrefix("/tmp/")
            || lower.hasPrefix("/private/tmp/")
            || lower.hasPrefix("/var/folders/")
            || lower.contains("/scratch/")
            || lower.contains(".scratch")
            || lower.contains("/tmp/")
            || lower.contains("/temp/") {
            return true
        }

        let tempDir = NSTemporaryDirectory().lowercased()
        if !tempDir.isEmpty && lower.hasPrefix(tempDir) {
            return true
        }

        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent.lowercased()
        let nameWithoutExtension = (filename as NSString).deletingPathExtension.lowercased()
        let pathComponents = Set(url.pathComponents.map { $0.lowercased() })

        // 2. Documentation and logo/icon directories never contain live agent screenshots.
        if pathComponents.contains("docs") || pathComponents.contains("documentation") || pathComponents.contains("doc") {
            return false
        }
        if pathComponents.contains("logos") || pathComponents.contains("icons") {
            return false
        }

        // 3. Explicit screenshot directory (e.g. screenshots/...)
        if pathComponents.contains("screenshots") || pathComponents.contains("screencaps") {
            return true
        }

        // 4. Reject other repository asset/resource directories unless explicitly named as a screenshot.
        let isAssetDir = !assetOrDocDirectoryNames.isDisjoint(with: pathComponents)
        if isAssetDir {
            return nameWithoutExtension.contains("screenshot")
                || nameWithoutExtension.contains("screencap")
                || nameWithoutExtension.contains("snapshot")
        }

        // 5. For any other project or workspace path, check if the filename indicates a screenshot.
        return isScreenshotNamePattern(nameWithoutExtension)
    }

    nonisolated private static func isScreenshotNamePattern(_ name: String) -> Bool {
        if name.contains("screenshot")
            || name.contains("screen-shot")
            || name.contains("screen_shot")
            || name.contains("screencap")
            || name.contains("screen_cap")
            || name.contains("snapshot") {
            return true
        }
        if name == "screen"
            || name.hasPrefix("screen-")
            || name.hasPrefix("screen_")
            || name == "preview"
            || name.hasPrefix("preview-")
            || name.hasPrefix("preview_")
            || name == "capture"
            || name.hasPrefix("capture-")
            || name.hasPrefix("capture_") {
            return true
        }
        return false
    }

    nonisolated private static func isScreenshotToolName(_ tool: String) -> Bool {
        let lower = tool.lowercased()
        return lower.contains("screenshot")
            || lower.contains("screencap")
            || lower.contains("capture_screen")
            || lower.contains("screen_capture")
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
        var toolUseNames: [String: String] = [:]
        for event in events {
            if case let .toolUse(id, tool, input, _) = event.content {
                toolUseInputs[id] = input
                toolUseNames[id] = tool
            }
        }

        var toolUseIDByRecordLine: [Substring: String] = [:]
        var toolUseIDByTimestamp: [Date: String] = [:]
        var toolUseIDForImage: [String: String] = [:]

        var lastToolUseID: String?
        var lastToolResultTimestamp: Date?

        for event in events {
            switch event.content {
            case let .toolUse(id, tool, input, timestamp):
                toolUseInputs[id] = input
                toolUseNames[id] = tool
                if event.id.contains(":") {
                    let line = event.id.split(separator: ":", maxSplits: 1)[0]
                    toolUseIDByRecordLine[line] = id
                }
                toolUseIDByTimestamp[timestamp] = id

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

            var candidatePaths: [String] = []
            var toolName: String?

            if let toolUseID = toolUseIDForImage[event.id] {
                toolName = toolUseNames[toolUseID]
                if let input = toolUseInputs[toolUseID] {
                    candidatePaths = [
                        input["file_path"],
                        input["path"],
                        input["filePath"],
                        input["url"]
                    ].compactMap { $0 } + input.values.filter { isImagePath($0) }
                }
            }

            let isUserProvided = candidatePaths.contains { path in
                isImageReferencedByUser(toolPath: path, filename: filename, in: userTexts)
            } || (filename != nil && isImageReferencedByUser(toolPath: nil, filename: filename, in: userTexts))

            if isUserProvided {
                return nil
            }

            if !isLikelyAgentScreenshot(tool: toolName, candidatePaths: candidatePaths, filename: filename) {
                return nil
            }

            let parts = event.id.split(separator: ":", maxSplits: 1)
            let position = EventPosition(line: Int(parts[0]) ?? offset,
                                         entry: parts.count > 1 ? (Int(parts[1]) ?? 0) : 0)
            guard baseline.map({ position > $0 }) ?? true else { return nil }
            let resolvedFilename = filename ?? candidatePaths.first.map { ($0 as NSString).lastPathComponent }
            return ImageEvent(id: event.id, position: position, base64: base64, filename: resolvedFilename, timestamp: timestamp)
        }
    }
}
