import Foundation
import SessionKit
import TranscriptKit
import CompanionKit
import os

/// Reads a session's native transcript for the phone, re-parsing only when the
/// file changed (docs/companion.md, A8).
actor CompanionTranscriptReader {
    private static let performance = Logger(subsystem: "com.niclassslua.flotilla", category: "CompanionPerformance")
    private let registry: TranscriptCodecRegistry
    private struct Cached {
        var url: URL
        var modified: Date
        var size: Int
        var parsedSize: Int
        var lineCount: Int
        var transcript: SessionTranscript
    }
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

    static let openCodeUnavailable = "OpenCode doesn't expose its transcript, so messages for this session are only visible in the terminal on your Mac."

    /// `nil` when nothing has changed since the last call for this session.
    func transcript(for session: Session, ifChangedSince previous: SessionTranscript?) -> SessionTranscript? {
        let result = read(session)
        return result == previous ? nil : result
    }

    func read(_ session: Session) -> SessionTranscript {
        let started = Date()
        defer {
            Self.performance.debug("transcript read \(Date().timeIntervalSince(started), format: .fixed(precision: 4))s")
        }
        guard let reader = registry.reader(for: session.agent) else {
            return SessionTranscript(unavailableReason: session.agent == .openCode ? Self.openCodeUnavailable : "No transcript is available for this session.")
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
            if (try? handle.seek(toOffset: UInt64(cached.parsedSize))) != nil,
               let bytes = try? handle.readToEnd() {
                let complete = Self.completeRecords(bytes)
                if !complete.isEmpty {
                    let lines = Self.lines(complete)
                    cached.transcript.events.append(contentsOf: Self.events(in: lines, reader: lineReader, firstLine: cached.lineCount))
                    cached.transcript.events = Array(cached.transcript.events.suffix(CompanionProtocol.transcriptEventLimit))
                    cached.lineCount += lines.count
                    cached.parsedSize += complete.count
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
            let lines = Self.lines(complete)
            let transcript = SessionTranscript(events: Self.recentEvents(in: lines, reader: lineReader))
            cache[session.id] = Cached(url: url, modified: modified, size: bytes.count,
                                       parsedSize: complete.count, lineCount: lines.count, transcript: transcript)
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
        lines.enumerated().flatMap { index, line in
            reader.readRecords([line]).enumerated().compactMap { entryIndex, entry in
                TranscriptEvent.Content(entry).map {
                    TranscriptEvent(id: "\(firstLine + index):\(entryIndex)", content: $0)
                }
            }
        }
    }

    private static func recentEvents(in lines: [Substring], reader: any TranscriptLineReading) -> [TranscriptEvent] {
        var latest: [TranscriptEvent] = []
        for index in lines.indices.reversed() {
            let events = self.events(in: [lines[index]], reader: reader, firstLine: index)
            latest.insert(contentsOf: events, at: 0)
            if latest.count >= CompanionProtocol.transcriptEventLimit { break }
        }
        return Array(latest.suffix(CompanionProtocol.transcriptEventLimit))
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
