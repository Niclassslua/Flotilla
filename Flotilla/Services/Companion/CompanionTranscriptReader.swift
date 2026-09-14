import Foundation
import SessionKit
import TranscriptKit
import CompanionKit

/// Reads a session's native transcript for the phone, re-parsing only when the
/// file changed (docs/companion.md, A8).
actor CompanionTranscriptReader {
    private let registry: TranscriptCodecRegistry
    private var cache: [UUID: (url: URL, modified: Date, size: Int, transcript: SessionTranscript)] = [:]
    private var watchers: [UUID: TranscriptFileWatcher] = [:]
    private let changeStream: AsyncStream<Void>
    private let changeContinuation: AsyncStream<Void>.Continuation

    /// Emits whenever a watched session's transcript file changes on disk.
    nonisolated var changes: AsyncStream<Void> { changeStream }

    init(registry: TranscriptCodecRegistry) {
        self.registry = registry
        var continuation: AsyncStream<Void>.Continuation!
        self.changeStream = AsyncStream { continuation = $0 }
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
        guard let entries = try? reader.readNative(at: url) else {
            return cache[session.id]?.transcript ?? SessionTranscript()
        }
        let transcript = Self.transcript(from: entries)
        cache[session.id] = (url, modified, size, transcript)
        return transcript
    }

    func forget(_ sessionID: UUID) {
        cache[sessionID] = nil
    }

    /// Newest events only, with ids from their absolute position so a growing
    /// transcript keeps every earlier event's identity.
    static func transcript(from entries: [CanonicalEntry], limit: Int = CompanionProtocol.transcriptEventLimit) -> SessionTranscript {
        let events = entries.enumerated().compactMap { index, entry -> TranscriptEvent? in
            TranscriptEvent.Content(entry).map { TranscriptEvent(id: String(index), content: $0) }
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
