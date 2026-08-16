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
    var systemImage: String? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(tint.opacity(0.16))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(tint.opacity(0.38), lineWidth: 0.5)
                }
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .bold))
            } else {
                Text(title.prefix(1).uppercased())
                    .font(.system(size: 9, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }

    /// Hues harmonized with FlotillaPalette — muted enough to sit in a dark
    /// sidebar without turning section headers into a rainbow.
    static let tints: [Color] = [
        FlotillaPalette.signal,
        FlotillaPalette.cyan,
        FlotillaPalette.ocean,
        Color(red: 0.78, green: 0.65, blue: 0.95),
        Color(red: 0.93, green: 0.74, blue: 0.42),
        Color(red: 0.62, green: 0.78, blue: 0.66),
    ]

    static func tint(for project: Project) -> Color {
        // Stable polynomial hash — Hasher is launch-seeded and would reshuffle
        // project colors on every start.
        let hash = project.name.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        return tints[Int(hash.magnitude % UInt(tints.count))]
    }
}
