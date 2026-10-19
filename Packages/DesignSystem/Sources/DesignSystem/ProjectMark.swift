import SwiftUI
import SessionKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// A project identity mark: a tinted rounded tile bearing the project's
/// custom icon, emoji, symbol, or initial. The tint comes from a persisted
/// accent when set, otherwise a deterministic hash of the project name.
public struct ProjectMark: View {
    public let title: String
    public let tint: Color
    public var icon: ProjectIcon? = nil
    public var systemImage: String? = nil
    /// Defaults to the sidebar size; commit history uses a larger mark in the
    /// detail pane, where the author is the subject rather than a list hint.
    public var size: CGFloat = 17

    public init(project: Project, size: CGFloat = 17) {
        self.title = project.name
        self.tint = Self.tint(for: project)
        self.icon = project.icon
        self.systemImage = nil
        self.size = size
    }

    public init(
        title: String,
        tint: Color,
        icon: ProjectIcon? = nil,
        systemImage: String? = nil,
        size: CGFloat = 17
    ) {
        self.title = title
        self.tint = tint
        self.icon = icon
        self.systemImage = systemImage
        self.size = size
    }

    /// Convenience for companion `ProjectSummary` and other wire shapes that
    /// carry name / icon / accent without a filesystem path.
    public init(
        title: String,
        icon: ProjectIcon? = nil,
        accentColor: String? = nil,
        systemImage: String? = nil,
        size: CGFloat = 17
    ) {
        self.title = title
        self.tint = Self.tint(accentColor: accentColor, name: title)
        self.icon = icon
        self.systemImage = systemImage
        self.size = size
    }

    private var cornerRadius: CGFloat { size * 5 / 17 }
    private var glyphSize: CGFloat { size * 9 / 17 }

    public var body: some View {
        Group {
            if let icon, case .custom(let data) = icon, let platformImage = Self.platformImage(from: data) {
                platformImage
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(FlotillaColors.separatorStrong.opacity(0.5), lineWidth: 0.5)
                    }
            } else if let icon, case .symbol(let name) = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(tint.opacity(0.38), lineWidth: 0.5)
                        }
                    Image(systemName: name)
                        .font(.system(size: glyphSize, weight: .bold))
                }
                .foregroundStyle(tint)
                .frame(width: size, height: size)
            } else if let icon, case .emoji(let emoji) = icon {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(tint.opacity(0.38), lineWidth: 0.5)
                        }
                    Text(emoji)
                        .font(.system(size: glyphSize * 1.15))
                }
                .frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .overlay {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(tint.opacity(0.38), lineWidth: 0.5)
                        }
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: glyphSize, weight: .bold))
                    } else {
                        Text(title.prefix(1).uppercased())
                            .font(.system(size: glyphSize, weight: .bold, design: .rounded))
                    }
                }
                .foregroundStyle(tint)
                .frame(width: size, height: size)
            }
        }
        .accessibilityHidden(true)
    }

    /// Hues harmonized with FlotillaPalette — muted enough to sit in a dark
    /// sidebar without turning section headers into a rainbow.
    public static let tints: [Color] = [
        FlotillaColors.statusWorking,
        FlotillaColors.statusReady,
        FlotillaColors.accent,
        Color(red: 0.78, green: 0.65, blue: 0.95),
        Color(red: 0.93, green: 0.74, blue: 0.42),
        Color(red: 0.62, green: 0.78, blue: 0.66),
    ]

    public static func tint(for project: Project) -> Color {
        tint(accentColor: project.accentColor, name: project.name)
    }

    public static func tint(accentColor: String?, name: String) -> Color {
        if let custom = accentColor, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = custom.hasPrefix("#") ? custom : "#\(custom)"
            return FlotillaAccent.makeColor(for: normalized)
        }
        return tint(forKey: name)
    }

    /// Any stable string works as the key — a project name, a commit author's
    /// email — so the same identity always draws the same color.
    ///
    /// Stable polynomial hash: `Hasher` is launch-seeded and would reshuffle
    /// the colors on every start.
    public static func tint(forKey key: String) -> Color {
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return tints[Int(hash.magnitude % UInt(tints.count))]
    }

    private static func platformImage(from data: Data) -> Image? {
        #if os(iOS)
        guard let uiImage = UIImage(data: data) else { return nil }
        return Image(uiImage: uiImage)
        #elseif os(macOS)
        guard let nsImage = NSImage(data: data) else { return nil }
        return Image(nsImage: nsImage)
        #else
        return nil
        #endif
    }
}
