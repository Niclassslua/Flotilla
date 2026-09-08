import SwiftUI

// MARK: - Metrics

// MARK: - Split

/// A two-pane split that opens at an even 50/50, settles back onto it when a
/// drag comes near, and keeps each pane above its minimum.
///
/// This hosts a real `NSSplitView` because neither SwiftUI route works here.
/// `HSplitView` never consults the ideal widths its panes ask for: it parks
/// each at its minimum and hands the surplus to whichever pane is greedy, so
/// the graph opened pinned to its minimum at any window width. And a
/// hand-rolled `DragGesture` divider fights the cursor — on macOS the gesture
/// is cancelled once the pointer leaves the dragged view's frame, which is
/// exactly what a divider does as it follows the drag, so the split
/// oscillated and the sweet spot turned that wobble into a jump.
///
/// AppKit has owned this behaviour all along: `constrainSplitPosition` is the
/// sweet spot, and it is the same hook Xcode's own editor split uses.
struct SnappingSplit<Leading: View, Trailing: View>: NSViewRepresentable {
    let leadingMin: CGFloat
    let trailingMin: CGFloat
    /// How close a drag has to come to the middle before it settles there.
    var snapDistance: CGFloat = 22
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    func makeCoordinator() -> Coordinator {
        Coordinator(leadingMin: leadingMin, trailingMin: trailingMin, snapDistance: snapDistance)
    }

    func makeNSView(context: Context) -> NSSplitView {
        let split = CentredSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.delegate = context.coordinator

        let leadingHost = NSHostingView(rootView: leading())
        let trailingHost = NSHostingView(rootView: trailing())
        for host in [leadingHost as NSView, trailingHost as NSView] {
            // The split view sets pane frames itself; an intrinsic size out of
            // the hosted SwiftUI would fight the divider.
            host.translatesAutoresizingMaskIntoConstraints = true
        }
        leadingHost.sizingOptions = []
        trailingHost.sizingOptions = []
        context.coordinator.leadingHost = leadingHost
        context.coordinator.trailingHost = trailingHost

        split.addArrangedSubview(leadingHost)
        split.addArrangedSubview(trailingHost)
        return split
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        context.coordinator.leadingMin = leadingMin
        context.coordinator.trailingMin = trailingMin
        context.coordinator.snapDistance = snapDistance
        context.coordinator.leadingHost?.rootView = leading()
        context.coordinator.trailingHost?.rootView = trailing()
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
        var leadingMin: CGFloat
        var trailingMin: CGFloat
        var snapDistance: CGFloat
        var leadingHost: NSHostingView<Leading>?
        var trailingHost: NSHostingView<Trailing>?

        init(leadingMin: CGFloat, trailingMin: CGFloat, snapDistance: CGFloat) {
            self.leadingMin = leadingMin
            self.trailingMin = trailingMin
            self.snapDistance = snapDistance
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMinCoordinate proposedMinimumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            max(proposedMinimumPosition, leadingMin)
        }

        func splitView(
            _ splitView: NSSplitView,
            constrainMaxCoordinate proposedMaximumPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            min(proposedMaximumPosition, splitView.bounds.width - splitView.dividerThickness - trailingMin)
        }

        /// The sweet spot: a drag passing within `snapDistance` of the middle
        /// settles exactly on it.
        func splitView(
            _ splitView: NSSplitView,
            constrainSplitPosition proposedPosition: CGFloat,
            ofSubviewAt dividerIndex: Int
        ) -> CGFloat {
            let centre = (splitView.bounds.width - splitView.dividerThickness) / 2
            return abs(proposedPosition - centre) <= snapDistance ? centre : proposedPosition
        }
    }
}

/// Parks the divider in the middle the first time the split view has a real
/// width; after that the position is the user's to move.
private final class CentredSplitView: NSSplitView {
    private var hasCentred = false

    override func layout() {
        super.layout()
        guard !hasCentred, arrangedSubviews.count == 2, bounds.width > 0 else { return }
        hasCentred = true
        setPosition((bounds.width - dividerThickness) / 2, ofDividerAt: 0)
    }
}

