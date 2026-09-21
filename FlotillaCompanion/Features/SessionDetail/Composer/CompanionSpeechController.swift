import AVFoundation
import CompanionKit
import Foundation
import Observation

struct CompanionAudioLevelSample: Identifiable, Equatable, Sendable {
    let id: UInt64
    let level: Double
}

/// Levels for every waveform slot one capture buffer touched. The last
/// sample is the slot still being recorded; it is republished (only ever
/// growing) until the slot completes.
struct CompanionAudioLevelUpdate: Sendable {
    let samples: [CompanionAudioLevelSample]
    /// Recorded audio duration, in seconds, at the end of the buffer.
    let audioTime: TimeInterval
}

/// Turns 16 kHz mono samples into one level per fixed-length waveform slot.
///
/// Each slot shows the loudest 20 ms window it contains, on a fixed dBFS
/// scale. There is deliberately no smoothing or automatic gain: a bar is a
/// snapshot of that moment, so one loud sound can never flatten the bars
/// that follow it.
struct CompanionAudioLevelMeter {
    static let sampleRate = 16_000.0
    static let slotDuration = 0.2
    static let floorDecibels = -50.0
    static let ceilingDecibels = -10.0

    private let slotLength = Int(sampleRate * slotDuration)
    private let windowLength = Int(sampleRate * 0.02)
    private var sampleIndex = 0
    private var windowSumOfSquares = 0.0
    private var windowCount = 0
    private var slotPeak = 0.0

    static func level(rms: Double) -> Double {
        guard rms > 0 else { return 0 }
        let decibels = 20 * log10(rms)
        return min(1, max(0, (decibels - floorDecibels) / (ceilingDecibels - floorDecibels)))
    }

    mutating func process(_ samples: UnsafeBufferPointer<Float>) -> CompanionAudioLevelUpdate {
        var completed: [CompanionAudioLevelSample] = []
        for sample in samples {
            let value = Double(sample)
            windowSumOfSquares += value * value
            windowCount += 1
            sampleIndex += 1
            if windowCount == windowLength { closeWindow() }
            if sampleIndex % slotLength == 0 {
                completed.append(CompanionAudioLevelSample(
                    id: UInt64(sampleIndex / slotLength - 1), level: slotPeak
                ))
                slotPeak = 0
            }
        }
        // Include the partial window so the live slot reacts within one buffer.
        var livePeak = slotPeak
        if windowCount > 0 {
            livePeak = max(livePeak, Self.level(rms: (windowSumOfSquares / Double(windowCount)).squareRoot()))
        }
        if sampleIndex % slotLength != 0 {
            completed.append(CompanionAudioLevelSample(id: UInt64(sampleIndex / slotLength), level: livePeak))
        }
        return CompanionAudioLevelUpdate(samples: completed,
                                         audioTime: Double(sampleIndex) / Self.sampleRate)
    }

    private mutating func closeWindow() {
        let rms = (windowSumOfSquares / Double(windowCount)).squareRoot()
        slotPeak = max(slotPeak, Self.level(rms: rms))
        windowSumOfSquares = 0
        windowCount = 0
    }
}

private final class CompanionAudioCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private let lock = NSLock()
    private var pending = Data()
    private let continuation: AsyncStream<Data>.Continuation
    let chunks: AsyncStream<Data>
    private let onOverflow: @Sendable () -> Void
    private let onLevel: @Sendable (CompanionAudioLevelUpdate) -> Void
    /// Only touched from the input tap, which AVAudioEngine calls serially.
    private var meter = CompanionAudioLevelMeter()

    init(onOverflow: @escaping @Sendable () -> Void,
         onLevel: @escaping @Sendable (CompanionAudioLevelUpdate) -> Void) {
        self.onOverflow = onOverflow
        self.onLevel = onLevel
        let pair = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingOldest(20))
        chunks = pair.stream
        continuation = pair.continuation
    }

    func start() throws {
#if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [])
        try session.setActive(true)
#endif
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw CompanionActionError(message: "The microphone format is unavailable.")
        }
        self.converter = converter
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { [weak self] buffer, _ in
            self?.convert(buffer, using: converter, inputFormat: inputFormat)
        }
        try engine.start()
    }

    func stop() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        lock.lock()
        let remainder = pending
        pending.removeAll(keepingCapacity: false)
        lock.unlock()
        if !remainder.isEmpty {
            if case .dropped = continuation.yield(remainder) { onOverflow() }
        }
        continuation.finish()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false)
        #endif
    }

    private func convert(_ input: AVAudioPCMBuffer, using converter: AVAudioConverter,
                         inputFormat: AVAudioFormat) {
        let capacity = AVAudioFrameCount(Double(input.frameLength) * 16_000 / inputFormat.sampleRate + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            guard !supplied else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard error == nil, status != .error, let floats = output.floatChannelData?[0] else { return }
        let frameCount = Int(output.frameLength)
        if frameCount > 0 {
            onLevel(meter.process(UnsafeBufferPointer(start: floats, count: frameCount)))
        }
        var chunksToYield: [Data] = []
        lock.lock()
        for index in 0..<Int(output.frameLength) {
            let sample = Int16((max(-1, min(1, floats[index])) * 32_767).rounded())
            pending.append(UInt8(truncatingIfNeeded: sample))
            pending.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        while pending.count >= 3_200 {
            let chunk = Data(pending.prefix(3_200))
            pending.removeFirst(3_200)
            chunksToYield.append(chunk)
        }
        lock.unlock()
        for chunk in chunksToYield {
            if case .dropped = continuation.yield(chunk) { onOverflow() }
        }
    }
}

@MainActor
@Observable
final class CompanionSpeechController {
    enum Phase: Equatable {
        case idle
        case checking
        case recording
        case processing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var isAvailable: Bool = false
    private(set) var audioLevels: [CompanionAudioLevelSample] = []
    private(set) var audioStartTime: TimeInterval?
    private var requestID: UUID?
    private var capture: CompanionAudioCapture?
    private var pump: Task<Void, Never>?
    private var generation: UInt64 = 0

    func checkAvailability(store: CompanionStore, sessionID: UUID) async {
        guard let macID = store.data.macID(for: sessionID) else {
            isAvailable = false
            return
        }
        let available = store.data.isSpeechAvailable(on: macID)
        if isAvailable != available {
            isAvailable = available
        }
        if let mac = store.mac(macID), mac.isReachable {
            do {
                let capabilities = try await store.data.speech(.speechCapabilities, on: macID)
                if case let .capabilities(status, _) = capabilities {
                    isAvailable = (status == "ready")
                } else {
                    isAvailable = false
                }
            } catch {
                isAvailable = false
            }
        }
    }

    func begin(store: CompanionStore, sessionID: UUID) async {
        guard isAvailable, phase == .idle, let macID = store.data.macID(for: sessionID) else { return }
        generation &+= 1
        let current = generation
        phase = .checking
        do {
            let capabilities = try await store.data.speech(.speechCapabilities, on: macID)
            guard case .capabilities("ready", _) = capabilities else {
                isAvailable = false
                throw CompanionActionError(message: message(for: capabilities))
            }
            let permission = await AVAudioApplication.requestRecordPermission()
            guard permission else { throw CompanionActionError(message: "Microphone access is required to dictate.") }
            let id = UUID()
            let started = try await store.data.speech(.speechStart(CompanionSpeechStart(requestID: id)), on: macID)
            guard case .started(id, _) = started, generation == current else {
                throw CompanionActionError(message: message(for: started))
            }
            requestID = id
            let capture = CompanionAudioCapture(
                onOverflow: { [weak self] in
                    Task { @MainActor in self?.fail("Audio could not keep up with the connection.",
                                                    store: store, macID: macID) }
                },
                onLevel: { [weak self] update in
                    Task { @MainActor in self?.recordAudioLevels(update) }
                }
            )
            self.capture = capture
            try capture.start()
            phase = .recording
            pump = Task { [weak self] in
                var sequence = 0
                for await chunk in capture.chunks {
                    guard let self, self.generation == current else { return }
                    do {
                        var retries = 0
                        while true {
                            let result = try await store.data.speech(
                                .speechAudio(requestID: id, sequence: sequence, pcm: chunk), on: macID)
                            switch result {
                            case .audioAck(id, let next) where next == sequence + 1:
                                sequence = next
                            case .slowDown(id, let next) where next == sequence && retries < 20:
                                retries += 1
                                try await Task.sleep(for: .milliseconds(100))
                                continue
                            default:
                                throw CompanionActionError(message: self.message(for: result))
                            }
                            break
                        }
                    } catch {
                        self.fail(error.localizedDescription, store: store, macID: macID)
                        return
                    }
                }
            }
        } catch {
            if generation == current { phase = .failed(error.localizedDescription) }
        }
    }

    func finish(store: CompanionStore, sessionID: UUID) async -> String? {
        guard phase == .recording, let id = requestID,
              let macID = store.data.macID(for: sessionID) else { return nil }
        phase = .processing
        capture?.stop()
        capture = nil
        resetAudioLevels()
        await pump?.value
        pump = nil
        guard phase == .processing else { return nil }
        do {
            let result = try await store.data.speech(.speechFinish(requestID: id), on: macID)
            guard case .final(id, _, let text) = result else {
                throw CompanionActionError(message: message(for: result))
            }
            requestID = nil
            phase = .idle
            return text
        } catch {
            phase = .failed(error.localizedDescription)
            return nil
        }
    }

    func cancel(store: CompanionStore, sessionID: UUID) {
        generation &+= 1
        capture?.stop()
        capture = nil
        resetAudioLevels()
        pump?.cancel()
        pump = nil
        if let id = requestID, let macID = store.data.macID(for: sessionID) {
            Task { _ = try? await store.data.speech(.speechCancel(requestID: id), on: macID) }
        }
        requestID = nil
        phase = .idle
    }

    func dismissError() {
        if case .failed = phase { phase = .idle }
    }

    private func recordAudioLevels(_ update: CompanionAudioLevelUpdate) {
        guard phase == .recording else { return }
        if audioStartTime == nil {
            // Anchor the scrolling clock to the first delivered audio rather
            // than engine start, so the live slot sits at the leading edge
            // instead of trailing it by the input latency.
            audioStartTime = Date().timeIntervalSinceReferenceDate - update.audioTime
        }
        for sample in update.samples {
            if let last = audioLevels.last, last.id == sample.id {
                audioLevels[audioLevels.count - 1] = CompanionAudioLevelSample(
                    id: sample.id, level: max(last.level, sample.level)
                )
            } else if audioLevels.last.map({ sample.id > $0.id }) ?? true {
                audioLevels.append(sample)
            }
        }
        if audioLevels.count > 48 {
            audioLevels.removeFirst(audioLevels.count - 48)
        }
    }

    private func resetAudioLevels() {
        audioStartTime = nil
        audioLevels.removeAll(keepingCapacity: true)
    }

    private func fail(_ message: String, store: CompanionStore, macID: MacHost.ID) {
        guard phase != .idle else { return }
        let id = requestID
        generation &+= 1
        capture?.stop()
        capture = nil
        resetAudioLevels()
        pump?.cancel()
        pump = nil
        requestID = nil
        phase = .failed(message)
        if let id { Task { _ = try? await store.data.speech(.speechCancel(requestID: id), on: macID) } }
    }

    private func message(for event: CompanionSpeechEvent) -> String {
        switch event {
        case .failed(_, _, let message, _): message
        case .capabilities(let status, _): "Handy is \(status) on this Mac."
        default: "Handy could not continue transcription."
        }
    }
}
