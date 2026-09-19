import SwiftUI
import Charts
import SessionKit
import DesignSystem

// MARK: - Model

/// One agent's commits over the last 30 days. Slices come in `AgentKind`
/// order so a colour always means the same agent.
struct AgentShareSlice: Identifiable {
    let agent: AgentKind
    let count: Int
    var id: AgentKind { agent }

    var color: Color {
        switch agent {
        // Antigravity's anchor azure sits right next to Codex's indigo;
        // its green brand stop keeps the two apart.
        case .antigravity: AgentBrand.antigravityGradientColors[1]
        default: AgentBrand.accentColor(for: agent)
        }
    }

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

/// A donut of which agents wrote your commits, with a logo legend beside
/// it. The pair is centred in whatever height the card is given, so the
/// card ends level with Weekly rhythm beside it.
struct AgentShareView: View {
    let contributions: [HomeContributor: Int]

    @State private var selectedCount: Int?

    private var slices: [AgentShareSlice] { AgentShareSlice.slices(from: contributions) }
    /// Commits by any agent — the ring's whole.
    private var agentTotal: Int { slices.map(\.count).reduce(0, +) }
    /// Every commit in the window, yours included.
    private var allCommits: Int { contributions.values.reduce(0, +) }

    /// How much of all your work agents did.
    private var agentPercent: Int {
        guard allCommits > 0 else { return 0 }
        return Int((Double(agentTotal) / Double(allCommits) * 100).rounded())
    }

    /// An agent's share of the agent commits.
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
            Text("No agent commits in the last 30 days.")
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            HStack(alignment: .center, spacing: FlotillaSpacing.xxLarge) {
                ring
                legend
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var ring: some View {
        Chart(slices) { slice in
            SectorMark(
                angle: .value("Commits", slice.count),
                innerRadius: .ratio(0.75),
                angularInset: 1.5
            )
            .cornerRadius(4)
            .foregroundStyle(slice.color)
            .opacity(selected == nil || selected?.id == slice.id ? 1 : 0.35)
        }
        .chartAngleSelection(value: $selectedCount)
        .chartBackground { _ in
            if let featured {
                VStack(spacing: 3) {
                    ProviderLogo(agent: featured.agent)
                        .frame(width: 22, height: 22)
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
        .frame(width: 160, height: 160)
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.medium + 2) {
            ForEach(slices) { slice in
                HStack(spacing: FlotillaSpacing.small) {
                    ProviderLogo(agent: slice.agent)
                        .frame(width: 18, height: 18)
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
}
