import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DesignSystem

/// A temporary inspector panel for screenshots the agent just sent. It only
/// exists while something is pending — closing it hands the inspector back to
/// whatever it showed before.
struct AgentScreenshotPanel: View {
    let screenshots: [AgentScreenshot]
    let onClose: () -> Void

    /// Index into `screenshots`; `nil` follows the newest as more arrive.
    @State private var pinnedIndex: Int?
    @State private var isViewerPresented = false

    private var index: Int {
        min(pinnedIndex ?? screenshots.count - 1, screenshots.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if screenshots.indices.contains(index) {
                content(for: screenshots[index])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .flotillaInspectorSurface()
        .onExitCommand(perform: onClose)
        .sheet(isPresented: $isViewerPresented) {
            if screenshots.indices.contains(index) {
                AgentScreenshotViewerSheet(
                    screenshots: screenshots,
                    selectedIndex: Binding(
                        get: { index },
                        set: { newIndex in
                            guard screenshots.indices.contains(newIndex) else { return }
                            pinnedIndex = newIndex == screenshots.count - 1 ? nil : newIndex
                        }
                    ),
                    onClose: { isViewerPresented = false }
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.agentScreenshotPanel.rawValue)
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Image(systemName: "photo")
                .font(.system(size: FlotillaIconSize.small, weight: .medium))
                .foregroundStyle(FlotillaColors.accent)
                .accessibilityHidden(true)
            Text("Screenshot")
                .font(FlotillaTypography.callout.weight(.semibold))
                .foregroundStyle(FlotillaColors.textPrimary)
            if screenshots.count > 1 {
                pager
            }
            Spacer(minLength: 0)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                    .frame(width: FlotillaControlHeight.small, height: FlotillaControlHeight.small)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Close screenshot")
            .accessibilityLabel("Close screenshot")
            .accessibilityIdentifier(AXID.agentScreenshotPanelClose.rawValue)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 38)
        .background(Color.clear)
    }

    private var pager: some View {
        HStack(spacing: 2) {
            Button {
                pinnedIndex = max(index - 1, 0)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(index == 0)
            .accessibilityLabel("Previous screenshot")
            Text("\(index + 1) of \(screenshots.count)")
                .font(FlotillaTypography.caption2.monospacedDigit())
                .foregroundStyle(FlotillaColors.textTertiary)
            Button {
                let next = index + 1
                pinnedIndex = next >= screenshots.count - 1 ? nil : next
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(index >= screenshots.count - 1)
            .accessibilityLabel("Next screenshot")
        }
        .buttonStyle(.borderless)
        .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
    }

    private func content(for screenshot: AgentScreenshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                if let filename = screenshot.filename {
                    Text(filename)
                        .font(FlotillaTypography.caption.weight(.medium))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    isViewerPresented = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        Image(nsImage: screenshot.image)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                            )

                        HStack(spacing: 4) {
                            Image(systemName: "plus.magnifyingglass")
                                .font(.system(size: 10, weight: .semibold))
                            Text("Zoom")
                                .font(FlotillaTypography.caption2.weight(.medium))
                        }
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            FlotillaColors.surfaceElevated.opacity(0.9),
                            in: Capsule()
                        )
                        .overlay(
                            Capsule().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                        )
                        .padding(8)
                    }
                }
                .buttonStyle(.plain)
                .help("Click to view full size and zoom")
                .accessibilityLabel("Screenshot from \(screenshot.agent.displayName), click to zoom")
                .accessibilityIdentifier(AXID.agentScreenshotPanelImage.rawValue)

                Text("Sent by \(screenshot.agent.displayName) · \(screenshot.timestamp, style: .relative) ago")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .lineLimit(1)
            }
            .padding(FlotillaSpacing.medium)
        }
        .id(screenshot.id)
    }
}

/// Full-size interactive zoomable and pannable image viewer modal sheet for macOS.
struct AgentScreenshotViewerSheet: View {
    let screenshots: [AgentScreenshot]
    @Binding var selectedIndex: Int
    let onClose: () -> Void

    @State private var scale: CGFloat = 1.0
    @State private var baseScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var copied = false

    private var pixelDimensions: String {
        if let rep = screenshot.image.representations.first {
            return "\(rep.pixelsWide) × \(rep.pixelsHigh)"
        }
        let size = screenshot.image.size
        return "\(Int(size.width)) × \(Int(size.height))"
    }

    private var zoomPercentage: Int {
        Int(round(scale * 100))
    }

    private var screenshot: AgentScreenshot {
        screenshots[selectedIndex]
    }

    private var canShowPrevious: Bool {
        selectedIndex > 0
    }

    private var canShowNext: Bool {
        selectedIndex < screenshots.count - 1
    }

    var body: some View {
        Group {
            if screenshots.indices.contains(selectedIndex) {
                VStack(spacing: 0) {
                    header
                    Divider()
                    viewport
                }
            }
        }
        .frame(minWidth: 960, idealWidth: 1280, maxWidth: 1920, minHeight: 680, idealHeight: 900, maxHeight: 1280)
        .flotillaLiquidSurface(FlotillaColors.canvas, glassTintOpacity: FlotillaGlassTint.detail)
        .onExitCommand(perform: onClose)
        .onChange(of: screenshot.id) { _, _ in
            resetZoom()
            copied = false
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.agentScreenshotViewerSheet.rawValue)
    }

    private var header: some View {
        HStack(spacing: FlotillaSpacing.large) {
            HStack(spacing: FlotillaSpacing.small) {
                ProviderLogo(agent: screenshot.agent)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(screenshot.filename ?? "\(screenshot.agent.displayName) Screenshot")
                        .font(FlotillaTypography.callout.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 6) {
                        Text("\(screenshot.timestamp, style: .relative) ago")
                        if !pixelDimensions.isEmpty {
                            Text("·")
                            Text(pixelDimensions)
                        }
                    }
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
            .layoutPriority(-1)

            Spacer(minLength: FlotillaSpacing.small)

            if screenshots.count > 1 {
                screenshotPager
                    .layoutPriority(1)
            }

            // Zoom Controls
            HStack(spacing: 3) {
                Button {
                    zoomOut()
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                        .font(.system(size: FlotillaIconSize.small))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(scale <= 0.25)
                .help("Zoom out (⌘-)")
                .keyboardShortcut("-", modifiers: .command)

                Text("\(zoomPercentage)%")
                    .font(FlotillaTypography.caption2.monospacedDigit().weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .frame(width: 44)

                Button {
                    zoomIn()
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                        .font(.system(size: FlotillaIconSize.small))
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(scale >= 6.0)
                .help("Zoom in (⌘+)")
                .keyboardShortcut("=", modifiers: .command)

                Divider()
                    .frame(height: 16)
                    .padding(.horizontal, 4)

                Button("Fit") {
                    resetZoom()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(FlotillaTypography.caption2)
                .help("Fit to window (⌘9)")
                .keyboardShortcut("9", modifiers: .command)

                Button("100%") {
                    zoomToActualSize()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(FlotillaTypography.caption2)
                .help("Actual size (⌘0)")
                .keyboardShortcut("0", modifiers: .command)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                FlotillaColors.surfaceElevated,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            )
            .layoutPriority(1)

            Spacer(minLength: FlotillaSpacing.small)

            // Actions
            HStack(spacing: FlotillaSpacing.small) {
                Button {
                    copy()
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Copy image to clipboard (⌘C)")
                .keyboardShortcut("c", modifiers: .command)

                Button {
                    save()
                } label: {
                    Label("Save…", systemImage: "square.and.arrow.down")
                        .fixedSize()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Save image to file (⌘S)")
                .keyboardShortcut("s", modifiers: .command)

                Button("Done", action: onClose)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(FlotillaColors.accent)
                    .fixedSize()
                    .accessibilityIdentifier(AXID.agentScreenshotViewerClose.rawValue)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, FlotillaSpacing.large)
        .frame(height: 56)
        .background(FlotillaColors.surface)
    }

    private var screenshotPager: some View {
        HStack(spacing: 3) {
            Button {
                selectedIndex = max(selectedIndex - 1, 0)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canShowPrevious)
            .help("Previous screenshot (←)")
            .keyboardShortcut(.leftArrow)
            .accessibilityLabel("Previous screenshot")
            .accessibilityIdentifier(AXID.agentScreenshotViewerPrevious.rawValue)

            Text("\(selectedIndex + 1) of \(screenshots.count)")
                .font(FlotillaTypography.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(minWidth: 48)

            Button {
                selectedIndex = min(selectedIndex + 1, screenshots.count - 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canShowNext)
            .help("Next screenshot (→)")
            .keyboardShortcut(.rightArrow)
            .accessibilityLabel("Next screenshot")
            .accessibilityIdentifier(AXID.agentScreenshotViewerNext.rawValue)
        }
        .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            FlotillaColors.surfaceElevated,
            in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Screenshot navigation")
        .accessibilityValue("Screenshot \(selectedIndex + 1) of \(screenshots.count)")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                guard canShowNext else { return }
                selectedIndex += 1
            case .decrement:
                guard canShowPrevious else { return }
                selectedIndex -= 1
            @unknown default:
                break
            }
        }
    }

    private var viewport: some View {
        GeometryReader { geometry in
            ZStack {
                FlotillaColors.canvas
                    .ignoresSafeArea()

                Image(nsImage: screenshot.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = max(0.2, min(8.0, baseScale * value.magnification))
                            }
                            .onEnded { _ in
                                baseScale = scale
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                offset = CGSize(
                                    width: baseOffset.width + value.translation.width,
                                    height: baseOffset.height + value.translation.height
                                )
                            }
                            .onEnded { _ in
                                baseOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                            if abs(scale - 1.0) < 0.15 {
                                scale = 2.5
                                baseScale = 2.5
                            } else {
                                resetZoom()
                            }
                        }
                    }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
    }

    private func zoomIn() {
        withAnimation(.easeInOut(duration: 0.15)) {
            scale = min(8.0, scale * 1.3)
            baseScale = scale
        }
    }

    private func zoomOut() {
        withAnimation(.easeInOut(duration: 0.15)) {
            scale = max(0.2, scale / 1.3)
            baseScale = scale
        }
    }

    private func resetZoom() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            scale = 1.0
            baseScale = 1.0
            offset = .zero
            baseOffset = .zero
        }
    }

    private func zoomToActualSize() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            scale = 1.5
            baseScale = 1.5
            offset = .zero
            baseOffset = .zero
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([screenshot.image])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .png]
        panel.nameFieldStringValue = screenshot.filename ?? "Screenshot-\(screenshot.agent.displayName).jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? screenshot.data.write(to: url, options: .atomic)
    }
}
