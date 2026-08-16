import SwiftUI

public struct FlotillaMotion: Sendable {
    public let duration: Double
    public let curve: Animation

    public static let fast = FlotillaMotion(duration: 0.15, curve: .easeOut(duration: 0.15))
    public static let normal = FlotillaMotion(duration: 0.22, curve: .easeInOut(duration: 0.22))
    public static let slow = FlotillaMotion(duration: 0.35, curve: .easeInOut(duration: 0.35))
    public static let snappy = FlotillaMotion(duration: 0.22, curve: .snappy(duration: 0.22))
    public static let spring = FlotillaMotion(duration: 0.4, curve: .spring(response: 0.4, dampingFraction: 0.85))

    public init(duration: Double, curve: Animation) {
        self.duration = duration
        self.curve = curve
    }
}

public extension View {
    func flotillaAnimation(_ motion: FlotillaMotion, value: some Equatable) -> some View {
        animation(motion.curve, value: value)
    }

    func flotillaAnimationIf(_ condition: Bool, _ motion: FlotillaMotion, value: some Equatable) -> some View {
        animation(condition ? motion.curve : nil, value: value)
    }
}

private struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var flotillaReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

public extension View {
    func flotillaReduceMotion(_ value: Bool) -> some View {
        environment(\.flotillaReduceMotion, value)
    }

    func withFlotillaMotion(_ motion: FlotillaMotion, value: some Equatable) -> some View {
        self.modifier(FlotillaMotionModifier(motion: motion, value: value))
    }
}

private struct FlotillaMotionModifier<Value: Equatable>: ViewModifier {
    let motion: FlotillaMotion
    let value: Value
    @Environment(\.flotillaReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : motion.curve, value: value)
    }
}

public extension Animation {
    static func flotillaReduceMotionAware(_ motion: FlotillaMotion, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : motion.curve
    }
}