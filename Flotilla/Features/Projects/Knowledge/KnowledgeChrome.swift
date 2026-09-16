import SwiftUI
import DesignSystem

/// Small shared pieces drawn by the catalog — the icon tile, scope/framework
/// chips, metric pills, tag chips, search field, scope picker, and sort menu.

// MARK: - Icon

/// The rounded icon tile that identifies an item: an agent framework logo for
/// skills, the file's own Material icon for rules.
struct KnowledgeIconTile: View {
    let item: KnowledgeItem
    var size: CGFloat = 32
    var isHighlighted = false

    private var cornerRadius: CGFloat { size * 0.25 }

    private var tint: Color {
        if let framework = item.framework {
            return SkillFrameworkBrand.accentColor(for: framework)
        }
        return FlotillaColors.accent
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(fill)
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(tint.opacity(isHighlighted ? 0.35 : 0.15), lineWidth: FlotillaBorderWidth.hairline)
                }
            glyph
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var fill: Color {
        if let framework = item.framework {
            return SkillFrameworkBrand.iconBackgroundColor(for: framework, isHovered: isHighlighted)
        }
        return FlotillaColors.accent.opacity(isHighlighted ? 0.18 : 0.10)
    }

    @ViewBuilder
    private var glyph: some View {
        switch item.icon {
        case .file(let url):
            MaterialFileIcon(url: url, size: size * 0.62)
        case .plugin:
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: size * 0.42))
                .foregroundStyle(tint)
        case .framework(let framework):
            if let logo = framework.logoAsset {
                logo.image
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.53, height: size * 0.53)
            } else {
                Image(systemName: framework.iconSystemName)
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(tint)
            }
        }
    }
}

// MARK: - Chips

struct KnowledgeScopeChip: View {
    let item: KnowledgeItem
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: item.scope.symbolName)
                .font(.system(size: compact ? 8 : 9))
            Text(item.scopeLabel)
                .font(FlotillaTypography.caption2.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(FlotillaColors.textSecondary)
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, 2)
        .background(FlotillaColors.surfaceElevated, in: Capsule())
        .accessibilityLabel("\(item.scopeLabel) scope")
    }
}

struct KnowledgeFrameworkChip: View {
    let item: KnowledgeItem

    var body: some View {
        if let name = item.frameworkName, let framework = item.framework {
            Text(name)
                .font(FlotillaTypography.caption2.weight(.semibold))
                .foregroundStyle(SkillFrameworkBrand.accentColor(for: framework))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(SkillFrameworkBrand.accentColor(for: framework).opacity(0.12), in: Capsule())
        }
    }
}

struct KnowledgeVersionChip: View {
    let version: String

    var body: some View {
        Text("v\(version)")
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(FlotillaColors.textTertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(FlotillaColors.surface, in: Capsule())
    }
}

struct KnowledgeMetricPill: View {
    let metric: KnowledgeMetric

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: metric.symbolName)
                .font(.system(size: 9))
                .foregroundStyle(metric.role.color)
            Text(metric.label)
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
        }
    }
}

struct KnowledgeTagChip: View {
    let tag: String

    var body: some View {
        Text("#\(tag)")
            .font(FlotillaTypography.caption2)
            .foregroundStyle(FlotillaColors.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(FlotillaColors.canvas.opacity(0.6), in: RoundedRectangle(cornerRadius: 3, style: .continuous))
    }
}

/// The copyable `/skill <args>` snippet. Only skills have one.
struct KnowledgeInvocationChip: View {
    let invocation: String
    let onCopy: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
                .foregroundStyle(FlotillaColors.accent)
            Text(invocation)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Button {
                onCopy(invocation)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Copy command invocation")
            .accessibilityLabel("Copy invocation")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(FlotillaColors.canvas.opacity(0.8), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Section header

/// Uppercased, wide-tracked section label — the convention `LaunchpadDesign`
/// established for group headings.
struct KnowledgeSectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Text(title.uppercased())
                .font(FlotillaTypography.caption2.weight(.bold))
                .tracking(FlotillaTypography.Tracking.loose3)
                .foregroundStyle(FlotillaColors.textTertiary)

            if let count {
                Text("\(count)")
                    .font(FlotillaTypography.caption3.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(FlotillaColors.surfaceElevated, in: Capsule())
            }

            Spacer(minLength: 0)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Empty state

struct KnowledgeEmptyState: View {
    let kind: KnowledgeKind
    let filter: KnowledgeFilter
    let isSearching: Bool

    var body: some View {
        ContentUnavailableView(
            isSearching ? "No Matches" : "No \(kind.title) Found",
            systemImage: isSearching ? "magnifyingglass" : kind.emptySymbol,
            description: Text(description)
        )
    }

    private var description: String {
        if isSearching {
            return "No \(kind.singular) matches your search. Try a different term or clear the filter."
        }
        switch (kind, filter) {
        case (.skills, .all):
            return "Add SKILL.md to .claude/skills/, .agents/skills/, .codex/skills/, .cursor/skills/, or .gemini/skills/ (globally or in this project)."
        case (.skills, .global):
            return "No global skills found in ~/.claude/skills/, ~/.agents/skills/, ~/.codex/skills/, ~/.cursor/skills/, or ~/.gemini/skills/."
        case (.skills, .project):
            return "No project-scoped skills found in project skills folders."
        case (.rules, .all):
            return "No rule instruction files found. Add AGENTS.md, CLAUDE.md, GEMINI.md, or .cursorrules to get started."
        case (.rules, .global):
            return "No global rules found in ~/.claude/ or ~/.agents/."
        case (.rules, .project):
            return "No project-scoped rules found in this workspace root."
        }
    }
}

// MARK: - List controls

/// Search field, sized to whatever container it lands in.
struct KnowledgeSearchField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(FlotillaColors.textTertiary)
                .font(.system(size: FlotillaIconSize.small))
                .accessibilityHidden(true)

            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)
                .accessibilityIdentifier(AXID.knowledgeSearchField.rawValue)

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, FlotillaSpacing.small + 2)
        .padding(.vertical, 5)
        .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
    }
}

struct KnowledgeScopePicker: View {
    @Binding var filter: KnowledgeFilter

    var body: some View {
        Picker("Scope", selection: $filter) {
            ForEach(KnowledgeFilter.allCases, id: \.self) { filter in
                Text(filter.label).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier(AXID.knowledgeScopeFilter.rawValue)
    }
}

/// Sort control. Icon-only in tight columns — the current choice stays
/// readable through the tooltip and the menu's own checkmark.
struct KnowledgeSortMenu: View {
    @Binding var sort: KnowledgeSort
    var showsLabel = true

    var body: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(KnowledgeSort.allCases) { option in
                    Label(option.label, systemImage: option.symbolName).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            if showsLabel {
                Label(sort.label, systemImage: "arrow.up.arrow.down")
                    .font(FlotillaTypography.caption)
            } else {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: FlotillaIconSize.small))
            }
        }
        .menuIndicator(showsLabel ? .visible : .hidden)
        .fixedSize()
        .help("Sort by \(sort.label)")
        .accessibilityLabel("Sort by \(sort.label)")
        .accessibilityIdentifier(AXID.knowledgeSortMenu.rawValue)
    }
}

/// The filter strip docked above the list column.
struct KnowledgeListControls: View {
    @Bindable var viewModel: ProjectKnowledgeViewModel

    var body: some View {
        VStack(spacing: FlotillaSpacing.small) {
            KnowledgeSearchField(
                prompt: viewModel.kind.searchPrompt,
                text: $viewModel.searchText
            )

            HStack(spacing: FlotillaSpacing.small) {
                KnowledgeScopePicker(filter: $viewModel.filter)
                    .frame(maxWidth: 220)
                Spacer(minLength: 0)
                KnowledgeSortMenu(sort: $viewModel.sort)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surface)
        .overlay(alignment: .bottom) { Divider() }
    }
}
