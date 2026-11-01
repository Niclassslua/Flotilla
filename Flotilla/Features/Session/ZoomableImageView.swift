import AppKit
import Observation
import SwiftUI

/// Drives a `ZoomableImageView` from SwiftUI controls and reports its zoom.
@MainActor
@Observable
final class ImageZoomController {
    /// Zoom relative to the image's actual pixels (1 = 100 %).
    fileprivate(set) var zoom: CGFloat = 1
    /// Whether the image is shown fitted to the viewport (and re-fits on resize).
    fileprivate(set) var isFitted = true

    @ObservationIgnored fileprivate weak var scrollView: ZoomScrollView?

    func fit() { scrollView?.fit(animated: true) }
    func actualSize() { scrollView?.setZoom(1, animated: true) }
    func zoomIn() { scrollView.map { $0.setZoom(zoom * 1.25, animated: true) } }
    func zoomOut() { scrollView.map { $0.setZoom(zoom / 1.25, animated: true) } }
}

/// An image in a native `NSScrollView`: pinch and ⌘-scroll zoom at the
/// pointer, scroll or drag to pan, double-click toggles Fit, and — while
/// fitted — a horizontal two-finger swipe pages via `onSwipe`.
///
/// Built on AppKit magnification rather than `scaleEffect`: a scaled SwiftUI
/// view keeps its hit area when zoomed and swallowed clicks on nearby controls.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let controller: ImageZoomController
    /// `-1` for previous, `+1` for next.
    var onSwipe: (Int) -> Void = { _ in }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scrollView = ZoomScrollView(image: image)
        scrollView.controller = controller
        scrollView.onSwipe = onSwipe
        controller.scrollView = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: ZoomScrollView, context: Context) {
        scrollView.onSwipe = onSwipe
        scrollView.controller = controller
        controller.scrollView = scrollView
        scrollView.setImage(image)
    }
}

final class ZoomScrollView: NSScrollView {
    weak var controller: ImageZoomController?
    var onSwipe: (Int) -> Void = { _ in }

    private let imageView = PanningImageView()
    private var isFitted = true
    private var swipeAccumulator: CGFloat = 0
    private var swipeFired = false

    /// Magnification at which one image pixel covers one screen pixel; the
    /// document is sized in image pixels, so this is 1 / backing scale.
    private var actualMagnification: CGFloat {
        1 / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    private var fitMagnification: CGFloat {
        let doc = imageView.frame.size
        let visible = contentSize
        guard doc.width > 0, doc.height > 0, visible.width > 0, visible.height > 0 else { return 1 }
        return min(visible.width / doc.width, visible.height / doc.height)
    }

    init(image: NSImage) {
        super.init(frame: .zero)
        contentView = CenteringClipView()
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        documentView = imageView
        imageView.imageScaling = .scaleAxesIndependently
        imageView.onDoubleClick = { [weak self] point in self?.toggleZoom(at: point) }
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: contentView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveMagnifyEnded), name: NSScrollView.didEndLiveMagnifyNotification, object: self
        )
        setImage(image)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        let rep = image.representations.first
        let pixels = rep.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) } ?? image.size
        imageView.frame = NSRect(origin: .zero, size: pixels.width > 0 ? pixels : image.size)
        fit(animated: false)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLimits()
        if isFitted { fit(animated: false) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateLimits()
        if isFitted { fit(animated: false) }
    }

    func fit(animated: Bool) {
        isFitted = true
        apply(fitMagnification, centeredAt: nil, animated: animated)
    }

    /// `zoom` is relative to actual pixels.
    func setZoom(_ zoom: CGFloat, centeredAt point: NSPoint? = nil, animated: Bool) {
        isFitted = false
        apply(zoom * actualMagnification, centeredAt: point, animated: animated)
    }

    private func toggleZoom(at point: NSPoint) {
        if isFitted {
            // Into actual pixels, or 2.5× the fit when the image is small.
            let target = max(actualMagnification, fitMagnification * 2.5)
            setZoom(target / actualMagnification, centeredAt: point, animated: true)
        } else {
            fit(animated: true)
        }
    }

    private func apply(_ magnification: CGFloat, centeredAt point: NSPoint?, animated: Bool) {
        updateLimits()
        let clamped = min(max(magnification, minMagnification), maxMagnification)
        let center = point ?? NSPoint(x: documentVisibleRect.midX, y: documentVisibleRect.midY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                animator().setMagnification(clamped, centeredAt: center)
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.publish() }
            }
        } else {
            setMagnification(clamped, centeredAt: center)
        }
        publish()
    }

    private func updateLimits() {
        minMagnification = min(fitMagnification, actualMagnification) * 0.5
        maxMagnification = max(actualMagnification, fitMagnification) * 8
    }

    private func publish() {
        controller?.zoom = magnification / actualMagnification
        controller?.isFitted = isFitted
    }

    @objc private func boundsChanged() { publish() }

    @objc private func liveMagnifyEnded() {
        isFitted = abs(magnification - fitMagnification) < 0.001
        publish()
    }

    override func magnify(with event: NSEvent) {
        isFitted = false
        super.magnify(with: event)
    }

    override func smartMagnify(with event: NSEvent) {
        toggleZoom(at: imageView.convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 100 : event.scrollingDeltaY / 10
            let point = imageView.convert(event.locationInWindow, from: nil)
            setZoom(magnification / actualMagnification * (1 + delta), centeredAt: point, animated: false)
            return
        }
        if isFitted, handleSwipe(event) { return }
        super.scrollWheel(with: event)
    }

    /// A horizontal trackpad swipe while fitted pages instead of panning;
    /// fires once per gesture and ignores momentum.
    private func handleSwipe(_ event: NSEvent) -> Bool {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else {
            return !event.momentumPhase.isEmpty && swipeFired
        }
        if event.phase.contains(.began) {
            swipeAccumulator = 0
            swipeFired = false
        }
        guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) || swipeAccumulator != 0 else { return false }
        swipeAccumulator += event.scrollingDeltaX
        if !swipeFired, abs(swipeAccumulator) > 60 {
            swipeFired = true
            // Fingers moving right reveal the previous image, as in Preview.
            onSwipe(swipeAccumulator > 0 ? -1 : 1)
        }
        return true
    }
}

/// Keeps a document smaller than the viewport centered instead of pinned to
/// the bottom-left corner.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView?.frame else { return rect }
        if rect.width > doc.width { rect.origin.x = (doc.width - rect.width) / 2 }
        if rect.height > doc.height { rect.origin.y = (doc.height - rect.height) / 2 }
        return rect
    }
}

/// The document view: drag to pan, double-click to toggle zoom.
private final class PanningImageView: NSImageView {
    var onDoubleClick: (NSPoint) -> Void = { _ in }
    private var dragStart: NSPoint?
    private var originAtDragStart: NSPoint = .zero

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick(convert(event.locationInWindow, from: nil))
            return
        }
        guard let clip = enclosingScrollView?.contentView else { return }
        dragStart = event.locationInWindow
        originAtDragStart = clip.bounds.origin
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        // Window points to document points: divide by the magnification.
        let dx = (event.locationInWindow.x - start.x) / scrollView.magnification
        let dy = (event.locationInWindow.y - start.y) / scrollView.magnification
        let origin = NSPoint(x: originAtDragStart.x - dx, y: originAtDragStart.y - dy)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        if dragStart != nil { NSCursor.pop() }
        dragStart = nil
    }
}
