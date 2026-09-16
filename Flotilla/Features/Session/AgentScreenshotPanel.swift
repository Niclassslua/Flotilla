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
        .background(FlotillaColors.canvas)
        .onExitCommand(perform: onClose)
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
            }
            .buttonStyle(.plain)
            .foregroundStyle(FlotillaColors.textSecondary)
            .help("Close screenshot")
            .accessibilityLabel("Close screenshot")
            .accessibilityIdentifier(AXID.agentScreenshotPanelClose.rawValue)
        }
        .padding(.horizontal, FlotillaSpacing.medium)
        .frame(height: 38)
        .background(FlotillaColors.surface)
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
                    .accessibilityLabel("Screenshot from \(screenshot.agent.displayName)")
                    .accessibilityIdentifier(AXID.agentScreenshotPanelImage.rawValue)

                HStack(spacing: FlotillaSpacing.small) {
                    Text("Sent by \(screenshot.agent.displayName) · \(screenshot.timestamp, style: .relative) ago")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button("Copy") { copy(screenshot) }
                    Button("Save…") { save(screenshot) }
                }
                .controlSize(.small)
            }
            .padding(FlotillaSpacing.medium)
        }
        .id(screenshot.id)
    }

    private func copy(_ screenshot: AgentScreenshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([screenshot.image])
    }

    private func save(_ screenshot: AgentScreenshot) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg]
        panel.nameFieldStringValue = "Screenshot.jpg"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? screenshot.data.write(to: url, options: .atomic)
    }
}
