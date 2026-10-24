import AppKit
import DesignSystem
import SwiftUI

extension OnboardingTool {
    var capability: String {
        switch self {
        case .git: "Worktrees"
        case .tmux: "Persistent Sessions"
        case .gh: "Pull Requests & CI"
        }
    }

    var capabilityDetail: String {
        switch self {
        case .git: "Gives every agent its own checkout of your repo."
        case .tmux: "Agents keep running when you quit or update Flotilla."
        case .gh: "Shows CI checks and sends failures back to the agent."
        }
    }

    /// What the user goes without while the tool is missing, mid-sentence.
    var missingConsequence: String {
        switch self {
        case .git: "worktrees"
        case .tmux: "sessions that survive quitting"
        case .gh: "pull requests and CI checks"
        }
    }

    var symbol: String {
        switch self {
        case .git: "arrow.triangle.branch"
        case .tmux: "terminal.fill"
        case .gh: "checkmark.seal.fill"
        }
    }

    var color: Color {
        switch self {
        case .git: .orange
        case .tmux: .green
        case .gh: .purple
        }
    }
}

/// The command-line tools that power Flotilla, as three equal columns — what
/// each one gives you, and whether it's installed.
struct EngineRoomDiagram: View {
    let draft: OnboardingDraft

    var body: some View {
        HStack(alignment: .top, spacing: FlotillaSpacing.large) {
            ForEach(OnboardingTool.allCases) { tool in
                ToolColumn(tool: tool, isInstalled: !draft.missingTools.contains(tool))
            }
        }
        .frame(maxHeight: .infinity, alignment: .center)
    }
}

private struct ToolColumn: View {
    let tool: OnboardingTool
    let isInstalled: Bool

    @State private var copied = false

    var body: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            Image(systemName: tool.symbol)
                .font(.system(size: 30, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isInstalled ? tool.color : FlotillaColors.textTertiary)
                .frame(width: 72, height: 72)
                .background((isInstalled ? tool.color : FlotillaColors.textTertiary).opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text(tool.capability)
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("Powered by \(tool.rawValue)")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }

            Text(tool.capabilityDetail)
                .font(FlotillaTypography.callout)
                .foregroundStyle(FlotillaColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)

            status
                .frame(height: 56, alignment: .top)
                .padding(.top, FlotillaSpacing.xSmall)
        }
        .padding(.horizontal, FlotillaSpacing.small)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(tool.capability), powered by \(tool.rawValue), \(isInstalled ? "installed" : "not installed")")
    }

    @ViewBuilder
    private var status: some View {
        if isInstalled {
            Label("Installed", systemImage: "checkmark.circle.fill")
                .font(FlotillaTypography.callout.weight(.medium))
                .foregroundStyle(FlotillaColors.success)
        } else {
            VStack(spacing: FlotillaSpacing.small) {
                Text(tool.installCommand)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .textSelection(.enabled)
                Button(copied ? "Copied" : "Copy Command") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tool.installCommand, forType: .string)
                    copied = true
                }
                .controlSize(.small)
                .accessibilityLabel("Copy \(tool.installCommand)")
            }
        }
    }
}
