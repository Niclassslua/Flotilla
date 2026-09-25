import Foundation
import AppKit
@preconcurrency import SwiftTerm
import ProcessKit

/// A distinct renderer for each place a session can appear. Xirp keeps its
/// full-session and grid terminals independent so moving between layouts
/// fits the terminal to the new pane instead of scaling/reparenting a live
/// renderer that was measured for another container.
public enum TerminalPresentation: Hashable, Sendable {
    case session
    case grid
    /// The small read-only preview on a Kanban card. It is a presentation of
    /// its own rather than a second mount of `.session`: an NSView has exactly
    /// one superview, so sharing the focused workspace's renderer meant every
    /// card reparented a live terminal out of wherever it was, re-measuring it
    /// for a 300×120 card and resizing the PTY behind it.
    case peek
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
    public private(set) var processID: UUID
    public var terminalView: TerminalView { sessionTerminalView }

    private var process: PTYProcessProtocol
    /// `var`, not `let`: `TerminalManager` caches one controller per session for
    /// the life of the app and hands it back to whichever view asks next, so the
    /// handlers a later caller passes have to be able to replace the ones the
    /// first mount installed — see `updateHandlers`.
    private var outputHandler: @MainActor @Sendable (Data) -> Void
    private var inputHandler: @MainActor @Sendable () -> Void
    private let multilineNewlineSequence: Data
    private var accessibilityIdentifier: String
    private var customReflowHandler: (@MainActor @Sendable (TerminalPresentation) -> Void)?
    private var onPTYResize: (@MainActor @Sendable (PTYSize) -> Void)?
    private let sessionTerminalView: TerminalView
    private var terminalViews: [TerminalPresentation: TerminalView]
    private var replayBuffer: Data
    private var fontSize = 14.0
    private var optionAsMetaKey = true
    private var scrollSensitivity = 1.0
    private var gpuRendering = false
    private var backgroundOpacity = 0.42
    private var outputTask: Task<Void, Never>?
    private var accessibilityTask: Task<Void, Never>?
    /// Keyed by presentation rather than single-valued: a grid tile scrolling
    /// into view would otherwise cancel the reflow the focused session's resize
    /// had just scheduled, leaving its transcript wrapped at the old width.
    private var resizeTasks: [TerminalPresentation: Task<Void, Never>] = [:]
    private var reflowTasks: [TerminalPresentation: Task<Void, Never>] = [:]
    private var hasSentInitialResize = false

    /// The column count each renderer's current contents were laid out at.
    /// `reflowOnDisplay` is a no-op when this still matches the renderer's
    /// width — re-wrapping only matters when the width actually changed, and
    /// the replay it would otherwise run costs a full emulator parse of
    /// `replayBuffer` on the main actor.
    private var reflowedColumns: [TerminalPresentation: Int] = [:]

    private var isReplaying = false
    private var authoritativePresentation: TerminalPresentation = .session
    private let pendingOutput = CoalescingOutputBuffer()
    private var lastPublishedAccessibleText: [ObjectIdentifier: String] = [:]

    /// Memoized `visibleScreenText()` — see there.
    private var cachedScreenText: String?
    private var cachedScreenPresentation: TerminalPresentation?

    /// Number of times `flushPendingOutput` has actually fed the renderers,
    /// as opposed to the number of PTY reads received. Exposed so tests can
    /// assert that a burst of reads collapses into far fewer flushes.
    public private(set) var outputFlushCount = 0

    /// Below this, a reported size is a layout artefact rather than a window
    /// anyone is looking at — see `sizeChanged`.
    private static let minimumUsableCols = 20
    private static let minimumUsableRows = 5

    private static let maximumReplayBytes = 2 * 1_024 * 1_024
    private static let replayTrimSlack = 256 * 1_024

    /// A new PTY client starts with full-screen addressing. Retained renderers
    /// and saved output may still have the previous client's DECLRMM/DECOM
    /// enabled, so even a correct tmux repaint wraps at the old right margin.
    /// CAN also terminates an escape sequence cut short by the old connection.
    /// These are display bytes only; keep history and the measured size intact.
    private static let connectionMarginReset = Data("\u{18}\u{1B}[?69l\u{1B}[?6l\u{1B}[r".utf8)

    /// `accessibilityIdentifier` must be unique per session (e.g. include
    /// the session title) — Grid View can show several terminals mounted
    /// simultaneously, so a fixed identifier would be ambiguous.
    @MainActor
    public init(
        sessionID: UUID,
        process: PTYProcessProtocol,
        accessibilityIdentifier: String,
        initialScrollback: Data = Data(),
        multilineNewlineSequence: Data = Data([0x1B, 0x0D]),
        customReflowHandler: (@MainActor @Sendable (TerminalPresentation) -> Void)? = nil,
        onPTYResize: (@MainActor @Sendable (PTYSize) -> Void)? = nil,
        outputHandler: @escaping @MainActor @Sendable (Data) -> Void = { _ in },
        inputHandler: @escaping @MainActor @Sendable () -> Void = {}
    ) {
        let sessionTerminalView = Self.makeTerminalView(for: .session)
        self.sessionID = sessionID
        self.processID = process.id
        self.process = process
        self.outputHandler = outputHandler
        self.inputHandler = inputHandler
        self.customReflowHandler = customReflowHandler
        self.onPTYResize = onPTYResize
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
                isReplaying = true
                sessionTerminalView.feed(byteArray: bytes[...])
                isReplaying = false
                Task { @MainActor in
                    await publishAccessibleContent()
                }
            }
            if customReflowHandler != nil {
                resetConnectionMargins()
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
                isReplaying = true
                view.feed(byteArray: bytes[...])
                isReplaying = false
                reflowedColumns[presentation] = view.getTerminal().getDims().cols
                Task { @MainActor in
                    await publishAccessibleContent(for: view)
                }
            }
            return view
        }
    }

    /// Returns the text content currently buffered in the renderer for `presentation`.
    @MainActor
    public func bufferText(for presentation: TerminalPresentation) -> String {
        guard let view = terminalViews[presentation] else { return "" }
        return String(decoding: view.getTerminal().getBufferAsData(), as: UTF8.self)
    }

    /// Marks a renderer as the one the user is looking at, so it — and only it
    /// — drives the PTY size from here on.
    ///
    /// `.peek` is never authoritative: a Kanban card is a thumbnail, and
    /// letting one resize the agent to card dimensions would wreck the session
    /// for every other view of it.
    ///
    /// This only records the intent. Pushing the size to the PTY is
    /// `syncPTYSize(for:)`'s job, because at the moment a view is mounted it is
    /// not yet in a window and has no real frame to measure — see there.
    @MainActor
    public func makeAuthoritative(_ presentation: TerminalPresentation) {
        guard presentation != .peek, authoritativePresentation != presentation else { return }
        authoritativePresentation = presentation
        invalidateScreenText()
        TerminalPerfLog.event("authoritative \(accessibilityIdentifier) → \(presentation)")
    }

    /// Pushes the renderer's measured size to the PTY, whether or not anything
    /// changed on the renderer's side.
    ///
    /// SwiftTerm only calls `sizeChanged` when its own column/row count
    /// changes, so a renderer restored to a size it already had reports
    /// nothing — and the PTY silently keeps whatever size the *other*
    /// presentation last set. Going full-screen → grid tile → full-screen used
    /// to leave the agent believing it still had the tile's dimensions, with
    /// the renderer drawing at the full size on top of it.
    ///
    /// The host view calls this once it is genuinely in a window and laid out,
    /// which is strictly after `makeNSView` returns: at mount time the view has
    /// no window and a zero frame, so measuring it there could only ever be
    /// skipped.
    @MainActor
    public func syncPTYSize(for presentation: TerminalPresentation) {
        guard presentation == authoritativePresentation else { return }
        guard let view = terminalViews[presentation],
              view.window != nil,
              view.frame.width > 0,
              view.frame.height > 0
        else { return }

        let dims = view.getTerminal().getDims()
        guard dims.cols >= Self.minimumUsableCols, dims.rows >= Self.minimumUsableRows else { return }

        // `applyResize` returns immediately when the PTY already has these
        // dimensions, which is the overwhelmingly common case: this runs from
        // `layout()`, so it is called on every pass of a live window drag.
        applyResize(PTYSize(cols: dims.cols, rows: dims.rows), for: presentation)
    }

    /// The single place a size reaches the PTY, whether it came from SwiftTerm
    /// noticing its own dimensions changed or from a renderer being mounted at
    /// a size it already had.
    ///
    /// Debounced after the first one. The first is sent immediately so the
    /// agent redraws its startup screen at the true size before it can print
    /// much at the guessed one; later ones wait for layout to settle, so
    /// dragging a window sends one resize rather than one per frame — each of
    /// which would otherwise cost a `SIGWINCH`, a full-screen TUI repaint, and
    /// for tmux-wrapped sessions a verification subprocess.
    @MainActor
    private func applyResize(_ size: PTYSize, for presentation: TerminalPresentation) {
        // Cancel before the equality check, not after. Resizing away and back
        // inside the debounce window arrives here as `size == lastAppliedSize`
        // while a task carrying the intermediate size is still pending — an
        // early return that left it queued would apply that stale size 150 ms
        // later, to a renderer that had already gone back.
        resizeTasks[presentation]?.cancel()
        resizeTasks[presentation] = nil
        guard size != lastAppliedSize else { return }

        guard hasSentInitialResize else {
            hasSentInitialResize = true
            lastAppliedSize = size
            TerminalPerfLog.event("PTY resize (initial) \(accessibilityIdentifier) → \(size.cols)x\(size.rows)")
            process.resize(size)
            reflowOnDisplay(presentation)
            // Hopped rather than called inline: this can run from inside
            // SwiftTerm's `setFrameSize`, and the handler reaches back into the
            // app's session state.
            Task { @MainActor [weak self] in self?.onPTYResize?(size) }
            return
        }

        resizeTasks[presentation] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.resizeTasks[presentation] = nil
            guard size != self.lastAppliedSize else { return }
            self.lastAppliedSize = size
            TerminalPerfLog.event("PTY resize \(self.accessibilityIdentifier) → \(size.cols)x\(size.rows)")
            self.process.resize(size)
            self.reflowOnDisplay(presentation)
            self.onPTYResize?(size)
        }
    }

    /// Replaces the host-supplied callbacks on a controller that outlives the
    /// view that created it. `TerminalManager` hands one cached controller to
    /// both the focused session view and the grid tile; without this the
    /// closures belonging to whichever mounted first stayed installed forever.
    @MainActor
    public func updateHandlers(
        accessibilityIdentifier: String? = nil,
        customReflowHandler: (@MainActor @Sendable (TerminalPresentation) -> Void)? = nil,
        onPTYResize: (@MainActor @Sendable (PTYSize) -> Void)? = nil,
        outputHandler: (@MainActor @Sendable (Data) -> Void)? = nil,
        inputHandler: (@MainActor @Sendable () -> Void)? = nil
    ) {
        self.customReflowHandler = customReflowHandler
        self.onPTYResize = onPTYResize
        if let outputHandler { self.outputHandler = outputHandler }
        if let inputHandler { self.inputHandler = inputHandler }
        // Renaming a session changes the identifier UI tests look the terminal
        // up by, so it has to follow the rename rather than stay pinned to the
        // title the session had when its controller was first created.
        if let accessibilityIdentifier, accessibilityIdentifier != self.accessibilityIdentifier {
            self.accessibilityIdentifier = accessibilityIdentifier
            for view in terminalViews.values {
                view.setAccessibilityIdentifier(accessibilityIdentifier)
            }
        }
    }

    /// Re-wraps one renderer's history at the size it currently has.
    ///
    /// Each presentation keeps its own emulator, and an emulator only wraps
    /// text at the width it had when the bytes arrived — resizing re-lays out
    /// the screen but does not re-flow what is already in it. So a renderer
    /// that was off-screen, or sitting in a narrow grid tile, while the agent
    /// was writing shows its transcript wrapped for the *old* width the moment
    /// it becomes the visible one: open a tile full-screen and the text stays
    /// hard-wrapped to the tile's column count.
    ///
    /// For tmux-wrapped sessions, the custom reflow handler triggers a server-side
    /// repaint (`refresh-client`) instead of replaying stale alt-screen frames.
    /// For non-tmux sessions, replaying the transcript into the reset emulator
    /// restores the state it would have had at this size.
    ///
    /// Debounced, because the mount that triggers this is immediately followed
    /// by the layout pass that gives the renderer its real size — replaying
    /// before that lands would just re-wrap at the stale width again.
    ///
    /// The replay is the single most expensive thing this class does: a full
    /// emulator parse of up to `maximumReplayBytes` on the main actor. It is
    /// therefore skipped whenever it provably cannot change anything — the
    /// renderer's width is what its contents were already laid out at, and it
    /// has not missed any output. Without that check, every tile scrolling back
    /// into a `LazyVGrid` paid a 2 MB parse for a re-wrap to the width it
    /// already had.
    @MainActor
    public func reflowOnDisplay(_ presentation: TerminalPresentation) {
        guard let view = terminalViews[presentation] else { return }
        reflowTasks[presentation]?.cancel()
        reflowTasks[presentation] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            self.reflowTasks[presentation] = nil

            // Measured after the debounce, not before: the layout pass that
            // gives the renderer its real width lands during that window.
            let columns = view.getTerminal().getDims().cols
            guard self.reflowedColumns[presentation] != columns else {
                TerminalPerfLog.event("reflow skipped (unchanged \(columns) cols) \(self.accessibilityIdentifier) presentation=\(presentation)")
                return
            }

            if let customReflow = self.customReflowHandler {
                TerminalPerfLog.event("customReflow \(self.accessibilityIdentifier) presentation=\(presentation)")
                self.reflowedColumns[presentation] = columns
                customReflow(presentation)
            } else {
                guard !self.replayBuffer.isEmpty else {
                    self.reflowedColumns[presentation] = columns
                    return
                }
                TerminalPerfLog.measure(
                    "TerminalController.reflow",
                    "\(self.accessibilityIdentifier) presentation=\(presentation) \(self.replayBuffer.count)B → \(columns) cols"
                ) {
                    view.getTerminal().resetToInitialState()
                    let bytes = [UInt8](self.replayBuffer)
                    self.isReplaying = true
                    view.feed(byteArray: bytes[...])
                    self.isReplaying = false
                }
                self.reflowedColumns[presentation] = columns
                self.invalidateScreenText()
                self.publishAccessibleContent(for: view)
            }
        }
    }

    /// The text the emulator currently has on screen.
    ///
    /// Reads from the authoritative mounted view (or falls back to session view),
    /// exposed so status inference looks at what the agent is actively drawing
    /// without disturbances.
    ///
    /// Memoized, because this is polled: `SessionScreenMonitor` asks every
    /// 900 ms and `SessionActivityStore` every 2 s, per running session, and
    /// both hop to the main actor to do it. `getBufferAsData` walks every cell
    /// of the emulator and allocates a fresh string, so an idle fleet was
    /// paying a full serialization per session per second to discover nothing
    /// had changed. The cache is dropped by `invalidateScreenText` wherever
    /// bytes are fed or the buffer is reset, which are the only ways its
    /// contents can move.
    @MainActor
    public func visibleScreenText() -> String? {
        if let cachedScreenText, cachedScreenPresentation == authoritativePresentation {
            return cachedScreenText
        }
        let activeView = terminalViews[authoritativePresentation] ?? sessionTerminalView
        guard let terminal = activeView.terminal ?? sessionTerminalView.terminal else { return nil }
        let text = String(decoding: terminal.getBufferAsData(), as: UTF8.self)
        cachedScreenText = text
        cachedScreenPresentation = authoritativePresentation
        return text
    }

    @MainActor
    private func invalidateScreenText() {
        cachedScreenText = nil
        cachedScreenPresentation = nil
    }

    /// The last size this controller successfully pushed to a PTY. Survives a
    /// `rebind`, so a replacement process can be told the real dimensions even
    /// when no renderer happens to be mounted at that instant.
    public private(set) var lastAppliedSize: PTYSize?

    /// Rebinds the controller to a replacement PTY process (e.g. after a non-destructive
    /// tmux reattach) while keeping existing TerminalViews, fonts, and scrollback warm.
    @MainActor
    public func rebind(process: PTYProcessProtocol) {
        self.outputTask?.cancel()
        flushPendingOutput()
        resetConnectionMargins()
        self.processID = process.id
        self.process = process
        self.hasSentInitialResize = false
        consumeOutput()

        // Re-send the size unconditionally. The replacement process was
        // launched at whatever default the manager guessed, and the renderer
        // it is now attached to will not report its size again unless the
        // *renderer's* dimensions change — which a reattach never does. Prefer
        // a live measurement, but fall back to the last size we applied so a
        // reattach that happens while nothing is mounted (the common case for
        // a background session) still lands.
        let measured: PTYSize? = {
            guard let currentView = terminalViews[authoritativePresentation],
                  currentView.window != nil,
                  currentView.frame.width > 0,
                  currentView.frame.height > 0
            else { return nil }
            let dims = currentView.getTerminal().getDims()
            guard dims.cols >= Self.minimumUsableCols, dims.rows >= Self.minimumUsableRows else { return nil }
            return PTYSize(cols: dims.cols, rows: dims.rows)
        }()

        guard let size = measured ?? lastAppliedSize else { return }
        TerminalPerfLog.event("rebind resize \(accessibilityIdentifier) → \(size.cols)x\(size.rows)")
        lastAppliedSize = size
        hasSentInitialResize = true
        process.resize(size)
        onPTYResize?(size)
    }

    @MainActor
    private func resetConnectionMargins() {
        // Record the boundary too: renderers created later replay the old
        // output, and must reach the same clean margin state before live data.
        appendToReplayBuffer(Self.connectionMarginReset)
        let bytes = [UInt8](Self.connectionMarginReset)
        isReplaying = true
        for view in terminalViews.values {
            view.feed(byteArray: bytes[...])
        }
        isReplaying = false
        invalidateScreenText()
    }

    /// Applies host-app presentation preferences without recreating the
    /// terminal view or disturbing its scrollback buffer.
    @MainActor
    public func applyPreferences(
        fontSize: Double,
        optionAsMetaKey: Bool,
        scrollSensitivity: Double,
        gpuRendering: Bool = false,
        backgroundOpacity: Double = 0.42
    ) {
        self.fontSize = fontSize
        self.optionAsMetaKey = optionAsMetaKey
        self.scrollSensitivity = scrollSensitivity
        self.gpuRendering = gpuRendering
        self.backgroundOpacity = backgroundOpacity
        for view in terminalViews.values {
            configureXirpAppearance(
                view,
                fontSize: CGFloat(fontSize),
                backgroundOpacity: CGFloat(backgroundOpacity)
            )
            view.optionAsMetaKey = optionAsMetaKey
            view.scrollSensitivity = CGFloat(scrollSensitivity)
            view.scrollerStyle = .overlay
            applyRenderer(gpuRendering, to: view)
        }
    }

    /// Falls back to CoreGraphics on any failure (e.g. no Metal device) —
    /// `setUseMetal` is best-effort, never a hard requirement to render.
    @MainActor
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

    @MainActor
    private static func makeTerminalView(for presentation: TerminalPresentation) -> TerminalView {
        FlotillaTerminalView(
            frame: .zero,
            options: TerminalOptions(
                cursorStyle: .steadyBlock,
                scrollback: 0
            )
        )
    }

    @MainActor
    private func configure(_ view: TerminalView) {
        view.terminalDelegate = self
        applyRenderer(gpuRendering, to: view)
        // SwiftTerm's custom-drawn content is not exposed in the AX tree, so
        // republish each renderer's buffer for assististive technology and UI
        // automation. Only the currently mounted presentation is visible.
        view.setAccessibilityElement(true)
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        view.setAccessibilityValue("")
        configureXirpAppearance(
            view,
            fontSize: CGFloat(fontSize),
            backgroundOpacity: CGFloat(backgroundOpacity)
        )
        view.optionAsMetaKey = optionAsMetaKey
        view.scrollSensitivity = CGFloat(scrollSensitivity)
        view.scrollerStyle = .overlay
    }

    /// Mirrors Xirp's default xterm.js presentation. Xirp ships a Nerd Font
    /// stack, uses 14 pt by default, and fixes its dark terminal palette even
    /// when the surrounding application follows the system appearance.
    @MainActor
    private func configureXirpAppearance(
        _ terminalView: TerminalView,
        fontSize: CGFloat,
        backgroundOpacity: CGFloat
    ) {
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
            // Keep the terminal comfortably dark, but allow the host's glass
            // surface to read through the default cells. SwiftTerm keeps
            // selections and explicitly coloured cells opaque, preserving the
            // contrast needed for dense terminal work.
            alpha: max(0.05, min(backgroundOpacity, 0.9))
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
        for task in reflowTasks.values { task.cancel() }
        for task in resizeTasks.values { task.cancel() }
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

        // Every renderer is fed, including ones that are not currently mounted.
        //
        // Skipping the unmounted ones looks like an easy win — a session shown
        // both full-screen and in the grid keeps two emulators alive forever,
        // so this parses every byte twice — but it is the wrong trade. A
        // renderer that misses output has to be rebuilt by replaying the whole
        // transcript before it can be shown, and that replay is O(replay
        // buffer) on the main actor, where feeding is O(bytes that just
        // arrived). Since a grid tile is unmounted and remounted every time it
        // scrolls through a `LazyVGrid`, skipping would trade a small
        // continuous cost for a 2 MB stall on every scroll.
        TerminalPerfLog.measure(
            "TerminalController.feed",
            "\(accessibilityIdentifier) \(bytes.count)B → \(terminalViews.count) renderer(s)"
        ) {
            for view in terminalViews.values {
                view.feed(byteArray: bytes[...])
            }
        }
        invalidateScreenText()
        outputHandler(data)
        scheduleAccessibleContentPublication()
    }

    @MainActor
    private func scheduleAccessibleContentPublication() {
        accessibilityTask?.cancel()
        accessibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            await self?.publishAccessibleContent()
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

@MainActor
    private func publishAccessibleContent() {
        for view in terminalViews.values {
            publishAccessibleContent(for: view)
        }
    }

    /// Skips renderers that aren't mounted (no `window`) and skips the
    /// `setAccessibilityValue` call entirely when the serialized buffer text
    /// hasn't changed since the last publish — both `getBufferAsData` and the
    /// AX write are otherwise paid on every debounce tick per renderer.
    @MainActor
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
        guard !isReplaying else { return }
        guard let presentation = terminalViews.first(where: { $0.value === source })?.key,
              presentation == authoritativePresentation else {
            return
        }
        process.send(input: Data(data))
        Task { @MainActor in inputHandler() }
    }

    public func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        // Only the renderer the user is actually looking at may resize the
        // agent — see `authoritativePresentation`.
        guard let presentation = terminalViews.first(where: { $0.value === source })?.key,
              presentation == authoritativePresentation
        else {
            TerminalPerfLog.event("sizeChanged ignored (not authoritative) \(accessibilityIdentifier) → \(newCols)x\(newRows)")
            return
        }

        // A renderer measured mid-layout, before its frame is real, reports an
        // absurd size — a near-zero frame comes through as 5x11. Forwarding
        // that resizes the agent to five columns, and a TUI does not re-flow
        // what it has already drawn: one transient bad measurement leaves the
        // session permanently mangled, its UI wrapped into a narrow ribbon
        // long after the window is large again. No real window is this small,
        // so there is nothing to lose by waiting for the next measurement.
        guard newCols >= Self.minimumUsableCols, newRows >= Self.minimumUsableRows else {
            TerminalPerfLog.event("sizeChanged ignored (degenerate) \(accessibilityIdentifier) → \(newCols)x\(newRows)")
            return
        }

        // The process starts at a deliberately narrow guessed size (see
        // SessionProcessManager) before any terminal view has laid out. The
        // first real measurement corrects that mismatch immediately, so the
        // agent redraws its startup screen at the true size before it can
        // print much at the wrong one. Later calls, from a live grid reflow,
        // still wait for pane layout to settle so we don't send a stream of
        // transient dimensions mid-drag.
        TerminalPerfLog.event("sizeChanged \(accessibilityIdentifier) → \(newCols)x\(newRows) initial=\(!hasSentInitialResize)")
        // SwiftTerm calls this on the main thread, from inside `setFrameSize`.
        // `applyResize` is `@MainActor` and everything it touches — including
        // the `process` reference that `rebind` replaces — is only ever read
        // there, which is what keeps this off the unsynchronized path a bare
        // `Task` used to take.
        MainActor.assumeIsolated {
            // The emulator has already re-laid out its buffer for the new
            // dimensions by the time it tells us, so the memoized screen text
            // is stale even if no new bytes have arrived.
            invalidateScreenText()
            applyResize(PTYSize(cols: newCols, rows: newRows), for: presentation)
        }
    }

    public func setTerminalTitle(source: TerminalView, title: String) {}

    public func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    public func scrolled(source: TerminalView, position: Double) {}

    public func clipboardCopy(source: TerminalView, content: Data) {
        guard !content.isEmpty else { return }
        let string = String(decoding: content, as: UTF8.self)
        guard !string.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    public func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    public func bell(source: TerminalView) {}

    public func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
