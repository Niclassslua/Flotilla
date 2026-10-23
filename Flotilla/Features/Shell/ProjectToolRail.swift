import SwiftUI
import DesignSystem
import SessionKit

/// Project tools that open in the main content column from the persistent rail.
/// Overview stays on the project header — it is not a rail entry.
enum ProjectTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case git, issues, files, skills, rules

    var id: Self { self }

    var title: String {
        switch self {
        case .git: "Git"
        case .issues: "Issues"
        case .files: "Files"
        case .skills: "Skills"
        case .rules: "Rules"
        }
    }

    var systemImage: String {
        switch self {
        case .git: "arrow.triangle.branch" // unused — Git uses `GitIcon`
        case .issues: "ant"
        case .files: "folder"
        case .skills: "sparkles"
        case .rules: "doc.text"
        }
    }

    var projectTab: ProjectDetailView.ProjectTab {
        switch self {
        case .git: .git
        case .issues: .issues
        case .files: .files
        case .skills: .skills
        case .rules: .rules
        }
    }

    init?(projectTab: ProjectDetailView.ProjectTab) {
        switch projectTab {
        case .overview: return nil
        case .git: self = .git
        case .issues: self = .issues
        case .files: self = .files
        case .skills: self = .skills
        case .rules: self = .rules
        }
    }
}

/// Far-left Xcode-style activity rail for project tools (issue #7).
struct ProjectToolRail: View {
    let projectID: UUID?
    let activeTool: ProjectTool?
    let showLabels: Bool
    let onSelect: (ProjectTool) -> Void

    private var isEnabled: Bool { projectID != nil }
    private var width: CGFloat {
        showLabels ? FlotillaLayoutWidth.toolRailLabeledWidth : FlotillaLayoutWidth.toolRailWidth
    }

    var body: some View {
        VStack(spacing: showLabels ? 6 : 4) {
            ForEach(ProjectTool.allCases) { tool in
                railButton(for: tool)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(FlotillaColors.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Project tools")
        .accessibilityIdentifier(AXID.projectToolRail.rawValue)
    }

    private func railButton(for tool: ProjectTool) -> some View {
        let isActive = isEnabled && activeTool == tool
        return Button {
            guard isEnabled else { return }
            onSelect(tool)
        } label: {
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? FlotillaColors.accent.opacity(0.28) : .clear)
                        .frame(width: 36, height: 36)
                        .overlay(alignment: .leading) {
                            if isActive {
                                Capsule()
                                    .fill(FlotillaColors.accent)
                                    .frame(width: 3, height: 18)
                                    .offset(x: -2)
                            }
                        }

                    Group {
                        if tool == .git {
                            GitIcon(size: 16)
                        } else {
                            Image(systemName: tool.systemImage)
                                .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                                .symbolRenderingMode(.hierarchical)
                        }
                    }
                    .foregroundStyle(glyphColor(isActive: isActive))
                    .frame(width: 28, height: 28)
                }
                .frame(width: 40, height: 40)

                if showLabels {
                    Text(tool.title)
                        .font(.system(size: 9, weight: isActive ? .semibold : .medium))
                        .foregroundStyle(isEnabled
                            ? (isActive ? FlotillaColors.textPrimary : FlotillaColors.textSecondary)
                            : FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : FlotillaStateOpacity.disabled)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(isEnabled ? tool.title : "Select a project")
        .accessibilityLabel(tool.title)
        .accessibilityHint(isEnabled ? "" : "Select a project")
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
        .accessibilityIdentifier(AXID.projectToolRailItem(tool.title))
    }

    private func glyphColor(isActive: Bool) -> Color {
        if !isEnabled { return FlotillaColors.textTertiary }
        return isActive ? FlotillaColors.accent : FlotillaColors.textSecondary
    }
}
