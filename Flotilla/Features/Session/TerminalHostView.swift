import SwiftUI
import AppKit
import TerminalKit

/// Bridges a cached `TerminalController` renderer into SwiftUI. The same
/// NSView is returned for a given controller and presentation, while full and
/// grid presentations remain independent so each can fit its own container.
struct TerminalHostView: NSViewRepresentable {
    let controller: TerminalController
    var presentation: TerminalPresentation = .session
    var isFocused = true
    var contentInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

    func makeNSView(context: Context) -> NSView {
        let view = XirpTerminalContainerView(
            controller: controller,
            presentation: presentation,
            terminalView: controller.terminalView(for: presentation),
            isFocused: isFocused,
            contentInsets: contentInsets
        )
        // Only the intent is recorded here. The renderer has no window and a
        // zero frame until SwiftUI inserts this container into the hierarchy,
        // so there is nothing to measure yet — the container pushes the real
        // size from `viewDidMoveToWindow`/`layout` instead. Doing it here was
        // the bug: the sync's `window != nil` guard could never pass, so the
        // PTY kept whatever size the previously authoritative presentation
        // left behind.
        controller.makeAuthoritative(presentation)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? XirpTerminalContainerView else { return }
        let terminalView = controller.terminalView(for: presentation)
        let isRemount = container.mountedTerminalView !== terminalView
        container.attach(
            controller: controller,
            presentation: presentation,
            terminalView: terminalView,
            isFocused: isFocused,
            contentInsets: contentInsets
        )
        if isRemount {
            controller.makeAuthoritative(presentation)
            container.syncTerminalSizeIfReady()
        }
    }
}

/// Xirp wraps xterm.js in `p-2`; this native container gives SwiftTerm the
/// same eight-point breathing room without changing its PTY sizing logic.
private final class XirpTerminalContainerView: NSView {
    private weak var controller: TerminalController?
    private var presentation: TerminalPresentation
    private(set) weak var mountedTerminalView: NSView?
    private var terminalConstraints: [NSLayoutConstraint] = []
    private var shouldFocusTerminal = false
    private var hasRequestedFocus = false
    private let keyDownMonitor = EventMonitorBox()

    init(
        controller: TerminalController,
        presentation: TerminalPresentation,
        terminalView: NSView,
        isFocused: Bool,
        contentInsets: NSEdgeInsets
    ) {
        self.presentation = presentation
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 10 / 255,
            green: 10 / 255,
            blue: 12 / 255,
            alpha: 1
        ).cgColor
        attach(
            controller: controller,
            presentation: presentation,
            terminalView: terminalView,
            isFocused: isFocused,
            contentInsets: contentInsets
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        // Safety net only: the monitor is normally removed the moment this
        // view leaves its window. `deinit` is nonisolated and runs wherever
        // the last reference happens to be released, so it must not assume the
        // main thread — `MainActor.assumeIsolated` would trap rather than fall
        // back. `EventMonitorBox` does the hop.
        keyDownMonitor.removeFromAnyThread()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The monitor's lifetime follows window membership rather than this
        // object's. Every mounted terminal installs one and every keystroke in
        // the app runs all of them, so a container that has been scrolled out
        // of a `LazyVGrid` — but not yet deallocated — must not keep costing
        // anything.
        if window == nil {
            keyDownMonitor.remove()
        } else {
            installKeyDownMonitor()
        }
        requestTerminalFocusIfNeeded()
        syncTerminalSizeIfReady()
    }

    override func layout() {
        super.layout()
        // The layout pass that gives the renderer its real frame is the
        // earliest point a size is worth reading, and it can land after
        // `viewDidMoveToWindow`. `syncPTYSize` is a no-op when the PTY already
        // has these dimensions, so calling it on every pass costs a comparison.
        syncTerminalSizeIfReady()
    }

    /// Tells the controller to push this renderer's measured size to the PTY.
    ///
    /// SwiftTerm only reports a size change when its own column/row count
    /// moves, so a renderer restored to dimensions it already had stays silent
    /// — and the agent keeps whatever size the other presentation last set it
    /// to. This is the call that closes that gap.
    func syncTerminalSizeIfReady() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        controller?.syncPTYSize(for: presentation)
    }

    func attach(
        controller: TerminalController,
        presentation: TerminalPresentation,
        terminalView: NSView,
        isFocused: Bool,
        contentInsets: NSEdgeInsets
    ) {
        self.controller = controller
        self.presentation = presentation
        let rendererChanged = mountedTerminalView !== terminalView || terminalView.superview !== self
        setTerminalFocused(isFocused, rendererChanged: rendererChanged)
        guard rendererChanged else {
            requestTerminalFocusIfNeeded()
            return
        }

        NSLayoutConstraint.deactivate(terminalConstraints)
        terminalConstraints.removeAll()
        terminalView.removeFromSuperview()
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        mountedTerminalView = terminalView

        terminalConstraints = [
            terminalView.topAnchor.constraint(equalTo: topAnchor, constant: contentInsets.top),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: contentInsets.left),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -contentInsets.right),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -contentInsets.bottom),
        ]
        NSLayoutConstraint.activate(terminalConstraints)
        requestTerminalFocusIfNeeded()
    }

    private func setTerminalFocused(_ isFocused: Bool, rendererChanged: Bool) {
        if shouldFocusTerminal != isFocused || rendererChanged {
            shouldFocusTerminal = isFocused
            hasRequestedFocus = false
        }
    }

    private func requestTerminalFocusIfNeeded() {
        guard shouldFocusTerminal, !hasRequestedFocus,
              let window, let terminalView = mountedTerminalView else { return }
        hasRequestedFocus = true
        DispatchQueue.main.async { [weak self, weak window, weak terminalView] in
            guard let self, self.shouldFocusTerminal,
                  let window, let terminalView,
                  terminalView.window === window else { return }
            window.makeFirstResponder(terminalView)
        }
    }

    private func installKeyDownMonitor() {
        guard !keyDownMonitor.isInstalled else { return }
        keyDownMonitor.value = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Cheapest discriminators first. Every mounted terminal installs
            // one of these monitors — in the grid that is one per visible tile
            // — and every keystroke anywhere in the app runs all of them, so
            // the common case has to reject on the event alone before touching
            // any view state.
            guard [UInt16(36), UInt16(76)].contains(event.keyCode) else { return event }

            var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            modifiers.subtract([.capsLock, .numericPad, .function])
            guard modifiers == .shift else { return event }

            guard let self,
                  let window = self.window,
                  event.window === window,
                  let terminalView = self.mountedTerminalView,
                  window.firstResponder === terminalView else {
                return event
            }

            self.controller?.sendMultilineNewline()
            return nil
        }
    }
}


/// Holds an `NSEvent` monitor token.
///
/// The token is an opaque `Any`, which is not `Sendable`, so a nonisolated
/// `deinit` cannot touch it directly. Boxing it lets the box — which *is*
/// safe to hand across threads, since the value is only ever created and
/// consumed on the main thread — carry the hop.
private final class EventMonitorBox: @unchecked Sendable {
    var value: Any?

    var isInstalled: Bool { value != nil }

    @MainActor
    func remove() {
        guard let value else { return }
        self.value = nil
        NSEvent.removeMonitor(value)
    }

    /// Callable from `deinit`, on whichever thread released the owner.
    func removeFromAnyThread() {
        guard value != nil else { return }
        if Thread.isMainThread {
            MainActor.assumeIsolated { remove() }
        } else {
            DispatchQueue.main.async { self.remove() }
        }
    }
}
