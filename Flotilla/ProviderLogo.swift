import SwiftUI
import SessionKit

extension AgentKind {
    var logoImageName: String {
        switch self {
        case .claudeCode: "ProviderLogoClaude"
        case .codexCLI: "ProviderLogoCodex"
        case .geminiCLI: "ProviderLogoGemini"
        }
    }
}

/// The provider's real brand mark (Claude, Codex/OpenAI, Gemini), rendered
/// from vector assets in Assets.xcassets rather than a generic SF Symbol.
struct ProviderLogo: View {
    let agent: AgentKind

    var body: some View {
        Image(agent.logoImageName)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .accessibilityHidden(true)
    }
}
