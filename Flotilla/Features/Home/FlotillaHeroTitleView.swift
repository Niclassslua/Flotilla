import SwiftUI
import AppKit
import DesignSystem
import SessionKit

/// Centered Claude-style hero header for the Flotilla Overview screen.
/// A large, personalized time-of-day greeting carries the whole header now —
/// no app-icon emblem — with rotating capability & inspiration sentences
/// given room to breathe beneath it.
struct FlotillaHeroTitleView: View {
    let stats: HomeFleetStats

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
        VStack(spacing: FlotillaSpacing.small) {
            Text("\(greeting), \(userName)")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .tracking(-0.4)
                .foregroundStyle(FlotillaColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(rotatingSentences[sentenceIndex % rotatingSentences.count])
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .frame(maxWidth: 460)
                .fixedSize(horizontal: false, vertical: true)
                .id("sentence-\(sentenceIndex % rotatingSentences.count)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, FlotillaSpacing.large)
        .padding(.bottom, FlotillaSpacing.small)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4.2))
                withAnimation(.easeInOut(duration: 0.6)) {
                    sentenceIndex += 1
                }
            }
        }
    }
}
