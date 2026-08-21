import SwiftUI
import DesignSystem

/// **Constellation** — a weighted mosaic.
///
/// The deliberately expressive option. Tiles are sized by how substantial the
/// document is and washed in the owning agent's colour, so a catalog reads as a
/// shape before it reads as a list — the big tile in the corner is your
/// 900-line AGENTS.md, and you learn to find it by position.
///
/// This departs from `.impeccable.md`'s "avoid decorative gradients and
/// floating-card dashboards" guidance on purpose, the same way `LaunchpadDesign`
/// does for the home composer: it is here to be judged against three restrained
/// siblings, and if it loses the bake-off it goes. Every colour is still a
/// token or an `AgentBrand` brand mark.
///
/// Strengths: memorable, genuinely fast for a catalog you know well. Weakness:
/// the least information-dense, and the weighting means nothing for rules,
/// which carry no line count.
struct ConstellationDesign: View {
    let items: [KnowledgeItem]
    let actions: KnowledgeActions

    @Namespace private var zoomNamespace

    /// Column count is fixed rather than adaptive so the masonry balance stays
    /// predictable as the window resizes.
    private static let columnCount = 3

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                ForEach(0..<Self.columnCount, id: \.self) { column in
                    LazyVStack(spacing: FlotillaSpacing.medium) {
                        ForEach(items(inColumn: column)) { item in
                            ConstellationTile(
                                item: item,
                                height: height(for: item),
                                namespace: zoomNamespace,
                                actions: actions
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(FlotillaSpacing.large)
        }
        .background {
            FlotillaColors.canvas
        }
    }

    /// Round-robin rather than a true packing algorithm: it keeps columns
    /// balanced enough at these tile counts, stays stable as items are filtered
    /// in and out, and costs nothing to compute.
    private func items(inColumn column: Int) -> [KnowledgeItem] {
        items.enumerated()
            .filter { $0.offset % Self.columnCount == column }
            .map(\.element)
    }

    /// Three sizes, chosen from line count. Rules have no weight and land on
    /// the middle size, which is the right default for a mixed grid.
    private func height(for item: KnowledgeItem) -> CGFloat {
        switch item.weight {
        case 0: return 156
        case ..<120: return 132
        case ..<400: return 176
        default: return 224
        }
    }
}

// MARK: - Tile

private struct ConstellationTile: View {
    let item: KnowledgeItem
    let height: CGFloat
    let namespace: Namespace.ID
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
            VStack(alignment: .leading, spacing: FlotillaSpacing.small) {
                HStack(spacing: FlotillaSpacing.small) {
                    KnowledgeIconTile(item: item, size: 30, isHighlighted: isHovered)
                    Spacer(minLength: 0)
                    KnowledgeScopeChip(item: item, compact: true)
                }

                Spacer(minLength: 0)

                Text(item.title)
                    .font(item.kind == .rules
                          ? .system(size: 14, weight: .bold, design: .monospaced)
                          : .system(size: 15, weight: .bold))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Text(item.subtitle)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(height > 160 ? 3 : 2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !item.tags.isEmpty && height > 160 {
                    HStack(spacing: 4) {
                        ForEach(item.tags.prefix(2), id: \.self) { KnowledgeTagChip(tag: $0) }
                    }
                }

                HStack(spacing: FlotillaSpacing.small) {
                    if let first = item.metrics.first {
                        KnowledgeMetricPill(metric: first)
                    } else if let date = item.lastModified {
                        Text(formatRelativeDate(date))
                            .font(FlotillaTypography.caption3)
                            .foregroundStyle(FlotillaColors.textTertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(FlotillaSpacing.medium)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
            .background(wash)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(
                        tint.opacity(isHovered ? 0.55 : 0.22),
                        lineWidth: isHovered ? FlotillaBorderWidth.medium : FlotillaBorderWidth.thin
                    )
            }
            .flotillaShadow(isHovered ? .level3 : .level1)
            .scaleEffect(isHovered && !reduceMotion ? 1.02 : 1)
            .matchedGeometryEffect(id: item.id, in: namespace)
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

    /// A corner-anchored brand wash over the panel surface. Antigravity's mark
    /// is a gradient rather than a single colour, so it gets the full sweep
    /// compressed into the same corner region — the treatment `LaunchpadDesign`
    /// established.
    @ViewBuilder
    private var wash: some View {
        ZStack {
            FlotillaColors.surfaceElevated

            if item.framework == .gemini {
                LinearGradient(
                    colors: AgentBrand.antigravityGradientColors,
                    startPoint: .topLeading,
                    endPoint: UnitPoint(x: 0.55, y: 0.45)
                )
                .opacity(isHovered ? 0.28 : 0.18)
                .mask {
                    LinearGradient(
                        colors: [.black, .black.opacity(0.4), .clear],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                }
            } else {
                LinearGradient(
                    colors: [
                        tint.opacity(isHovered ? 0.22 : 0.14),
                        tint.opacity(0.04),
                        .clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .center
                )
            }
        }
    }
}
