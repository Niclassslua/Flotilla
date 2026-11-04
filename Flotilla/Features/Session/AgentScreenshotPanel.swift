import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import DesignSystem

/// A temporary inspector panel for screenshots the agent sent. It opens on its
/// own when a new one arrives; closing it hands the inspector back to whatever
/// it showed before.
struct AgentScreenshotPanel: View {
    let screenshots: [AgentScreenshot]
    let onClose: () -> Void

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        AgentScreenshotBrowser(
            screenshots: screenshots,
            usesKeyboardShortcuts: false,
            onOpenInWindow: { openWindow(id: AgentScreenshotWindow.sceneID) },
            onClose: onClose
        )
        .flotillaInspectorSurface(ignoresSafeAreaEdges: .top)
        .onExitCommand(perform: onClose)
        .accessibilityIdentifier(AXID.agentScreenshotPanel.rawValue)
    }
}

/// A standalone, non-modal viewer that follows the focused session's screenshots.
struct AgentScreenshotWindow: View {
    static let sceneID = "agent-screenshots"

    @Environment(AgentScreenshotMonitor.self) private var monitor

    var body: some View {
        Group {
            if monitor.screenshots.isEmpty {
                ContentUnavailableView(
                    "No Screenshots",
                    systemImage: "photo",
                    description: Text("Screenshots the focused session's agent sends appear here.")
                )
            } else {
                AgentScreenshotBrowser(screenshots: monitor.screenshots, usesKeyboardShortcuts: true)
            }
        }
        .frame(minWidth: 640, minHeight: 480)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .accessibilityIdentifier(AXID.agentScreenshotWindow.rawValue)
    }
}

/// Image viewer shared by the panel and the window: metadata, a zoomable
/// image, zoom/export controls, and a thumbnail strip.
private struct AgentScreenshotBrowser: View {
    let screenshots: [AgentScreenshot]
    /// Only the window binds keys; in the panel arrows and ⌘C belong to the terminal.
    let usesKeyboardShortcuts: Bool
    var onOpenInWindow: (() -> Void)?
    var onClose: (() -> Void)?

    /// Selected screenshot; `nil` follows the newest as more arrive.
    @State private var pinnedID: String?
    @State private var zoom = ImageZoomController()
    @State private var copied = false
    @AppStorage("agentScreenshotDesign") private var design = 0

    private var index: Int {
        pinnedID.flatMap { id in screenshots.firstIndex { $0.id == id } } ?? screenshots.count - 1
    }

    private func select(_ newIndex: Int) {
        guard screenshots.indices.contains(newIndex) else { return }
        pinnedID = newIndex == screenshots.count - 1 ? nil : screenshots[newIndex].id
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if screenshots.indices.contains(index) {
                let screenshot = screenshots[index]
                switch design {
                case 1:
                    image(for: screenshot)
                        .padding(12)
                    metadata(for: screenshot)
                    controls(for: screenshot)
                    Divider()
                    thumbnails
                case 2:
                    metadata(for: screenshot)
                    Divider()
                    HStack(spacing: 0) {
                        image(for: screenshot)
                        Divider()
                        thumbnailRail
                    }
                    Divider()
                    controls(for: screenshot)
                case 3:
                    controls(for: screenshot)
                    Divider()
                    image(for: screenshot)
                        .padding(8)
                    Divider()
                    metadata(for: screenshot)
                    thumbnails
                default:
                    thumbnails
                    Divider()
                    image(for: screenshot)
                    Divider()
                    metadata(for: screenshot)
                    controls(for: screenshot)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: index) { _, _ in copied = false }
        .accessibilityElement(children: .contain)
    }

    private func image(for screenshot: AgentScreenshot) -> some View {
        ZoomableImageView(image: screenshot.image, controller: zoom) { select(index + $0) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .accessibilityLabel("Screenshot from \(screenshot.agent.displayName)")
            .accessibilityIdentifier(AXID.agentScreenshotPanelImage.rawValue)
    }

    private var thumbnailRail: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(screenshots.enumerated()), id: \.element.id) { offset, screenshot in
                    Button { select(offset) } label: {
                        Image(nsImage: screenshot.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 54, height: 40)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                                offset == index ? FlotillaColors.accent : FlotillaColors.separator,
                                lineWidth: offset == index ? 2 : FlotillaBorderWidth.hairline
                            ))
                    }
                    .buttonStyle(.plain)
                    .help(screenshot.filename ?? "Screenshot \(offset + 1)")
                    .accessibilityLabel(screenshot.filename ?? "Screenshot \(offset + 1)")
                    .accessibilityAddTraits(offset == index ? .isSelected : [])
                }
            }
            .padding(8)
        }
        .frame(width: 70)
        .accessibilityIdentifier(AXID.agentScreenshotThumbnails.rawValue)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "photo")
                .font(.system(size: FlotillaIconSize.small, weight: .medium))
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityHidden(true)
            Text(screenshots.count == 1 ? "Screenshot" : "Screenshots")
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            if screenshots.count > 1 { pager }
            Spacer(minLength: 0)
            Menu {
                Picker("Screenshot design", selection: $design) {
                    Text("1 · Contact sheet").tag(0)
                    Text("2 · Gallery").tag(1)
                    Text("3 · Filmstrip").tag(2)
                    Text("4 · Studio").tag(3)
                }
            } label: {
                Image(systemName: "rectangle.3.group")
                    .frame(width: FlotillaControlHeight.small, height: FlotillaControlHeight.small)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose screenshot design")
            .accessibilityLabel("Choose screenshot design")
            if let onOpenInWindow {
                iconButton("macwindow", help: "Open in window", action: onOpenInWindow)
                    .accessibilityIdentifier(AXID.agentScreenshotPanelOpenWindow.rawValue)
            }
            if let onClose {
                iconButton("xmark", help: "Close screenshot", action: onClose)
                    .accessibilityIdentifier(AXID.agentScreenshotPanelClose.rawValue)
            }
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 38)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            iconButton("chevron.left", help: "Previous screenshot") { select(index - 1) }
                .disabled(index == 0)
                .shortcut(.leftArrow, enabled: usesKeyboardShortcuts)
                .accessibilityIdentifier(AXID.agentScreenshotViewerPrevious.rawValue)
            Text("\(index + 1) of \(screenshots.count)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
                .fixedSize()
            iconButton("chevron.right", help: "Next screenshot") { select(index + 1) }
                .disabled(index >= screenshots.count - 1)
                .shortcut(.rightArrow, enabled: usesKeyboardShortcuts)
                .accessibilityIdentifier(AXID.agentScreenshotViewerNext.rawValue)
        }
    }

    // MARK: Metadata

    private func metadata(for screenshot: AgentScreenshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let filename = screenshot.filename {
                Text(filename)
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text("Sent by \(screenshot.agent.displayName) · \(screenshot.timestamp, style: .relative) ago · \(pixelDimensions(screenshot))")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FlotillaSpacing.medium)
        .padding(.vertical, FlotillaSpacing.small)
    }

    private func pixelDimensions(_ screenshot: AgentScreenshot) -> String {
        if let rep = screenshot.image.representations.first, rep.pixelsWide > 0 {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        return "\(Int(screenshot.image.size.width)) × \(Int(screenshot.image.size.height))"
    }

    // MARK: Controls

    private func controls(for screenshot: AgentScreenshot) -> some View {
        HStack(spacing: 2) {
            iconButton("minus.magnifyingglass", help: "Zoom out (⌘−)", action: zoom.zoomOut)
                .shortcut("-", modifiers: .command, enabled: usesKeyboardShortcuts)
            Text("\(Int((zoom.zoom * 100).rounded()))%")
                .font(FlotillaTypography.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(minWidth: 38)
            iconButton("plus.magnifyingglass", help: "Zoom in (⌘+)", action: zoom.zoomIn)
                .shortcut("=", modifiers: .command, enabled: usesKeyboardShortcuts)
            Button("Fit", action: zoom.fit)
                .help("Fit (⌘9)")
                .disabled(zoom.isFitted)
                .shortcut("9", modifiers: .command, enabled: usesKeyboardShortcuts)
            Button("100%", action: zoom.actualSize)
                .help("Actual pixels (⌘0)")
                .shortcut("0", modifiers: .command, enabled: usesKeyboardShortcuts)
            Spacer(minLength: FlotillaSpacing.small)
            iconButton(copied ? "checkmark" : "doc.on.doc", help: "Copy image") { copy(screenshot) }
                .shortcut("c", modifiers: .command, enabled: usesKeyboardShortcuts)
            iconButton("square.and.arrow.down", help: "Save image…") { save(screenshot) }
                .shortcut("s", modifiers: .command, enabled: usesKeyboardShortcuts)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(FlotillaTypography.caption2)
        .padding(.horizontal, FlotillaSpacing.small)
        .frame(height: 32)
    }

    // MARK: Thumbnails

    private var thumbnails: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FlotillaSpacing.small) {
                    ForEach(Array(screenshots.enumerated()), id: \.element.id) { offset, screenshot in
                        Button { select(offset) } label: {
                            Image(nsImage: screenshot.image)
                                .resizable()
                                .interpolation(.medium)
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 64, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                                        .strokeBorder(
                                            offset == index ? FlotillaColors.accent : FlotillaColors.separator,
                                            lineWidth: offset == index ? 2 : FlotillaBorderWidth.hairline
                                        )
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(screenshot.filename ?? "Screenshot \(offset + 1)")
                        .accessibilityLabel(screenshot.filename ?? "Screenshot \(offset + 1)")
                        .accessibilityAddTraits(offset == index ? .isSelected : [])
                        .id(screenshot.id)
                    }
                }
                .padding(FlotillaSpacing.small)
            }
            .onAppear { proxy.scrollTo(screenshots.last?.id, anchor: .trailing) }
            .onChange(of: index) { _, newIndex in
                withAnimation { proxy.scrollTo(screenshots[newIndex].id) }
            }
            .onChange(of: screenshots.last?.id) { _, id in
                guard pinnedID == nil else { return }
                withAnimation { proxy.scrollTo(id, anchor: .trailing) }
            }
        }
        .frame(height: 60)
        .accessibilityIdentifier(AXID.agentScreenshotThumbnails.rawValue)
    }

    // MARK: Actions

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                .frame(width: FlotillaControlHeight.small, height: FlotillaControlHeight.small)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textSecondary)
        .help(help)
        .accessibilityLabel(help)
    }

    private func copy(_ screenshot: AgentScreenshot) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([screenshot.image])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func save(_ screenshot: AgentScreenshot) {
        let panel = NSSavePanel()
        let type = CGImageSourceCreateWithData(screenshot.data as CFData, nil)
            .flatMap(CGImageSourceGetType)
            .flatMap { UTType($0 as String) } ?? .png
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = screenshot.filename ?? "Screenshot-\(screenshot.agent.displayName).\(type.preferredFilenameExtension ?? "png")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? screenshot.data.write(to: url, options: .atomic)
    }
}

private extension View {
    @ViewBuilder
    func shortcut(_ key: KeyEquivalent, modifiers: EventModifiers = [], enabled: Bool) -> some View {
        if enabled { keyboardShortcut(key, modifiers: modifiers) } else { self }
    }
}
