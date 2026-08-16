import Foundation
import AppKit
import SwiftTerm
import ProcessKit

/// A distinct renderer for each place a session can appear. Xirp keeps its
/// full-session and grid terminals independent so moving between layouts
/// fits the terminal to the new pane instead of scaling/reparenting a live
/// renderer that was measured for another container.
public enum TerminalPresentation: Hashable, Sendable {
    case session
    case grid
}

/// Owns the PTY subscription for one session and fans its output out to an
/// independent `SwiftTerm.TerminalView` per presentation. There is still
/// exactly one input/output controller per process, so terminal history is
/// persisted once even while more than one renderer is kept warm.
/// `@unchecked Sendable` so the output-consuming `Task` can capture `self`
/// across the actor boundary; all mutation happens back on the main actor
/// via `terminalView.feed`, so this mirrors the same pattern used by
/// `SystemPTYProcess`/`MockPTYProcess`.
public final class TerminalController: NSObject, TerminalViewDelegate, @unchecked Sendable {
    public let sessionID: UUID
    public let processID: UUID
    public var terminalView: TerminalView { sessionTerminalView }

    private let process: PTYProcessProtocol
    private let outputHandler: @MainActor @Sendable (Data) -> Void
    private let inputHandler: @MainActor @Sendable () -> Void
    private let multilineNewlineSequence: Data
    private let accessibilityIdentifier: String
    private let sessionTerminalView: TerminalView
    private var terminalViews: [TerminalPresentation: TerminalView]
    private var replayBuffer: Data
    private var fontSize = 14.0
    private var optionAsMetaKey = true
    private var scrollSensitivity = 1.0
    private var gpuRendering = false
    private var outputTask: Task<Void, Never>?
    private var accessibilityTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var hasSentInitialResize = false
    private let pendingOutput = CoalescingOutputBuffer()
    private var lastPublishedAccessibleText: [ObjectIdentifier: String] = [:]

    /// Number of times `flushPendingOutput` has actually fed the renderers,
    /// as opposed to the number of PTY reads received. Exposed so tests can
    /// assert that a burst of reads collapses into far fewer flushes.
    public private(set) var outputFlushCount = 0

    private static let maximumReplayBytes = 2 * 1_024 * 1_024
    private static let replayTrimSlack = 256 * 1_024

    /// `accessibilityIdentifier` must be unique per session (e.g. include
    /// the session title) — Grid View can show several terminals mounted
    /// simultaneously, so a fixed identifier would be ambiguous.
    public init(
        sessionID: UUID,
        process: PTYProcessProtocol,
        accessibilityIdentifier: String,
        initialScrollback: Data = Data(),
        multilineNewlineSequence: Data = Data([0x1B, 0x0D]),
        outputHandler: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        inputHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        let sessionTerminalView = Self.makeTerminalView(for: .session)
        self.sessionID = sessionID
        self.processID = process.id
        self.process = process
        self.outputHandler = outputHandler
        self.inputHandler = inputHandler
        self.multilineNewlineSequence = multilineNewlineSequence
        self.accessibilityIdentifier = accessibilityIdentifier
        self.sessionTerminalView = sessionTerminalView
        self.terminalViews = [.session: sessionTerminalView]
        self.replayBuffer = initialScrollback
        super.init()
        configure(sessionTerminalView)
        if !initialScrollback.isEmpty {
            let bytes = [UInt8](initialScrollback)
            TerminalPerfLog.measure(
                "TerminalController.replayInitialScrollback",
                "\(accessibilityIdentifier) \(bytes.count)B"
            ) {
                sessionTerminalView.feed(byteArray: bytes[...])
                publishAccessibleContent()
            }
        }
        consumeOutput()
    }

    /// Returns a stable renderer for one presentation. Creating the grid
    /// renderer replays the controller's transcript into it, then both
    /// renderers receive every subsequent PTY chunk in lockstep.
    @MainActor
    public func terminalView(for presentation: TerminalPresentation) -> TerminalView {
        if let existing = terminalViews[presentation] {
            return existing
        }

        return TerminalPerfLog.measure(
            "TerminalController.makeRenderer",
            "\(accessibilityIdentifier) presentation=\(presentation) replay=\(replayBuffer.count)B"
        ) {
            let view = Self.makeTerminalView(for: presentation)
            terminalViews[presentation] = view
            configure(view)
            if !replayBuffer.isEmpty {
                let bytes = [UInt8](replayBuffer)
                view.feed(byteArray: bytes[...])
                publishAccessibleContent(for: view)
            }
            return view
        }
    }

    /// The text the emulator currently has on screen.
    ///
    /// This is the same buffer read-out already published for accessibility,
    /// exposed so status inference can look at what the agent is *drawing*
    /// instead of guessing from how many bytes it wrote. Reading it is free —
    /// no process is spawned and the emulator is not disturbed.
    @MainActor
    public func visibleScreenText() -> String? {
        guard let terminal = sessionTerminalView.terminal else { return nil }
        return String(decoding: terminal.getBufferAsData(), as: UTF8.self)
    }

    /// Applies host-app presentation preferences without recreating the
    /// terminal view or disturbing its scrollback buffer.
    @MainActor
    public func applyPreferences(
        fontSize: Double,
        optionAsMetaKey: Bool,
        scrollSensitivity: Double,
        gpuRendering: Bool = false
    ) {
        self.fontSize = fontSize
        self.optionAsMetaKey = optionAsMetaKey
        self.scrollSensitivity = scrollSensitivity
        self.gpuRendering = gpuRendering
        for view in terminalViews.values {
            configureXirpAppearance(view, fontSize: CGFloat(fontSize))
            view.optionAsMetaKey = optionAsMetaKey
            view.scrollSensitivity = CGFloat(scrollSensitivity)
            view.scrollerStyle = .overlay
            applyRenderer(gpuRendering, to: view)
        }
    }

    /// Falls back to CoreGraphics on any failure (e.g. no Metal device) —
    /// `setUseMetal` is best-effort, never a hard requirement to render.
    private func applyRenderer(_ gpuRendering: Bool, to view: TerminalView) {
        try? view.setUseMetal(gpuRendering)
    }

    /// Xirp's default prompt bindings submit with Return and insert a
    /// multiline newline with Shift-Return. The host view intercepts that
    /// gesture before SwiftTerm collapses it to a regular carriage return.
    public func sendMultilineNewline() {
        process.send(input: multilineNewlineSequence)
        Task { @MainActor in inputHandler() }
    }

    private static func makeTerminalView(for presentation: TerminalPresentation) -> TerminalView {
        FlotillaTerminalView(
            frame: .zero,
            options: TerminalOptions(
                cursorStyle: .steadyBlock,
                scrollback: 0
            )
        )
    }

    private func configure(_ view: TerminalView) {
        view.terminalDelegate = self
        applyRenderer(gpuRendering, to: view)
        // SwiftTerm's custom-drawn content is not exposed in the AX tree, so
        // republish each renderer's buffer for assistive technology and UI
        // automation. Only the currently mounted presentation is visible.
        view.setAccessibilityElement(true)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityValue("")
        configureXirpAppearance(view, fontSize: CGFloat(fontSize))
        view.optionAsMetaKey = optionAsMetaKey
        view.scrollSensitivity = CGFloat(scrollSensitivity)
        view.scrollerStyle = .overlay
    }

    /// Mirrors Xirp's default xterm.js presentation. Xirp ships a Nerd Font
    /// stack, uses 14 pt by default, and fixes its dark terminal palette even
    /// when the surrounding application follows the system appearance.
    private func configureXirpAppearance(_ terminalView: TerminalView, fontSize: CGFloat) {
        let preferredFontNames = [
            "JetBrainsMono Nerd Font Mono",
            "MesloLGS Nerd Font Mono",
            "FiraCode Nerd Font Mono",
            "Hack Nerd Font Mono",
            "Symbols Nerd Font Mono",
            "JetBrains Mono",
            "Fira Code",
            "Menlo",
        ]
        terminalView.font = preferredFontNames.lazy
            .compactMap { NSFont(name: $0, size: fontSize) }
            .first
            ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)

        terminalView.nativeBackgroundColor = NSColor(
            srgbRed: 10 / 255,
            green: 10 / 255,
            blue: 12 / 255,
            alpha: 1
        )
        terminalView.nativeForegroundColor = NSColor(
            srgbRed: 245 / 255,
            green: 245 / 255,
            blue: 248 / 255,
            alpha: 1
        )
        terminalView.caretColor = terminalView.nativeForegroundColor
        terminalView.selectedTextBackgroundColor = NSColor(
            srgbRed: 50 / 255,
            green: 50 / 255,
            blue: 58 / 255,
            alpha: 1
        )
        terminalView.selectedTextForegroundColor = terminalView.nativeForegroundColor
        terminalView.installColors(Self.makeXirpANSIColors())
        terminalView.useBrightColors = true
    }

    private static func makeXirpANSIColors() -> [SwiftTerm.Color] {
        [
            .init(red8: 0x32, green8: 0x32, blue8: 0x3A),
            .init(red8: 0xF8, green8: 0x71, blue8: 0x71),
            .init(red8: 0x34, green8: 0xD3, blue8: 0x99),
            .init(red8: 0xFB, green8: 0xBF, blue8: 0x24),
            .init(red8: 0x60, green8: 0xA5, blue8: 0xFA),
            .init(red8: 0xE8, green8: 0x79, blue8: 0xF9),
            .init(red8: 0x22, green8: 0xD3, blue8: 0xEE),
            .init(red8: 0xB9, green8: 0xB9, blue8: 0xC3),
            .init(red8: 0x73, green8: 0x73, blue8: 0x7E),
            .init(red8: 0xF8, green8: 0x71, blue8: 0x71),
            .init(red8: 0x34, green8: 0xD3, blue8: 0x99),
            .init(red8: 0xFB, green8: 0xBF, blue8: 0x24),
            .init(red8: 0x60, green8: 0xA5, blue8: 0xFA),
            .init(red8: 0xE8, green8: 0x79, blue8: 0xF9),
            .init(red8: 0x22, green8: 0xD3, blue8: 0xEE),
            .init(red8: 0xF5, green8: 0xF5, blue8: 0xF8),
        ]
    }

    deinit {
        outputTask?.cancel()
        accessibilityTask?.cancel()
        resizeTask?.cancel()
    }

    private func consumeOutput() {
        let stream = process.outputStream
        outputTask = Task { [weak self] in
            for await chunk in stream {
                guard let self else { return }
                if self.pendingOutput.append(chunk) {
                    Task { @MainActor [weak self] in
                        self?.flushPendingOutput()
                    }
                }
            }
            // The stream finished (process exited) — drain whatever arrived
            // after the last scheduled flush so no trailing output is lost.
            await MainActor.run { [weak self] in
                self?.flushPendingOutput()
            }
        }
    }

    /// Drains everything buffered since the last flush and applies it to the
    /// emulator(s) exactly once, regardless of how many PTY reads produced
    /// it. Coalescing here means a TUI's cursor-hide/cursor-show escape pair
    /// — or any other multi-chunk repaint — always resolves within a single
    /// flush instead of being visible mid-repaint for a runloop turn.
    @MainActor
    private func flushPendingOutput() {
        let data = pendingOutput.drain()
        guard !data.isEmpty else { return }
        outputFlushCount += 1
        appendToReplayBuffer(data)
        let bytes = [UInt8](data)
        TerminalPerfLog.measure(
            "TerminalController.feed",
            "\(accessibilityIdentifier) \(bytes.count)B → \(terminalViews.count) renderer(s)"
        ) {
            for view in terminalViews.values {
                view.feed(byteArray: bytes[...])
            }
        }
        outputHandler(data)
        scheduleAccessibleContentPublication()
    }

    @MainActor
    private func scheduleAccessibleContentPublication() {
        accessibilityTask?.cancel()
        accessibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.publishAccessibleContent()
        }
    }

    @MainActor
    private func appendToReplayBuffer(_ data: Data) {
        replayBuffer.append(data)
        // Trim with slack rather than back down to the cap on every chunk:
        // this turns an O(chunks) sequence of full-buffer copies into an
        // amortized O(1) one, at the cost of briefly overshooting the cap by
        // up to `replayTrimSlack` bytes.
        if replayBuffer.count > Self.maximumReplayBytes + Self.replayTrimSlack {
            replayBuffer = Data(replayBuffer.suffix(Self.maximumReplayBytes))
        }
    }

    private func publishAccessibleContent() {
        for view in terminalViews.values {
            publishAccessibleContent(for: view)
        }
    }

    /// Skips renderers that aren't mounted (no `window`) and skips the
    /// `setAccessibilityValue` call entirely when the serialized buffer text
    /// hasn't changed since the last publish — both `getBufferAsData` and the
    /// AX write are otherwise paid on every debounce tick per renderer.
    private func publishAccessibleContent(for terminalView: TerminalView) {
        guard terminalView.window != nil, let terminal = terminalView.terminal else { return }
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        let key = ObjectIdentifier(terminalView)
        guard lastPublishedAccessibleText[key] != text else { return }
        lastPublishedAccessibleText[key] = text
        terminalView.setAccessibilityValue(text)
    }

    // MARK: - TerminalViewDelegate

    public func send(source: TerminalView, data: ArraySlice<UInt8>) {
        process.send(input: Data(data))
        Task { @MainActor in inputHandler() }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // The process starts at a deliberately narrow guessed size (see
        // SessionProcessManager) before any terminal view has laid out. The
        // first real measurement corrects that mismatch immediately, so the
        // agent redraws its startup screen at the true size before it can
        // print much at the wrong one. Later calls, from a live grid reflow,
        // still wait for pane layout to settle so we don't send a stream of
        // transient dimensions mid-drag.
        resizeTask?.cancel()
        TerminalPerfLog.event("sizeChanged \(accessibilityIdentifier) → \(newCols)x\(newRows) initial=\(!hasSentInitialResize)")
        guard hasSentInitialResize else {
            hasSentInitialResize = true
            process.resize(PTYSize(cols: newCols, rows: newRows))
            return
        }
        resizeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            TerminalPerfLog.event("PTY resize \(self.accessibilityIdentifier) → \(newCols)x\(newRows)")
            self.process.resize(PTYSize(cols: newCols, rows: newRows))
        }
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func scrolled(source: TerminalView, position: Double) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let string = String(data: content, encoding: .utf8) {
            pasteboard.setString(string, forType: .string)
        }
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func bell(source: TerminalView) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
