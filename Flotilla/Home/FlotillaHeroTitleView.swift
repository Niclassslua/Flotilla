import SwiftUI
import AppKit
import DesignSystem
import SessionKit

/// Centered Claude-style hero header for the Flotilla Overview screen.
/// Features the real application icon with ambient warm glow, a personalized
/// time-of-day greeting, and rotating capability & inspiration sentences.
struct FlotillaHeroTitleView: View {
    let stats: HomeFleetStats

    @Environment(\.colorScheme) private var colorScheme
    @State private var sentenceIndex: Int = 0

    private var userName: String {
        let fullName = NSFullUserName()
        if !fullName.isEmpty {
            let first = fullName.split(separator: " ").first.map(String.init) ?? fullName
            return first
        }
        return NSUserName().capitalized
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 6..<12:
            return "Good morning"
        case 12..<17:
            return "Good afternoon"
        case 17..<23:
            return "Good evening"
        default:
            return "Working late"
        }
    }

    private let rotatingSentences = [
        "Coordinate concurrent AI agents across your Git worktrees.",
        "Triage active sessions, review diffs, and ship clean code.",
        "Parallelize Claude Code, Codex, and OpenCode workflows.",
        "Your local command center for agentic development."
    ]

    var body: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            appIconEmblem

            Text("\(greeting), \(userName)")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(FlotillaColors.textPrimary)

            Text(rotatingSentences[sentenceIndex % rotatingSentences.count])
                .font(FlotillaTypography.body)
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
                .id("sentence-\(sentenceIndex % rotatingSentences.count)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FlotillaSpacing.small)
        .padding(.bottom, FlotillaSpacing.xSmall)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4.2))
                withAnimation(.easeInOut(duration: 0.6)) {
                    sentenceIndex += 1
                }
            }
        }
    }

    // MARK: - App Icon Emblem with Ambient Glow

    @ViewBuilder
    private var appIconEmblem: some View {
        ZStack {
            // Subtle ambient warm glow behind and below icon (directed downward, no upward bleed)
            Circle()
                .fill(FlotillaColors.accent.opacity(colorScheme == .dark ? 0.22 : 0.10))
                .frame(width: 54, height: 54)
                .blur(radius: 8)
                .offset(y: 4)

            if colorScheme == .dark, let icon = NSApp.applicationIconImage {
                // Real macOS App Icon for Dark Mode (borderless, 68pt)
                Image(nsImage: icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 68, height: 68)
                    .shadow(color: FlotillaColors.accent.opacity(0.18), radius: 5, y: 3)
            } else {
                // Symmetrically matched Light Mode squircle with identical footprint and padding
                RoundedRectangle(cornerRadius: 13.5, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white,
                                Color(white: 0.94)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 58, height: 58)
                    .overlay {
                        Image(systemName: "sailboat.fill")
                            .font(.system(size: 37, weight: .semibold))
                            .offset(y: -1)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(red: 0.89, green: 0.40, blue: 0.23),
                                        Color(red: 1.00, green: 0.55, blue: 0.16)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .shadow(color: Color.black.opacity(0.10), radius: 4, y: 2)
                    .frame(width: 68, height: 68)
            }
        }
    }
}
