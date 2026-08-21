import SwiftUI
import DesignSystem

/// **Atlas** — an editorial card grid.
///
/// The considered evolution of what these tabs looked like before: same
/// browse-then-open model, but the card is rebuilt around a framework-tinted
/// spine, a real typographic hierarchy, and a footer that carries the facts
/// worth scanning (metrics, freshness) instead of repeating the title.
///
/// Strengths: every item shows its description, so an unfamiliar catalog is
/// legible at a glance. Weakness: at 40+ items it becomes a lot of scrolling.
struct AtlasDesign: View {
    let items: [KnowledgeItem]
    let actions: KnowledgeActions

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: FlotillaSpacing.medium)],
                spacing: FlotillaSpacing.medium
            ) {
                ForEach(items) { item in
                    AtlasCard(item: item, actions: actions)
                }
            }
            .padding(FlotillaSpacing.large)
        }
        .background(FlotillaColors.canvas)
    }
}

private struct AtlasCard: View {
    let item: KnowledgeItem
    let actions: KnowledgeActions

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    private var tint: Color {
        if let framework = item.framework {
            return AgentBrand.accentColor(for: framework)
        }
        return FlotillaColors.accent
    }

    var body: some View {
        Button {
            actions.open(item)
        } label: {
            HStack(spacing: 0) {
                // The tinted spine carries the framework identity, which frees
                // the card body from needing a coloured badge to do it.
                Rectangle()
                    .fill(tint.opacity(isHovered ? 0.9 : 0.55))
                    .frame(width: 3)

                VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                    topRow
                    titleBlock
                    Spacer(minLength: 0)
                    Divider().opacity(0.5)
                    footer
                }
                .padding(FlotillaSpacing.medium)
            }
            .frame(height: 178, alignment: .topLeading)
            .background(FlotillaColors.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                    .strokeBorder(
                        isHovered ? tint.opacity(0.5) : FlotillaColors.separator.opacity(0.6),
                        lineWidth: FlotillaBorderWidth.thin
                    )
            }
            .flotillaShadow(isHovered ? .level2 : .level1)
            .scaleEffect(isHovered && !reduceMotion ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .withFlotillaMotion(.fast, value: isHovered)
        .help(item.subtitle)
        .accessibilityLabel("\(item.title), \(item.scopeLabel)")
        .accessibilityHint(item.subtitle)
        .accessibilityIdentifier(AXID.knowledgeItem.rawValue + item.title)
        .contextMenu {
            Button("Open in Default App") { actions.openExternally(item.url) }
            if let invocation = item.invocation {
                Button("Copy Invocation") { actions.copy(invocation) }
            }
        }
    }

    private var topRow: some View {
        HStack(spacing: FlotillaSpacing.small) {
            KnowledgeIconTile(item: item, size: 32, isHighlighted: isHovered)
            KnowledgeFrameworkChip(item: item)
            if let version = item.version {
                KnowledgeVersionChip(version: version)
            }
            Spacer(minLength: 0)
            KnowledgeScopeChip(item: item, compact: true)
        }
        .frame(height: 32)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title)
                .font(item.kind == .rules
                      ? .system(size: 13.5, weight: .semibold, design: .monospaced)
                      : FlotillaTypography.headline)
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(item.subtitle)
                .font(FlotillaTypography.caption)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footer: some View {
        HStack(spacing: FlotillaSpacing.small) {
            if item.metrics.isEmpty {
                Text(item.parentFolder)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                // Two metrics is all that fits without the row becoming a
                // wall of pills; the rest are on the detail card.
                ForEach(item.metrics.prefix(2)) { KnowledgeMetricPill(metric: $0) }
            }

            Spacer(minLength: 0)

            if let date = item.lastModified {
                Text(formatRelativeDate(date))
                    .font(FlotillaTypography.caption3)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(isHovered ? tint : FlotillaColors.textTertiary)
        }
        .frame(height: 16)
    }
}
