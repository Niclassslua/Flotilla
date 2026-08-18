import SwiftUI
import AppKit

/// Command-scroll to zoom, the way Finder and Preview do it.
///
/// SwiftUI has no scroll-wheel gesture on macOS, and an overlay view that
/// caught the wheel would also swallow the terminals' own scrolling. A local
/// event monitor is the same approach `TerminalHostView` already uses for its
/// Shift-Return handling: it sees the event first, consumes it only when
/// Command is held, and otherwise hands it straight back.
struct CommandScrollZoom: ViewModifier {
    let isEnabled: Bool
    let onZoom: (CGFloat) -> Void

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear { install() }
            .onDisappear { remove() }
            .onChange(of: isEnabled) { _, enabled in
                enabled ? install() : remove()
            }
    }

    private func install() {
        guard isEnabled, monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard event.modifierFlags.contains(.command) else { return event }
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY / 100
                : event.scrollingDeltaY / 10
            guard delta != 0 else { return event }
            onZoom(1 + delta)
            return nil
        }
    }

    private func remove() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }
}

extension View {
    /// Command-scroll and pinch both drive the same zoom callback, which takes
    /// a multiplier on the current tile width.
    func gridZoomGestures(isEnabled: Bool, onZoom: @escaping (CGFloat) -> Void) -> some View {
        modifier(CommandScrollZoom(isEnabled: isEnabled, onZoom: onZoom))
            .gesture(
                MagnifyGesture()
                    .onEnded { value in onZoom(value.magnification) }
            )
    }
}
