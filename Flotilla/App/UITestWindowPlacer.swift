#if DEBUG
import AppKit
import SwiftUI

/// Keeps screenshot-producing UI tests on the primary display.
///
/// `XCUIScreenshot` cannot reliably capture windows hosted on a secondary
/// display. This representable is only mounted when `UI_TESTING=1`, so normal
/// app launches retain macOS' standard window placement behavior.
enum UITestWindowPlacement: Equatable {
    case fillPrimaryDisplay
    case topLeading
}

struct UITestWindowPlacer: NSViewRepresentable {
    let placement: UITestWindowPlacement

    func makeNSView(context: Context) -> NSView {
        PlacementView(placement: placement)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let placementView = nsView as? PlacementView else { return }
        placementView.placement = placement
        placementView.placeWindowIfPossible()
    }
}

private final class PlacementView: NSView {
    var placement: UITestWindowPlacement

    init(placement: UITestWindowPlacement) {
        self.placement = placement
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        placeWindowIfPossible()
    }

    func placeWindowIfPossible() {
        guard let window, let primaryScreen = NSScreen.screens.first else { return }

        switch placement {
        case .fillPrimaryDisplay:
            window.setFrame(primaryScreen.visibleFrame, display: true)
        case .topLeading:
            let visibleFrame = primaryScreen.visibleFrame
            let origin = NSPoint(
                x: visibleFrame.minX,
                y: visibleFrame.maxY - window.frame.height
            )
            window.setFrameOrigin(origin)
        }
    }
}
#endif
