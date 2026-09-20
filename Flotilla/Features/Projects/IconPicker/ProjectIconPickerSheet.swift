import SwiftUI
import UniformTypeIdentifiers
import SessionKit
import DesignSystem

/// The comprehensive hybrid icon picker for projects:
/// - SF Symbols tab with search and category filtering
/// - Emojis tab with search
/// - Custom Image tab with drag-and-drop, multi-format file browser (.icns, .icon, .ico, svg, pdf, png, etc.),
///   clipboard paste, and the interactive native cropper.
public struct ProjectIconPickerSheet: View {
    let project: Project
    let onSave: (ProjectIcon?) -> Void
    let onDismiss: () -> Void

    @State private var selectedTab: PickerTab = .symbols
    @State private var selectedSymbol: String?
    @State private var selectedEmoji: String?
    @State private var stagedImage: NSImage?
    @State private var searchQuery: String = ""
    @State private var isDropTargeted = false

    enum PickerTab: String, CaseIterable, Identifiable {
        case symbols = "Symbols"
        case emojis = "Emojis"
        case customImage = "Custom Image"

        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .symbols: return "star.fill"
            case .emojis: return "face.smiling.inverse"
            case .customImage: return "photo.fill"
            }
        }
    }

    public init(
        project: Project,
        onSave: @escaping (ProjectIcon?) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.project = project
        self.onSave = onSave
        self.onDismiss = onDismiss

        if let existing = project.icon {
            switch existing {
            case .symbol(let name):
                _selectedSymbol = State(initialValue: name)
                _selectedTab = State(initialValue: .symbols)
            case .emoji(let character):
                _selectedEmoji = State(initialValue: character)
                _selectedTab = State(initialValue: .emojis)
            case .custom:
                _selectedTab = State(initialValue: .customImage)
            }
        }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Masthead & Tab Picker
            header

            Divider()
                .background(FlotillaColors.separator)

            // Content Area
            Group {
                if let image = stagedImage {
                    ProjectIconCropperView(
                        sourceImage: image,
                        onChooseAnotherFile: { stagedImage = nil },
                        onCancel: onDismiss,
                        onApply: { pngData in
                            onSave(.custom(data: pngData))
                            onDismiss()
                        }
                    )
                } else {
                    switch selectedTab {
                    case .symbols:
                        symbolsTab
                    case .emojis:
                        emojisTab
                    case .customImage:
                        customImageTab
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if stagedImage == nil {
                Divider()
                    .background(FlotillaColors.separator)
                footer
            }
        }
        .frame(width: 560, height: stagedImage != nil ? 540 : 490)
        .background(FlotillaColors.canvas)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.modal, style: .continuous))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: FlotillaSpacing.large) {
            // Live Preview of Current / Selected Mark
            currentMarkPreview
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Project Icon")
                    .font(FlotillaTypography.headline)
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text(project.name)
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }

            Spacer()

            if stagedImage == nil {
                Picker("", selection: $selectedTab) {
                    ForEach(PickerTab.allCases) { tab in
                        Label(tab.rawValue, systemImage: tab.systemImage)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 270)
            }
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium + 2)
    }

    @ViewBuilder
    private var currentMarkPreview: some View {
        if let staged = stagedImage {
            Image(nsImage: staged)
                .resizable()
                .scaledToFill()
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 38 * 5 / 17, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 38 * 5 / 17, style: .continuous)
                        .strokeBorder(FlotillaColors.separatorStrong, lineWidth: 0.5)
                }
        } else if let symbol = selectedSymbol, selectedTab == .symbols {
            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project), icon: .symbol(name: symbol), size: 38)
        } else if let emoji = selectedEmoji, selectedTab == .emojis {
            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project), icon: .emoji(emoji), size: 38)
        } else {
            ProjectMark(title: project.name, tint: ProjectMark.tint(for: project), icon: project.icon, size: 38)
        }
    }

    // MARK: - Symbols Tab

    private var symbolsTab: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            searchField(placeholder: "Search symbols…")

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                    ForEach(filteredSymbols, id: \.self) { symbol in
                        Button {
                            selectedSymbol = symbol
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                    .fill(selectedSymbol == symbol ? FlotillaColors.accent.opacity(0.2) : FlotillaColors.surface)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                            .strokeBorder(selectedSymbol == symbol ? FlotillaColors.accent : FlotillaColors.separator, lineWidth: 1)
                                    }

                                Image(systemName: symbol)
                                    .font(.system(size: 17, weight: .medium))
                                    .foregroundStyle(selectedSymbol == symbol ? FlotillaColors.accent : FlotillaColors.textPrimary)
                            }
                            .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.vertical, FlotillaSpacing.small)
            }
        }
        .padding(.top, FlotillaSpacing.medium)
    }

    // MARK: - Emojis Tab

    private var emojisTab: some View {
        VStack(spacing: FlotillaSpacing.medium) {
            searchField(placeholder: "Search emojis…")

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 8)], spacing: 8) {
                    ForEach(filteredEmojis, id: \.self) { emoji in
                        Button {
                            selectedEmoji = emoji
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                    .fill(selectedEmoji == emoji ? FlotillaColors.accent.opacity(0.2) : FlotillaColors.surface)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                            .strokeBorder(selectedEmoji == emoji ? FlotillaColors.accent : FlotillaColors.separator, lineWidth: 1)
                                    }

                                Text(emoji)
                                    .font(.system(size: 22))
                            }
                            .frame(height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.vertical, FlotillaSpacing.small)
            }
        }
        .padding(.top, FlotillaSpacing.medium)
    }

    // MARK: - Custom Image Tab

    private var customImageTab: some View {
        VStack(spacing: FlotillaSpacing.large) {
            // Drag & Drop Box
            ZStack {
                RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                    .strokeBorder(
                        isDropTargeted ? FlotillaColors.accent : FlotillaColors.separatorStrong,
                        style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                    )
                    .background(
                        RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                            .fill(isDropTargeted ? FlotillaColors.accent.opacity(0.08) : FlotillaColors.surface)
                    )

                VStack(spacing: FlotillaSpacing.medium) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 34))
                        .foregroundStyle(isDropTargeted ? FlotillaColors.accent : FlotillaColors.textSecondary)

                    VStack(spacing: 3) {
                        Text("Drag & drop an image or icon file here")
                            .font(FlotillaTypography.headline)
                            .foregroundStyle(FlotillaColors.textPrimary)

                        Text("Supports PNG, JPEG, WebP, SVG, PDF, .icns, .ico, .icon bundles, and app icons")
                            .font(FlotillaTypography.caption)
                            .foregroundStyle(FlotillaColors.textTertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, FlotillaSpacing.large)
                    }

                    HStack(spacing: FlotillaSpacing.medium) {
                        Button("Browse Files…", action: openFilePicker)
                            .buttonStyle(.plain)
                            .font(FlotillaTypography.caption.weight(.semibold))
                            .foregroundStyle(FlotillaColors.textPrimary)
                            .padding(.horizontal, FlotillaSpacing.large)
                            .padding(.vertical, FlotillaSpacing.small)
                            .background(FlotillaColors.surfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))

                        if let pasteboardImage = ProjectIconImageLoader.loadFromPasteboard() {
                            Button("Paste from Clipboard") {
                                stagedImage = pasteboardImage
                            }
                            .buttonStyle(.plain)
                            .font(FlotillaTypography.caption.weight(.medium))
                            .foregroundStyle(FlotillaColors.accent)
                            .padding(.horizontal, FlotillaSpacing.large)
                            .padding(.vertical, FlotillaSpacing.small)
                            .background(FlotillaColors.accent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                        }
                    }
                    .padding(.top, FlotillaSpacing.small)
                }
                .padding(FlotillaSpacing.large)
            }
            .padding(.horizontal, FlotillaSpacing.xLarge)
            .padding(.vertical, FlotillaSpacing.large)
            .onDrop(of: [.fileURL, .image], isTargeted: $isDropTargeted) { providers in
                handleDrop(providers)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if project.icon != nil {
                Button("Remove Icon") {
                    onSave(nil)
                    onDismiss()
                }
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.statusCrashed)
            }

            Spacer()

            Button("Cancel", action: onDismiss)
                .buttonStyle(.plain)
                .font(FlotillaTypography.caption.weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .padding(.horizontal, FlotillaSpacing.large)
                .padding(.vertical, FlotillaSpacing.small)
                .background(FlotillaColors.surfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))

            Button("Save") {
                saveCurrentSelection()
            }
            .buttonStyle(.plain)
            .font(FlotillaTypography.caption.weight(.semibold))
            .foregroundStyle(FlotillaColors.accentContent)
            .padding(.horizontal, FlotillaSpacing.large + 4)
            .padding(.vertical, FlotillaSpacing.small)
            .background(FlotillaColors.accent)
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .padding(.vertical, FlotillaSpacing.medium)
    }

    // MARK: - Helpers

    private func searchField(placeholder: String) -> some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(FlotillaColors.textTertiary)

            TextField(placeholder, text: $searchQuery)
                .textFieldStyle(.plain)
                .font(FlotillaTypography.caption)

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
        .background(FlotillaColors.surface)
        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: 1)
        }
        .padding(.horizontal, FlotillaSpacing.large)
    }

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ProjectIconImageLoader.supportedContentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.prompt = "Choose Icon"
        if panel.runModal() == .OK, let url = panel.url {
            if let image = ProjectIconImageLoader.load(from: url) {
                stagedImage = image
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        // 1. Try file URL loading
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var targetURL: URL?
                if let url = item as? URL {
                    targetURL = url
                } else if let data = item as? Data, let urlString = String(data: data, encoding: .utf8) {
                    targetURL = URL(string: urlString)
                }
                if let targetURL, let image = ProjectIconImageLoader.load(from: targetURL) {
                    DispatchQueue.main.async {
                        stagedImage = image
                    }
                }
            }
            return true
        }

        // 2. Try raw image loading
        if provider.canLoadObject(ofClass: NSImage.self) {
            _ = provider.loadObject(ofClass: NSImage.self) { image, _ in
                if let nsImage = image as? NSImage {
                    DispatchQueue.main.async {
                        stagedImage = ProjectIconImageLoader.highestResolutionRepresentation(of: nsImage)
                    }
                }
            }
            return true
        }

        return false
    }

    private func saveCurrentSelection() {
        switch selectedTab {
        case .symbols:
            if let selectedSymbol {
                onSave(.symbol(name: selectedSymbol))
            }
        case .emojis:
            if let selectedEmoji {
                onSave(.emoji(selectedEmoji))
            }
        case .customImage:
            break
        }
        onDismiss()
    }

    // MARK: - Curated Data

    private var filteredSymbols: [String] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return curatedSymbols
        }
        let q = searchQuery.lowercased()
        return curatedSymbols.filter { $0.lowercased().contains(q) }
    }

    private var filteredEmojis: [String] {
        if searchQuery.trimmingCharacters(in: .whitespaces).isEmpty {
            return curatedEmojis
        }
        let q = searchQuery.lowercased()
        return curatedEmojis.filter { $0.contains(q) }
    }

    private let curatedSymbols: [String] = [
        "terminal", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces",
        "cube.fill", "gearshape.2.fill", "cpu.fill", "memorychip", "network", "server.rack",
        "externaldrive.fill", "folder.fill", "folder.badge.gearshape", "tray.full.fill",
        "archivebox.fill", "doc.text.fill", "hammer.fill", "wrench.and.screwdriver.fill",
        "paintbrush.fill", "sparkles", "bolt.fill", "flame.fill", "gauge.with.needle.fill",
        "speedometer", "rocket.fill", "shield.fill", "lock.fill", "arrow.triangle.branch",
        "arrow.triangle.pull", "arrow.triangle.merge", "arrow.clockwise", "star.fill",
        "bookmark.fill", "tag.fill", "flag.fill", "heart.fill", "bell.fill", "lightbulb.fill",
        "globe", "macbook.and.iphone", "play.fill", "waveform.path.ecg", "brain.head.profile",
        "antenna.radiowaves.left.and.right", "puzzlepiece.fill", "wand.and.stars"
    ]

    private let curatedEmojis: [String] = [
        "🚀", "⚡", "🔥", "💥", "🌟", "✨", "💡", "🎯", "🧭", "🛸", "🪐", "🌌", "🌍", "🌐",
        "💻", "🖥️", "📱", "⚙️", "🔧", "🔨", "🛠️", "🔬", "🧪", "📡", "🔋", "💾", "🕹️", "🎮",
        "📦", "📁", "📂", "🗂️", "🏷️", "📌", "🔖", "🔑", "🔒", "🛡️", "💎", "👑", "🏆", "🎨",
        "🤖", "👾", "🦊", "🐙", "🦉", "🦄", "🍀", "☕", "🍕", "⚓", "⛵", "🚢", "🧪", "🪄"
    ]
}
