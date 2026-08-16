import SwiftUI

public enum FlotillaBannerStyle {
    case error
    case warning
    case info
    case success

    var backgroundColor: (FlotillaColors) -> Color {
        switch self {
        case .error: return { $0.dangerSurface }
        case .warning: return { $0.warningSurface }
        case .info: return { $0.accent.opacity(0.12) }
        case .success: return { $0.successSurface }
        }
    }

    var foregroundColor: (FlotillaColors) -> Color {
        switch self {
        case .error: return { $0.danger }
        case .warning: return { $0.warning }
        case .info: return { $0.accent }
        case .success: return { $0.success }
        }
    }

    var icon: String {
        switch self {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        }
    }

    var accessibilityTrait: AccessibilityTraits {
        switch self {
        case .error: return .updatesFrequently
        case .warning: return .updatesFrequently
        case .info: return []
        case .success: return []
        }
    }
}

public struct FlotillaBanner: View {
    private let message: String
    private let style: FlotillaBannerStyle
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let dismissAction: (() -> Void)?

    @Environment(\.flotillaColors) private var colors

    public init(
        _ message: String,
        style: FlotillaBannerStyle = .info,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        dismissAction: (() -> Void)? = nil
    ) {
        self.message = message
        self.style = style
        self.actionTitle = actionTitle
        self.action = action
        self.dismissAction = dismissAction
    }

    public var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: style.icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(style.foregroundColor(colors))
                .accessibilityHidden(true)

            Text(message)
                .font(FlotillaTypography.callout)
                .foregroundStyle(style.foregroundColor(colors))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(message)

            Spacer(minLength: FlotillaSpacing.medium)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(style.foregroundColor(colors))
                    .padding(.horizontal, FlotillaSpacing.small)
                    .padding(.vertical, FlotillaSpacing.xSmall)
                    .background(style.foregroundColor(colors).opacity(0.15), in: Capsule())
            }

            if let dismissAction {
                Button(action: dismissAction) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.foregroundColor(colors).opacity(0.7))
                        .frame(width: 20, height: 20)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(style.backgroundColor(colors), in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(style.foregroundColor(colors).opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(style.accessibilityTrait)
    }
}

public extension FlotillaBanner {
    static func error(_ message: String, dismiss: @escaping () -> Void) -> FlotillaBanner {
        FlotillaBanner(message, style: .error, dismissAction: dismiss)
    }

    static func warning(_ message: String, dismiss: @escaping () -> Void) -> FlotillaBanner {
        FlotillaBanner(message, style: .warning, dismissAction: dismiss)
    }

    static func info(_ message: String, dismiss: (() -> Void)? = nil) -> FlotillaBanner {
        FlotillaBanner(message, style: .info, dismissAction: dismiss ?? {})
    }

    static func success(_ message: String, dismiss: (() -> Void)? = nil) -> FlotillaBanner {
        FlotillaBanner(message, style: .success, dismissAction: dismiss ?? {})
    }
}