import SwiftUI
import DesignSystem

private extension HomeWidgetKind {
    /// One line explaining what the widget shows, for the gallery.
    var subtitle: String {
        switch self {
        case .needsYou: "Sessions waiting on you, oldest first"
        case .reviewQueue: "Sessions ready for review, with their diff size"
        case .looseEnds: "Uncommitted, unpushed and orphaned worktrees"
        case .agentScreenshots: "The newest screenshots your agents sent"
        case .streak: "Consecutive days with a commit"
        case .today: "Commits, lines and sessions started today"
        case .busiestHours: "When your fleet commits most"
        case .hotFiles: "The files changed most recently"
        case .topPermissions: "What agents ask permission for most"
        case .contributions: "A year of commits, one square per day"
        case .weeklyRhythm: "Lines added and removed by day"
        case .agentShare: "Which agents wrote your commits"
        case .codebaseGrowth: "Net lines added over time"
        }
    }
}

/// The **+** gallery: every widget kind, with its description and supported
/// sizes, tap to add. Widgets can be added more than once (Q25), so nothing
/// here is ever disabled or marked "added".
struct HomeWidgetGallerySheet: View {
    let editor: HomeWidgetEditor
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 260), spacing: FlotillaSpacing.medium)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: FlotillaSpacing.medium) {
                    ForEach(HomeWidgetKind.allCases) { kind in
                        Button {
                            editor.add(kind: kind)
                            dismiss()
                        } label: {
                            row(kind)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(FlotillaSpacing.large)
            }
            .navigationTitle("Add Widget")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .frame(width: 640, height: 460)
        .accessibilityIdentifier(AXID.homeWidgetGallery.rawValue)
    }

    private func row(_ kind: HomeWidgetKind) -> some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
            Image(systemName: kind.glyph)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(FlotillaColors.accent)
                .frame(width: 30, height: 30)
                .background(FlotillaColors.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(kind.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(kind.subtitle)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(FlotillaColors.accent)
        }
        .padding(FlotillaSpacing.medium)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FlotillaColors.textPrimary.opacity(0.04), in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.textPrimary.opacity(0.06), lineWidth: 1)
        }
        .accessibilityIdentifier(AXID.homeWidgetGalleryAddButton.rawValue + kind.rawValue)
    }
}
