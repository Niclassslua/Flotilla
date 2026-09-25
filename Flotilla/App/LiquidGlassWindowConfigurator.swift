import AppKit
import SwiftUI

/// Keeps the AppKit window in the same compositing mode as the workspace
/// appearance preference. Without this, translucent SwiftUI and SwiftTerm
/// surfaces would only blend against an opaque window backing store.
struct LiquidGlassWindowConfigurator: NSViewRepresentable {
    let isEnabled: Bool

    func makeNSView(context: Context) -> NSView {
        LiquidGlassConfigurationView(isEnabled: isEnabled)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? LiquidGlassConfigurationView)?.isEnabled = isEnabled
    }
}

@MainActor
private final class LiquidGlassConfigurationView: NSView {
    var isEnabled: Bool {
        didSet { configureWindow() }
    }

    init(isEnabled: Bool) {
        self.isEnabled = isEnabled
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindow()
    }

    private func configureWindow() {
        guard let window else { return }
        window.isOpaque = !isEnabled
        window.backgroundColor = isEnabled ? .clear : NSColor(
            srgbRed: 10 / 255,
            green: 10 / 255,
            blue: 12 / 255,
            alpha: 1
        )
    }
}
