import SwiftUI
import DesignSystem

/// How the detail pane is being presented, which changes only its chrome:
/// a modal floats and offers a close button; a docked pane fills its column.
enum KnowledgeDetailPresentation {
    case modal
    case docked
}

/// The read-and-edit surface for one item, shared by all four designs.
///
/// Replaces the two duplicated `enlargedCardHeader` implementations the Skills
/// and Rules tabs each carried. Rendering is Markdown by default and swaps to a
/// syntax-highlighted editor on Edit, with ⌘S wired to save.
struct KnowledgeDetailView: View {
    let item: KnowledgeItem
    @Bindable var viewModel: ProjectKnowledgeViewModel
    let actions: KnowledgeActions
    var presentation: KnowledgeDetailPresentation = .modal
    let onClose: () -> Void

    @State private var isEditing = false
    @FocusState private var isEditorFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: item)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // A new selection always lands in reading mode — carrying an open
        // editor across files invites saving into the wrong one.
        .onChange(of: item.id) { _, _ in isEditing = false }
    }

    // MARK: - Content

    @ViewBuilder
    private func body(for item: KnowledgeItem) -> some View {
        if isEditing {
            SyntaxHighlightedTextEditor(
                text: $viewModel.content,
                language: .markdown,
                font: .system(.body, design: .monospaced),
                onTextChange: { viewModel.content = $0 }
            )
            .focused($isEditorFocused)
            .padding(FlotillaSpacing.small)
            .background(FlotillaColors.terminalCanvas)
            .accessibilityIdentifier(AXID.knowledgeDetailEditor.rawValue)
        } else {
            ScrollView {
                MarkdownView(markdown: viewModel.content)
                    .padding(FlotillaSpacing.large + 4)
                    // Long instruction files are prose; cap the measure so
                    // lines stay readable on a wide window.
                    .frame(maxWidth: FlotillaLayoutWidth.contentMax, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
            .accessibilityIdentifier(AXID.knowledgeDetailReader.rawValue)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.small + 2) {
            HStack(alignment: .top, spacing: FlotillaSpacing.medium) {
                KnowledgeIconTile(item: item, size: 44)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(titleFont)
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        KnowledgeFrameworkChip(item: item)
                        KnowledgeScopeChip(item: item)

                        if let version = item.version {
                            KnowledgeVersionChip(version: version)
                        }
                    }

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(FlotillaTypography.callout)
                            .foregroundStyle(FlotillaColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let invocation = item.invocation {
                        KnowledgeInvocationChip(invocation: invocation, onCopy: actions.copy)
                    }
                }

                Spacer(minLength: FlotillaSpacing.small)

                controls
            }

            if !item.metrics.isEmpty || item.author != nil || item.license != nil {
                metricRibbon
            }

            if !item.tags.isEmpty {
                HStack(spacing: 5) {
                    ForEach(item.tags, id: \.self) { KnowledgeTagChip(tag: $0) }
                }
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
        .background(FlotillaColors.surface)
    }

    /// Rules are identified by path, so they read as machine facts and get
    /// monospace; skill names are prose.
    private var titleFont: Font {
        item.kind == .rules
            ? .title3.weight(.bold).monospaced()
            : .title3.weight(.bold)
    }

    private var metricRibbon: some View {
        HStack(spacing: FlotillaSpacing.medium) {
            ForEach(item.metrics) { KnowledgeMetricPill(metric: $0) }

            if let date = item.lastModified {
                KnowledgeMetricPill(metric: KnowledgeMetric(
                    label: formatRelativeDate(date),
                    symbolName: "calendar",
                    role: .neutral
                ))
            }

            Spacer(minLength: 0)

            if let author = item.author {
                Text("by \(author)")
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
            if let license = item.license {
                Text(license)
                    .font(FlotillaTypography.caption2.monospaced())
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Controls

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Button {
                actions.openExternally(item.url)
            } label: {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: FlotillaIconSize.small))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Open in default system application")
            .accessibilityLabel("Open in default application")

            if isEditing {
                if let message = viewModel.message {
                    Label(
                        message,
                        systemImage: message.hasPrefix("Saved") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(message.hasPrefix("Saved") ? FlotillaColors.success : FlotillaColors.danger)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(message)
                    .accessibilityIdentifier(AXID.knowledgeSaveStatus.rawValue)
                }

                Button("Save") {
                    // Blurring the editor first flushes the in-flight edit into
                    // the binding; the yield lets that land before we write.
                    isEditorFocused = false
                    Task {
                        await Task.yield()
                        await viewModel.save()
                    }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(viewModel.isSaving)
                .accessibilityIdentifier(AXID.knowledgeSaveButton.rawValue)

                Button("Done") {
                    isEditing = false
                }
                .buttonStyle(.borderedProminent)
                .tint(FlotillaColors.accent)
                .controlSize(.small)
            } else {
                Button {
                    isEditing = true
                    isEditorFocused = true
                } label: {
                    Label("Edit", systemImage: "pencil")
                        .font(FlotillaTypography.caption)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier(AXID.knowledgeEditButton.rawValue)
            }

            if presentation == .modal {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FlotillaIconSize.medium))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
                .help("Close (Esc)")
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close")
            }
        }
    }
}

/// Placeholder shown by the docked designs when nothing is selected yet.
struct KnowledgeNoSelectionView: View {
    let kind: KnowledgeKind

    var body: some View {
        ContentUnavailableView(
            "Select a \(kind.singular.capitalized)",
            systemImage: "doc.text.magnifyingglass",
            description: Text("Review and edit the instructions this project gives its agents.")
        )
        // Without an explicit fill the placeholder sizes to its own content and
        // an `HSplitView` pane parks it against the bottom edge.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .accessibilityIdentifier(AXID.knowledgeNoSelection.rawValue)
    }
}
