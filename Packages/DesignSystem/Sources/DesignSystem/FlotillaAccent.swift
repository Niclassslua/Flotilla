import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import os
import Observation

public enum FlotillaAccent: Sendable {
    public static let defaultID = "orange"
    public static let customStorageKey = "settings.appearance.custom-accent"
    public static let companionStorageKey = "companion.accent-color"
    /// Whether the companion follows the paired Mac's accent (default on).
    public static let companionFollowsMacStorageKey = "companion.accent-follows-mac"

    public struct Option: Identifiable, Sendable, Equatable {
        public let id: String
        public let name: String
        public let color: Color

        public init(id: String, name: String, color: Color) {
            self.id = id
            self.name = name
            self.color = color
        }

        public static func == (lhs: Option, rhs: Option) -> Bool {
            lhs.id == rhs.id
        }
    }

    public static let options: [Option] = [
        Option(id: "blue", name: "Blue", color: .blue),
        Option(id: "purple", name: "Purple", color: .purple),
        Option(id: "pink", name: "Pink", color: .pink),
        Option(id: "red", name: "Red", color: .red),
        Option(id: "orange", name: "Orange", color: .orange),
        Option(id: "green", name: "Green", color: .green),
    ]

    public static let spectrum = AngularGradient(
        colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
        center: .center
    )

    private static let defaultOrangeColor: Color = {
        #if os(macOS)
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? PlatformColor(red: 0.96, green: 0.36, blue: 0.16, alpha: 1)
                : PlatformColor(red: 0.85, green: 0.3, blue: 0.12, alpha: 1)
        })
        #else
        Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? PlatformColor(red: 0.96, green: 0.36, blue: 0.16, alpha: 1)
                : PlatformColor(red: 0.85, green: 0.3, blue: 0.12, alpha: 1)
        })
        #endif
    }()

    private struct AccentState: Sendable {
        var id: String
        var color: Color
    }

    private static let lock = OSAllocatedUnfairLock(
        initialState: AccentState(id: defaultID, color: makeColor(for: defaultID))
    )

    /// Observation hook for the lock-protected state. Views that read
    /// `currentID`/`currentColor` (and so `FlotillaColors.accent`) in `body`
    /// are invalidated when the accent changes — without it, windows kept
    /// their old accent until something else re-rendered them.
    private final class AccentObservation: Observable, Sendable {
        static let shared = AccentObservation()
        private let registrar = ObservationRegistrar()
        var accent: Void { () }

        func access() {
            registrar.access(self, keyPath: \.accent)
        }

        func mutate(_ body: () -> Void) {
            registrar.withMutation(of: self, keyPath: \.accent, body)
        }
    }

    public static var currentID: String {
        get {
            AccentObservation.shared.access()
            return lock.withLock { $0.id }
        }
        set {
            guard lock.withLock({ $0.id }) != newValue else { return }
            let color = makeColor(for: newValue)
            AccentObservation.shared.mutate {
                lock.withLock { $0 = AccentState(id: newValue, color: color) }
            }
        }
    }

    public static var currentColor: Color {
        AccentObservation.shared.access()
        return lock.withLock { $0.color }
    }

    public static func platformColor(for value: String, isDark: Bool = true) -> PlatformColor {
        if value.hasPrefix("#"), let hex = PlatformColor(hexString: value) {
            return hex
        }
        switch value {
        case "blue":
            return .systemBlue
        case "purple":
            return .systemPurple
        case "pink":
            return .systemPink
        case "red":
            return .systemRed
        case "orange":
            #if os(macOS)
            return isDark
                ? PlatformColor(red: 0.96, green: 0.36, blue: 0.16, alpha: 1)
                : PlatformColor(red: 0.85, green: 0.3, blue: 0.12, alpha: 1)
            #else
            return .systemOrange
            #endif
        case "green":
            return .systemGreen
        default:
            #if os(macOS)
            return .controlAccentColor
            #else
            return .tintColor
            #endif
        }
    }

    public static func makeColor(for value: String) -> Color {
        if value.hasPrefix("#"), let hex = PlatformColor(hexString: value) {
            #if os(macOS)
            return Color(nsColor: hex)
            #else
            return Color(uiColor: hex)
            #endif
        }
        switch value {
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        case "red": return .red
        case "orange": return defaultOrangeColor
        case "green": return .green
        default:
            #if os(macOS)
            return Color(nsColor: .controlAccentColor)
            #else
            return Color.accentColor
            #endif
        }
    }

    public static func color(for value: String) -> Color {
        makeColor(for: value)
    }

    public static func storageValue(for color: Color) -> String? {
        #if os(macOS)
        guard let converted = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((converted.redComponent * 255).rounded()),
            Int((converted.greenComponent * 255).rounded()),
            Int((converted.blueComponent * 255).rounded())
        )
        #else
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        return String(
            format: "#%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
        #endif
    }
}

public extension PlatformColor {
    convenience init?(hexString: String) {
        let value = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard value.count == 6, let rgb = UInt32(value, radix: 16) else { return nil }
        #if os(macOS)
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
        #else
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
        #endif
    }
}

public struct AccentSwatch<Swatch: View>: View {
    public let name: LocalizedStringKey
    public let isSelected: Bool
    public let action: () -> Void
    @ViewBuilder public let swatch: Swatch

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    public init(
        name: LocalizedStringKey,
        isSelected: Bool,
        action: @escaping () -> Void,
        @ViewBuilder swatch: () -> Swatch
    ) {
        self.name = name
        self.isSelected = isSelected
        self.action = action
        self.swatch = swatch()
    }

    public var body: some View {
        Button(action: action) {
            swatch
                .frame(width: 20, height: 20)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .scaleEffect(isHovering && !reduceMotion ? 1.1 : 1)
                .padding(4)
                .overlay {
                    Circle().strokeBorder(ringColor, lineWidth: isSelected ? 2 : 1)
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.15), value: isSelected)
        .animation(.snappy(duration: 0.15), value: isHovering)
        .help(name)
        .accessibilityLabel(name)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var ringColor: Color {
        if isSelected { return .primary.opacity(0.65) }
        return isHovering ? .primary.opacity(0.25) : .clear
    }
}

public struct AccentColorPicker: View {
    @Binding public var accentColor: String
    private let customStorageKey: String
    @AppStorage private var lastCustomAccent: String

    public init(
        accentColor: Binding<String>,
        customStorageKey: String = "settings.appearance.custom-accent"
    ) {
        self._accentColor = accentColor
        self.customStorageKey = customStorageKey
        self._lastCustomAccent = AppStorage(wrappedValue: "", customStorageKey)
    }

    private var value: String { accentColor }
    private var isCustom: Bool { value.hasPrefix("#") }
    private var selectedOption: FlotillaAccent.Option? { FlotillaAccent.options.first { $0.id == value } }
    private var isSystem: Bool { !isCustom && selectedOption == nil && (value == "system" || value.isEmpty) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AccentSwatch(name: "System Accent", isSelected: isSystem) {
                    applyValue("system")
                } swatch: {
                    #if os(macOS)
                    Circle().fill(Color(nsColor: .controlAccentColor).gradient)
                    #else
                    Circle().fill(Color.accentColor.gradient)
                    #endif
                }
                .accessibilityIdentifier("settings.appearance.accent.system")

                Divider().frame(height: 20)

                ForEach(FlotillaAccent.options) { option in
                    AccentSwatch(name: LocalizedStringKey(option.name), isSelected: option.id == value) {
                        applyValue(option.id)
                    } swatch: {
                        Circle().fill(option.color.gradient)
                    }
                    .accessibilityIdentifier("settings.appearance.accent.\(option.id)")
                }

                Divider().frame(height: 20)

                #if os(macOS)
                AccentSwatch(name: "Custom", isSelected: isCustom, action: chooseCustom) {
                    Circle()
                        .fill(FlotillaAccent.spectrum)
                        .overlay {
                            if let custom = customSwatchColor {
                                Circle().fill(custom).padding(4)
                            }
                        }
                }
                .accessibilityIdentifier("settings.appearance.accent.custom")
                #else
                AccentSwatch(name: "Custom", isSelected: isCustom, action: {}) {
                    Circle()
                        .fill(FlotillaAccent.spectrum)
                        .overlay {
                            if let custom = customSwatchColor {
                                Circle().fill(custom).padding(4)
                            }
                        }
                }
                .overlay {
                    ColorPicker("", selection: Binding(
                        get: { customSwatchColor ?? FlotillaAccent.color(for: value) },
                        set: { applyColor($0) }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .opacity(0.015)
                }
                .accessibilityIdentifier("settings.appearance.accent.custom")
                #endif
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Accent Color")
            .accessibilityIdentifier("settings.appearance.accents")

            summary
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        #if os(macOS)
        .onDisappear {
            #if os(macOS)
            AccentColorPanel.shared.detach()
            #endif
        }
        #endif
    }

    private var summary: Text {
        if let selectedOption { return Text(selectedOption.name) }
        if isCustom { return Text("Custom") + Text(verbatim: " (\(value))") }
        if isSystem { return Text("System Accent") }
        return Text("Orange")
    }

    private var customSwatchColor: Color? {
        if isCustom { return FlotillaAccent.color(for: value) }
        return lastCustomAccent.isEmpty ? nil : FlotillaAccent.color(for: lastCustomAccent)
    }

    private func applyValue(_ newValue: String) {
        accentColor = newValue
        FlotillaAccent.currentID = newValue
    }

    private func applyColor(_ color: Color) {
        guard let hex = FlotillaAccent.storageValue(for: color) else { return }
        lastCustomAccent = hex
        accentColor = hex
        FlotillaAccent.currentID = hex
    }

    #if os(macOS)
    private func chooseCustom() {
        let initial = customSwatchColor ?? FlotillaAccent.color(for: value)
        applyColor(initial)
        AccentColorPanel.shared.present(initial: initial) { newColor in
            applyColor(newColor)
        }
    }
    #endif
}

#if os(macOS)
@MainActor
public final class AccentColorPanel: NSObject {
    public static let shared = AccentColorPanel()

    private var onChange: ((Color) -> Void)?

    public func present(initial: Color, onChange: @escaping (Color) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.color = NSColor(initial)
        panel.setTarget(self)
        panel.setAction(#selector(colorDidChange))
        panel.makeKeyAndOrderFront(nil)
    }

    public func detach() {
        guard onChange != nil else { return }
        onChange = nil
        let panel = NSColorPanel.shared
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.close()
    }

    @objc private func colorDidChange(_ sender: NSColorPanel) {
        onChange?(Color(nsColor: sender.color))
    }
}
#endif
