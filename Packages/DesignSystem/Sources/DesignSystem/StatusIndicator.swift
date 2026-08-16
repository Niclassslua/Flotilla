import SwiftUI

/// A small colored dot + accessible label. Color-agnostic so DesignSystem
/// stays standalone — callers map their own domain status into a color.
public struct StatusIndicator: View {
    private let color: Color
    private let label: String
    private let pulses: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    public init(color: Color, label: String, pulses: Bool = false) {
        self.color = color
        self.label = label
        self.pulses = pulses
    }

    private var shouldPulse: Bool { pulses && !reduceMotion }

    public var body: some View {
        ZStack {
            // Drawn at a fixed size and scaled, never resized: animating the
            // ring's frame changes the ZStack's bounds every frame, which
            // nudges the dot around inside whatever lays this out.
            Circle()
                .stroke(color, lineWidth: 1.5)
                .frame(width: 8, height: 8)
                .scaleEffect(isExpanded ? 2.2 : 1)
                .opacity(isExpanded ? 0 : 0.55)
                .opacity(shouldPulse ? 1 : 0)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.45), radius: shouldPulse ? 3 : 0)
        }
        .frame(width: 18, height: 18)
        .animation(pulseAnimation, value: isExpanded)
        .accessibilityLabel(label)
        // Driven by `onChange` as well as `onAppear`: these indicators are
        // reused as a session changes state, so a view that already exists
        // when it starts working would otherwise never begin pulsing (and
        // one that stops working would stay stuck mid-pulse).
        .onAppear { isExpanded = shouldPulse }
        .onChange(of: shouldPulse) { _, pulsing in isExpanded = pulsing }
    }

    /// `nil` on the way back to rest so the repeating animation is dropped
    /// rather than left attached to the next state change.
    private var pulseAnimation: Animation? {
        isExpanded ? .easeOut(duration: 1.1).repeatForever(autoreverses: false) : nil
    }
}
