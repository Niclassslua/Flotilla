import AppKit
import SwiftUI

/// A borderless floating panel, not a modal sheet. Unlike `.sheet`, this can
/// resign key when the user clicks elsewhere and close itself — the
/// click-outside-to-dismiss behavior a Spotlight-style launcher needs.
private final class CommandPalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class CommandPaletteWindowController: NSWindowController, NSWindowDelegate {
    private var onClose: (() -> Void)?
    private var isClosing = false

    init(onClose: @escaping () -> Void) {
        let panel = CommandPalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.setAccessibilityLabel("Command Palette")
        super.init(window: panel)
        self.onClose = onClose
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setContent(_ view: some View) {
        (window as? CommandPalettePanel)?.contentView = NSHostingView(
            rootView: view.clipShape(.rect(cornerRadius: 14))
        )
    }

    func show(relativeTo parentWindow: NSWindow?) {
        guard let panel = window else { return }
        let screen = parentWindow?.screen ?? NSScreen.main
        if let screen {
            let size = panel.frame.size
            let x = screen.visibleFrame.midX - size.width / 2
            let y = screen.visibleFrame.midY - size.height / 2
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        // Clicking anywhere outside the panel — including the main window —
        // resigns key status here first. Treat that as "click outside to dismiss".
        close()
    }

    override func close() {
        guard !isClosing else { return }
        isClosing = true
        super.close()
        onClose?()
        isClosing = false
    }
}
