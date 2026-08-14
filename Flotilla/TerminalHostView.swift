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
        XirpTerminalContainerView(
            controller: controller,
            terminalView: controller.terminalView(for: presentation),
            isFocused: isFocused,
            contentInsets: contentInsets
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let container = nsView as? XirpTerminalContainerView else { return }
        container.attach(
            controller: controller,
            terminalView: controller.terminalView(for: presentation),
            isFocused: isFocused,
            contentInsets: contentInsets
        )
    }
}

/// Xirp wraps xterm.js in `p-2`; this native container gives SwiftTerm the
/// same eight-point breathing room without changing its PTY sizing logic.
private final class XirpTerminalContainerView: NSView {
    private weak var controller: TerminalController?
    private weak var mountedTerminalView: NSView?
    private var terminalConstraints: [NSLayoutConstraint] = []
    private var shouldFocusTerminal = false
    private var hasRequestedFocus = false
    private var keyDownMonitor: Any?

    init(
        controller: TerminalController,
        terminalView: NSView,
        isFocused: Bool,
        contentInsets: NSEdgeInsets
    ) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 10 / 255,
            green: 10 / 255,
            blue: 12 / 255,
            alpha: 1
        ).cgColor
        installKeyDownMonitor()
        attach(
            controller: controller,
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
        MainActor.assumeIsolated {
            if let keyDownMonitor {
                NSEvent.removeMonitor(keyDownMonitor)
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestTerminalFocusIfNeeded()
    }

    func attach(
        controller: TerminalController,
        terminalView: NSView,
        isFocused: Bool,
        contentInsets: NSEdgeInsets
    ) {
        self.controller = controller
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
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let window = self.window,
                  event.window === window,
                  let terminalView = self.mountedTerminalView,
                  window.firstResponder === terminalView,
                  [UInt16(36), UInt16(76)].contains(event.keyCode) else {
                return event
            }

            var modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            modifiers.subtract([.capsLock, .numericPad, .function])
            guard modifiers == .shift else { return event }

            self.controller?.sendMultilineNewline()
            return nil
        }
    }
}
