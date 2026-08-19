import SwiftUI
import SessionKit
import AgentKit

extension AgentKind {
    var logoImageName: String {
        AgentCatalog.descriptor(for: self).logoAssetName
    }
}

/// The provider's real brand mark (Claude, Codex/OpenAI, OpenCode, Antigravity), rendered
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
