import AppKit
import SwiftTerm

/// `TerminalView` subclass hosting Flotilla-specific redraw behavior that
/// doesn't belong in `TerminalController`.
final class FlotillaTerminalView: TerminalView {
    private var lastCursorStyle: CursorStyle?
    var onEffectiveAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    // `CursorStyle` (SwiftTerm/TerminalOptions.swift) deliberately gains no
    // Equatable conformance from the library, so compare via this ordinal
    // mapping rather than `!=`.
    private static func ordinal(_ style: CursorStyle) -> Int {
        switch style {
        case .blinkBlock: 0
        case .steadyBlock: 1
        case .blinkUnderline: 2
        case .steadyUnderline: 3
        case .blinkBar: 4
        case .steadyBar: 5
        }
    }

    /// SwiftTerm's `CaretView.style` setter unconditionally tears down and
    /// re-adds the blink `CABasicAnimation`, even when the new style equals
    /// the old one (`MacCaretView.updateCursorStyle` -> `updateAnimation`).
    /// An agent that re-emits DECSCUSR every frame — some do, to keep the
    /// cursor shape correct after a full repaint — would otherwise restart
    /// the blink animation continuously, which reads as flicker even though
    /// the style never actually changed. Flotilla always configures
    /// `.steadyBlock`, so this is defensive rather than load-bearing.
    override func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {
        if let lastCursorStyle, Self.ordinal(lastCursorStyle) == Self.ordinal(newStyle) {
            return
        }
        lastCursorStyle = newStyle
        super.cursorStyleChanged(source: source, newStyle: newStyle)
    }
}

extension NSAppearance {
    var isFlotillaLight: Bool { bestMatch(from: [.aqua, .darkAqua]) == .aqua }
}

public extension NSColor {
    static let flotillaTerminalDark = NSColor(srgbRed: 10 / 255, green: 10 / 255, blue: 12 / 255, alpha: 1)
    static let flotillaTerminalLight = NSColor(srgbRed: 0xFA / 255, green: 0xFA / 255, blue: 0xFC / 255, alpha: 1)
    /// Opaque window backdrop behind terminals; resolves per appearance.
    static let flotillaTerminalBackground = NSColor(name: nil) {
        $0.isFlotillaLight ? .flotillaTerminalLight : .flotillaTerminalDark
    }
}
