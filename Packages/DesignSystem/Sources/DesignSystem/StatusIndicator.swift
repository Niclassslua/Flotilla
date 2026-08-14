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

    public var body: some View {
        ZStack {
            if pulses && !reduceMotion {
                Circle()
                    .stroke(color.opacity(isExpanded ? 0 : 0.55), lineWidth: 1.5)
                    .frame(width: isExpanded ? 18 : 8, height: isExpanded ? 18 : 8)
            }
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(0.45), radius: pulses ? 3 : 0)
        }
            .frame(width: 18, height: 18)
            .accessibilityLabel(label)
            .onAppear {
                guard pulses, !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.35).repeatForever(autoreverses: false)) {
                    isExpanded = true
                }
            }
    }
}
