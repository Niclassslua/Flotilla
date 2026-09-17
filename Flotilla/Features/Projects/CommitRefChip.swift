import SwiftUI
import SessionKit
import GitKit
import DesignSystem

// MARK: - Ref Chip

/// Capsule chip for a ref decoration — branch, remote, or tag.
struct CommitRefChip: View {
    let text: String
    let systemImage: String
    let tint: Color
    let maxTextWidth: CGFloat?

    init(text: String, systemImage: String, tint: Color, maxTextWidth: CGFloat? = nil) {
        self.text = BranchNaming.displayName(for: text)
        self.systemImage = systemImage
        self.tint = tint
        self.maxTextWidth = maxTextWidth
    }

    init(ref: GitCommitRef, maxTextWidth: CGFloat? = nil) {
        self.text = ref.name
        self.maxTextWidth = maxTextWidth
        switch ref.kind {
        case .head:
            self.systemImage = "location.fill"
            self.tint = FlotillaColors.accent
        case .localBranch:
            self.systemImage = "arrow.triangle.branch"
            self.tint = FlotillaColors.accent
        case .remoteBranch:
            self.systemImage = "cloud"
            self.tint = FlotillaColors.textTertiary
        case .tag:
            self.systemImage = "tag"
            self.tint = FlotillaColors.statusReady
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if systemImage == "arrow.triangle.branch" {
                GitBranchIcon(size: 8)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 8, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: maxTextWidth)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(tint.opacity(0.14), in: Capsule())
        .foregroundStyle(tint)
        .fixedSize(horizontal: maxTextWidth == nil, vertical: true)
    }
}
