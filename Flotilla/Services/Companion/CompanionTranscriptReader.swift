import Foundation
import SessionKit
import TranscriptKit
import CompanionKit

/// Reads a session's native transcript for the phone, re-parsing only when the
/// file changed (docs/companion.md, A8).
actor CompanionTranscriptReader {
    private let registry: TranscriptCodecRegistry
    private struct Cached {
        var url: URL
        var modified: Date
        var size: Int
        var parsedSize: Int
        var lineCount: Int
        /// The last bytes already parsed. Cursor rewrites its transcript (it
        /// drops the trailing `turn_ended` record when a turn starts), so a
        /// file that grew may still have changed underneath `parsedSize`.
        var parsedTail: Data = Data()
        var transcript: SessionTranscript
    }

    private static let parsedTailLength = 512
    private var cache: [UUID: Cached] = [:]
    private var watchers: [UUID: TranscriptFileWatcher] = [:]
    private let changeStream: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    /// Emits whenever a watched session's transcript file changes on disk.
    nonisolated var changes: AsyncStream<Void> { changeStream }

    init(registry: TranscriptCodecRegistry) {
        self.registry = registry
        var continuation: AsyncStream<Void>.Continuation!
        self.changeStream = AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation = $0 }
        self.changeContinuation = continuation
    }

    /// Starts watching `session`'s transcript file for changes, retrying
    /// discovery until the file exists (it may not have been created yet).
    func watch(_ session: Session) {
        guard watchers[session.id] == nil else { return }
        guard let reader = registry.reader(for: session.agent) else { return }
        let watcher = TranscriptFileWatcher { [weak self] in
            self?.changeContinuation.yield()
        }
        watchers[session.id] = watcher
        if let url = locate(session, reader: reader) {
            watcher.start(url: url)
            return
        }
        let sessionID = session.id
        Task { [weak self] in
            while let self, await self.isCurrentWatcher(watcher, for: sessionID) {
                if let url = await self.locate(session, reader: reader) {
                    watcher.start(url: url)
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func isCurrentWatcher(_ watcher: TranscriptFileWatcher, for sessionID: UUID) -> Bool {
        watchers[sessionID] === watcher
    }

    func unwatch(_ sessionID: UUID) {
        watchers[sessionID]?.stop()
        watchers[sessionID] = nil
    }

    func unwatchAll() {
        for watcher in watchers.values { watcher.stop() }
        watchers.removeAll()
    }

    /// `nil` when nothing has changed since the last call for this session.
    func transcript(for session: Session, ifChangedSince previous: SessionTranscript?) -> SessionTranscript? {
        let result = read(session)
        return result == previous ? nil : result
    }

    func read(_ session: Session) -> SessionTranscript {
        // OpenCode's companion adapter reads its live conversation through the
        // authenticated private server. Running `opencode export` here would
        // spawn a CLI process on every transcript refresh; reserve that export
        // for the explicit handoff path.
        if session.agent == .openCode { return SessionTranscript() }
        guard let reader = registry.reader(for: session.agent) else {
            return SessionTranscript(unavailableReason: "No transcript is available for this session.")
        }
        guard let url = locate(session, reader: reader) else {
            return SessionTranscript()
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date ?? .distantPast
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        if let cached = cache[session.id], cached.url == url, cached.modified == modified, cached.size == size {
            return cached.transcript
        }
        if let lineReader = reader as? any TranscriptLineReading,
           var cached = cache[session.id], cached.url == url, size > cached.size,
           let handle = try? FileHandle(forReadingFrom: url) {
            defer { try? handle.close() }
            let tailStart = cached.parsedSize - cached.parsedTail.count
            if (try? handle.seek(toOffset: UInt64(tailStart))) != nil,
               let read = try? handle.readToEnd(),
               read.prefix(cached.parsedTail.count) == cached.parsedTail {
                let bytes = read.dropFirst(cached.parsedTail.count)
                let complete = Self.completeRecords(Data(bytes))
                if !complete.isEmpty {
                    let lines = Self.lines(complete)
                    cached.transcript.events.append(contentsOf: Self.events(in: lines, reader: lineReader, firstLine: cached.lineCount))
                    cached.transcript.events = Array(cached.transcript.events.suffix(CompanionProtocol.transcriptEventLimit))
                    cached.lineCount += lines.count
                    cached.parsedSize += complete.count
                    cached.parsedTail = Self.parsedTail(of: cached.parsedTail + complete)
                }
                cached.size = cached.parsedSize + bytes.count - complete.count
                cached.modified = modified
                cache[session.id] = cached
                return cached.transcript
            }
        }
        if let lineReader = reader as? any TranscriptLineReading,
           let bytes = try? Data(contentsOf: url) {
            let complete = Self.completeRecords(bytes)
            let (events, lineCount) = Self.tailEvents(in: complete, reader: lineReader)
            let transcript = SessionTranscript(events: events)
            cache[session.id] = Cached(url: url, modified: modified, size: bytes.count,
                                       parsedSize: complete.count, lineCount: lineCount,
                                       parsedTail: Self.parsedTail(of: complete), transcript: transcript)
            return transcript
        }
        guard let entries = try? reader.readNative(at: url) else {
            return cache[session.id]?.transcript ?? SessionTranscript()
        }
        let transcript = Self.transcript(from: entries)
        cache[session.id] = Cached(url: url, modified: modified, size: size,
                                   parsedSize: size, lineCount: 0, transcript: transcript)
        return transcript
    }

    /// Every event that could be, or explain, an image the agent sent, from
    /// the whole transcript rather than `read`'s trailing event window. A long
    /// agent turn easily pushes an earlier screenshot out of that window, so
    /// the screenshot panel loads a session's history from here once. Event
    /// ids match `read`'s, so the two can be merged.
    func imageEvents(_ session: Session) -> [TranscriptEvent] {
        guard let reader = registry.reader(for: session.agent),
              let url = locate(session, reader: reader) else { return [] }
        guard let lineReader = reader as? any TranscriptLineReading else {
            guard let entries = try? reader.readNative(at: url) else { return [] }
            return Self.transcript(from: entries, limit: .max).events
        }
        guard let bytes = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        let complete = Self.completeRecords(bytes)
        // Decoding every record of a transcript that can run to tens of
        // megabytes is wasted on lines that never mention an image, so lines
        // are matched on raw bytes first and only the survivors are parsed.
        return complete.withUnsafeBytes { raw -> [TranscriptEvent] in
            guard let base = raw.baseAddress else { return [] }
            var events: [TranscriptEvent] = []
            var start = 0
            var lineIndex = 0
            while start < raw.count, let newline = memchr(base + start, 0x0A, raw.count - start) {
                let end = UnsafeRawPointer(newline) - base
                let line = UnsafeRawBufferPointer(rebasing: raw[start..<end])
                if Self.imageMarkers.contains(where: { Self.contains($0, in: line) }) {
                    let text = String(decoding: line, as: UTF8.self)
                    events += Self.events(in: [text[...]], reader: lineReader, firstLine: lineIndex)
                }
                start = end + 1
                lineIndex += 1
            }
            return events
        }
    }

    /// Byte patterns present in every record that carries an image (Claude's
    /// `"type":"image"`, Codex's `input_image`, `SendUserFile`) or names an
    /// image path the tool call and user-message checks need.
    private static let imageMarkers: [[UInt8]] = [
        "image", "SendUserFile", ".png", ".jp", ".gif", ".webp", ".heic", ".tif", ".bmp"
    ].map { Array($0.utf8) }

    private static func contains(_ pattern: [UInt8], in line: UnsafeRawBufferPointer) -> Bool {
        guard let base = line.baseAddress else { return false }
        return pattern.withUnsafeBytes { needle in
            memmem(base, line.count, needle.baseAddress, needle.count) != nil
        }
    }

    private static func parsedTail(of data: Data) -> Data {
        Data(data.suffix(parsedTailLength))
    }

    private static func completeRecords(_ data: Data) -> Data {
        guard let end = data.lastIndex(of: 0x0A) else { return Data() }
        return Data(data.prefix(through: end))
    }

    private static func lines(_ data: Data) -> [Substring] {
        // Blank records still occupy a line in the native file. Preserve
        // their position so append-time event IDs match the initial tail.
        Array(String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false).dropLast())
    }

    private static func events(in lines: [Substring], reader: any TranscriptLineReading, firstLine: Int) -> [TranscriptEvent] {
        lines.enumerated().flatMap { index, line -> [TranscriptEvent] in
            guard reader.agent != .codexCLI || isVisibleCodexRecord(line) else { return [] }
            return reader.readRecords([line]).enumerated().compactMap { entryIndex, entry in
                TranscriptEvent.Content(entry).map {
                    TranscriptEvent(id: "\(firstLine + index):\(entryIndex)", content: $0)
                }
            }
        }
    }

    /// Codex stores harness instructions in the same rollout as the conversation.
    /// Keep their native records for resume, but never publish them as chat.
    private static func isVisibleCodexRecord(_ line: Substring) -> Bool {
        guard let data = line.data(using: .utf8),
              let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              record["type"] as? String == "response_item",
              let payload = record["payload"] as? [String: Any],
              payload["type"] as? String == "message" else { return true }

        guard let role = payload["role"] as? String else { return false }
        if role != "user" { return role == "assistant" }

        let parts = payload["content"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !(text.hasPrefix("# AGENTS.md instructions for ") && text.contains("<INSTRUCTIONS>"))
            && !(text.hasPrefix("<environment_context>") && text.hasSuffix("</environment_context>"))
    }

    private static func tailEvents(in data: Data, reader: any TranscriptLineReading) -> (events: [TranscriptEvent], totalLines: Int) {
        guard !data.isEmpty else { return ([], 0) }
        let totalLines = countNewlines(in: data)
        guard totalLines > 0 else { return ([], 0) }

        // Read up to 1,000 lines from the tail: more than enough to yield
        // CompanionProtocol.transcriptEventLimit (400 events) while avoiding
        // allocating and splitting megabytes of historical JSONL records.
        let targetTailLines = min(totalLines, max(1000, CompanionProtocol.transcriptEventLimit * 2))
        if let (offset, linesInTail) = tailNewlineOffset(in: data, maxLines: targetTailLines) {
            let tailData = data.subdata(in: offset..<data.count)
            let tailLines = Self.lines(tailData)
            let firstLineIndex = totalLines - linesInTail
            let events = recentEvents(in: tailLines, reader: reader, firstLine: firstLineIndex)
            if events.count >= CompanionProtocol.transcriptEventLimit || offset == 0 {
                return (events, totalLines)
            }
        }

        // Fallback in case the tail had fewer than 400 events due to filtered records:
        let lines = Self.lines(data)
        return (recentEvents(in: lines, reader: reader, firstLine: 0), totalLines)
    }

    private static func countNewlines(in data: Data) -> Int {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return 0 }
            var count = 0
            var ptr = base
            var remaining = rawBuffer.count
            while remaining > 0, let next = memchr(ptr, Int32(0x0A), remaining) {
                let found = UnsafeRawPointer(next)
                count += 1
                let consumed = (found - ptr) + 1
                ptr = found + 1
                remaining -= consumed
            }
            return count
        }
    }

    private static func tailNewlineOffset(in data: Data, maxLines: Int) -> (offset: Int, linesFound: Int)? {
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var count = 0
            var i = rawBuffer.count - 1
            if i >= 0 && base[i] == 0x0A {
                i -= 1
            }
            while i >= 0 {
                if base[i] == 0x0A {
                    count += 1
                    if count == maxLines {
                        return (i + 1, count)
                    }
                }
                i -= 1
            }
            return (0, count + (rawBuffer.count > 0 ? 1 : 0))
        }
    }

    private static func recentEvents(in lines: [Substring], reader: any TranscriptLineReading, firstLine: Int = 0) -> [TranscriptEvent] {
        var latestReversed: [TranscriptEvent] = []
        for index in lines.indices.reversed() {
            let events = self.events(in: [lines[index]], reader: reader, firstLine: firstLine + index)
            for event in events.reversed() {
                latestReversed.append(event)
            }
            if latestReversed.count >= CompanionProtocol.transcriptEventLimit { break }
        }
        return Array(latestReversed.reversed().suffix(CompanionProtocol.transcriptEventLimit))
    }

    func forget(_ sessionID: UUID) {
        cache[sessionID] = nil
    }

    /// Newest events only, with ids from their absolute position so a growing
    /// transcript keeps every earlier event's identity.
    static func transcript(from entries: [CanonicalEntry], limit: Int = CompanionProtocol.transcriptEventLimit, offset: Int = 0) -> SessionTranscript {
        let events = entries.enumerated().compactMap { index, entry -> TranscriptEvent? in
            TranscriptEvent.Content(entry).map { TranscriptEvent(id: String(offset + index), content: $0) }
        }
        return SessionTranscript(events: Array(events.suffix(limit)))
    }

    /// Mirrors `HandoffService.plan`'s lookup: recorded path, then the codec's
    /// own derivation from the pinned id, then discovery by working directory.
    private func locate(_ session: Session, reader: any TranscriptReading) -> URL? {
        if let path = session.nativeTranscriptPath, FileManager.default.fileExists(atPath: path.path) {
            return path
        }
        if let nativeID = session.agentSessionID, !nativeID.isEmpty,
           let found = try? reader.transcriptURL(sessionID: nativeID, workingDirectory: session.workingDirectory) {
            return found
        }
        if session.agentSessionID == nil,
           let discovered = try? reader.discoverSession(
               workingDirectory: session.workingDirectory,
               since: session.createdAt.addingTimeInterval(-30)
           ) {
            return discovered.url
        }
        return nil
    }
}

/// Watches one transcript file for writes via a raw file descriptor, since
/// the agent CLI appends to the same path for a session's whole lifetime.
/// Only ever created, started, and stopped from `CompanionTranscriptReader`'s
/// actor-isolated methods; its own event handler runs on the main queue and
/// only calls the `onChange` callback, which is itself thread-safe.
private final class TranscriptFileWatcher: @unchecked Sendable {
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
    }

    func start(url: URL) {
        stop()
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.onChange() }
        source.setCancelHandler { [fd] in close(fd) }
        self.source = source
        source.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
