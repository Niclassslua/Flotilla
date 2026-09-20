import SwiftUI
import SessionKit
import DesignSystem

/// A project identity mark used in sidebars: a tinted rounded tile bearing
/// the project's initial (or a symbol for built-in groups like General).
/// The tint is derived deterministically from the project name so a project
/// keeps its color across launches without persisting anything.
struct ProjectMark: View {
    let title: String
    let tint: Color
    var icon: ProjectIcon? = nil
    var systemImage: String? = nil
    /// Defaults to the sidebar size; commit history uses a larger mark in the
    /// detail pane, where the author is the subject rather than a list hint.
    var size: CGFloat = 17

    init(project: Project, size: CGFloat = 17) {
        self.title = project.name
        self.tint = Self.tint(for: project)
        self.icon = project.icon
        self.systemImage = nil
        self.size = size
    }

    init(title: String, tint: Color, icon: ProjectIcon? = nil, systemImage: String? = nil, size: CGFloat = 17) {
        self.title = title
        self.tint = tint
        self.icon = icon
        self.systemImage = systemImage
        self.size = size
    }

    private var cornerRadius: CGFloat { size * 5 / 17 }
    private var glyphSize: CGFloat { size * 9 / 17 }

    var body: some View {
        Group {
            if let icon, case .custom(let data) = icon, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
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
    static let tints: [Color] = [
        FlotillaColors.statusWorking,
        FlotillaColors.statusReady,
        FlotillaColors.accent,
        Color(red: 0.78, green: 0.65, blue: 0.95),
        Color(red: 0.93, green: 0.74, blue: 0.42),
        Color(red: 0.62, green: 0.78, blue: 0.66),
    ]

    static func tint(for project: Project) -> Color {
        if let custom = project.accentColor, !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = custom.hasPrefix("#") ? custom : "#\(custom)"
            return FlotillaAccent.makeColor(for: normalized)
        }
        return tint(forKey: project.name)
    }

    /// Any stable string works as the key — a project name, a commit author's
    /// email — so the same identity always draws the same color.
    ///
    /// Stable polynomial hash: `Hasher` is launch-seeded and would reshuffle
    /// the colors on every start.
    static func tint(forKey key: String) -> Color {
        let hash = key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return tints[Int(hash.magnitude % UInt(tints.count))]
    }
}
