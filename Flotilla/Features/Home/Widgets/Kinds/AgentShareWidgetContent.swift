import SwiftUI
import Charts
import SessionKit
import GitKit
import DesignSystem

// MARK: - Model

/// One agent's commits over the window, in `AgentKind` order so a color
/// always means the same agent.
struct AgentShareSlice: Identifiable {
    let agent: AgentKind
    let count: Int
    var id: AgentKind { agent }

    var color: Color { AgentBrand.accentColor(for: agent) }

    /// Agents only — your own commits are the baseline the share is
    /// measured against, not a slice of it.
    static func slices(from contributions: [HomeContributor: Int]) -> [AgentShareSlice] {
        AgentKind.allCases.compactMap { agent -> AgentShareSlice? in
            let count = contributions[.agent(agent), default: 0]
            return count > 0 ? AgentShareSlice(agent: agent, count: count) : nil
        }
    }
}

// MARK: - View

/// A donut of which agents wrote the fleet's commits, sized from a bare
/// ring (small) through a ring-plus-legend (medium) to a ring, legend and a
/// per-agent lines table (large).
struct AgentShareWidgetContent: View {
    let size: HomeWidgetSize
    let contributions: [HomeContributor: Int]
    var linesByContributor: [HomeContributor: GitDiffStat] = [:]

    @State private var selectedCount: Int?

    private var slices: [AgentShareSlice] { AgentShareSlice.slices(from: contributions) }
    private var agentTotal: Int { slices.map(\.count).reduce(0, +) }
    private var allCommits: Int { contributions.values.reduce(0, +) }

    private var agentPercent: Int {
        guard allCommits > 0 else { return 0 }
        return Int((Double(agentTotal) / Double(allCommits) * 100).rounded())
    }

    private func percent(_ slice: AgentShareSlice) -> Int {
        guard agentTotal > 0 else { return 0 }
        return Int((Double(slice.count) / Double(agentTotal) * 100).rounded())
    }

    /// The slice under the pointer: angle selection reports a cumulative
    /// count, so walk the slices until it's covered.
    private var selected: AgentShareSlice? {
        guard let selectedCount else { return nil }
        var running = 0
        for slice in slices {
            running += slice.count
            if selectedCount <= running { return slice }
        }
        return nil
    }

    /// Shown in the hole: the hovered agent, else the busiest one.
    private var featured: AgentShareSlice? {
        selected ?? slices.max { $0.count < $1.count }
    }

    var body: some View {
        if slices.isEmpty {
            HomeWidgetAllClearState(message: "No agent commits in this window.")
        } else {
            switch size {
            case .small:
                ring(diameter: 108)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .large:
                VStack(spacing: FlotillaSpacing.medium) {
                    HStack(alignment: .center, spacing: FlotillaSpacing.xxLarge) {
                        ring(diameter: 140)
                        legend
                    }
                    Divider().opacity(0.5)
                    linesTable
                }
            default:
                HStack(alignment: .center, spacing: FlotillaSpacing.xxLarge) {
                    ring(diameter: 140)
                    legend
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func ring(diameter: CGFloat) -> some View {
        Chart(slices) { slice in
            SectorMark(angle: .value("Commits", slice.count), innerRadius: .ratio(0.75), angularInset: 1.5)
                .cornerRadius(4)
                .foregroundStyle(slice.color)
                .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.35)
        }
        .chartAngleSelection(value: $selectedCount)
        .chartBackground { _ in
            if let featured {
                VStack(spacing: 3) {
                    ProviderLogo(agent: featured.agent).frame(width: 22, height: 22)
                    Text("\(percent(featured))%")
                        .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .contentTransition(.numericText())
                    Text(featured.agent.displayName)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                }
                .animation(.snappy, value: featured.id)
            }
        }
        .frame(width: diameter, height: diameter)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium - 2) {
            ForEach(slices) { slice in
                HStack(spacing: FlotillaSpacing.small) {
                    ProviderLogo(agent: slice.agent).frame(width: 18, height: 18)
                    Text(slice.agent.displayName)
                        .font(FlotillaTypography.callout)
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: FlotillaSpacing.small)
                    Text("\(slice.count)")
                        .font(FlotillaTypography.caption.monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                    Text("\(percent(slice))%")
                        .font(FlotillaTypography.callout.weight(.semibold).monospacedDigit())
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .frame(width: 38, alignment: .trailing)
                    Circle().fill(slice.color).frame(width: 7, height: 7)
                }
                .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.45)
                .accessibilityElement(children: .combine)
            }
            Divider().opacity(0.6)
            Text("\(agentTotal) of \(allCommits) commits by agents · \(agentPercent)%")
                .font(FlotillaTypography.caption.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
        }
    }

    /// Large-only: lines changed and commit share per agent, alongside the
    /// commit counts the ring and legend already show.
    private var linesTable: some View {
        VStack(spacing: 4) {
            ForEach(slices) { slice in
                let stat = linesByContributor[.agent(slice.agent)] ?? .zero
                HStack(spacing: FlotillaSpacing.small) {
                    Text(slice.agent.displayName)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .frame(width: 90, alignment: .leading)
                    Text("\(slice.count) commits")
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                    Spacer(minLength: 4)
                    Text("+\(stat.additions.formatted(.number.notation(.compactName)))")
                        .foregroundStyle(FlotillaColors.diffAdded)
                    Text("−\(stat.deletions.formatted(.number.notation(.compactName)))")
                        .foregroundStyle(FlotillaColors.diffRemoved)
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
            }
        }
    }
}
