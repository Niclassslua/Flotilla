import SwiftUI
import DesignSystem

/// An interactive native SwiftUI square cropper for project icons.
///
/// Features pan and pinch gestures, zoom slider, reset button,
/// squircle guide matching `ProjectMark` curvature, and real-time
/// side-by-side previews at sidebar and card sizes.
struct ProjectIconCropperView: View {
    let sourceImage: NSImage
    let onChooseAnotherFile: () -> Void
    let onCancel: () -> Void
    let onApply: (Data) -> Void

    private let viewportSize: CGFloat = 280
    private var cornerRadius: CGFloat { viewportSize * 5 / 17 }

    @State private var zoom: CGFloat = 1.0
    @State private var steadyZoom: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var isExporting = false

    private var baseScale: CGFloat {
        guard sourceImage.size.width > 0, sourceImage.size.height > 0 else { return 1.0 }
        return max(viewportSize / sourceImage.size.width, viewportSize / sourceImage.size.height)
    }

    private var effectiveZoom: CGFloat {
        max(0.4, min(4.0, zoom))
    }

    private var totalScale: CGFloat {
        baseScale * effectiveZoom
    }

    private var drawnWidth: CGFloat {
        sourceImage.size.width * totalScale
    }

    private var drawnHeight: CGFloat {
        sourceImage.size.height * totalScale
    }

    private var maxDragX: CGFloat {
        max(40, abs(drawnWidth - viewportSize) / 2)
    }

    private var maxDragY: CGFloat {
        max(40, abs(drawnHeight - viewportSize) / 2)
    }

    var body: some View {
        VStack(spacing: FlotillaSpacing.large) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Crop Project Icon")
                        .font(FlotillaTypography.headline)
                        .foregroundStyle(FlotillaColors.textPrimary)
                    Text("Drag to reposition, pinch or use the slider to zoom.")
                        .font(FlotillaTypography.caption)
                        .foregroundStyle(FlotillaColors.textSecondary)
                }
                Spacer()
                Button("Choose Another File", action: onChooseAnotherFile)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.accent)
            }

            // Main crop area + side preview
            HStack(alignment: .top, spacing: FlotillaSpacing.xLarge) {
                // Interactive Viewport
                VStack(spacing: FlotillaSpacing.medium) {
                    cropCanvas
                        .frame(width: viewportSize, height: viewportSize)
                        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.panel, style: .continuous)
                                .strokeBorder(FlotillaColors.separatorStrong, lineWidth: 1)
                        }

                    // Zoom Controls
                    HStack(spacing: FlotillaSpacing.medium) {
                        Image(systemName: "minus.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textTertiary)

                        Slider(value: Binding(
                            get: { effectiveZoom },
                            set: { newZoom in
                                zoom = newZoom
                                clampOffset()
                            }
                        ), in: 0.4...4.0)
                        .tint(FlotillaColors.accent)

                        Image(systemName: "plus.magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(FlotillaColors.textTertiary)

                        Button("Reset") {
                            withAnimation(.spring(duration: 0.25)) {
                                zoom = 1.0
                                steadyZoom = 1.0
                                offset = .zero
                            }
                        }
                        .buttonStyle(.plain)
                        .font(FlotillaTypography.caption2.weight(.medium))
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(FlotillaColors.surfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
                    }
                    .frame(width: viewportSize)
                }

                // Previews column
                VStack(alignment: .leading, spacing: FlotillaSpacing.large) {
                    Text("Preview")
                        .font(FlotillaTypography.caption.weight(.semibold))
                        .foregroundStyle(FlotillaColors.textSecondary)

                    VStack(alignment: .leading, spacing: FlotillaSpacing.medium) {
                        HStack(spacing: FlotillaSpacing.medium) {
                            livePreview(size: 38)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Card")
                                    .font(FlotillaTypography.caption.weight(.medium))
                                    .foregroundStyle(FlotillaColors.textPrimary)
                                Text("38×38")
                                    .font(FlotillaTypography.caption3.monospaced())
                                    .foregroundStyle(FlotillaColors.textTertiary)
                            }
                        }

                        HStack(spacing: FlotillaSpacing.medium) {
                            livePreview(size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sidebar")
                                    .font(FlotillaTypography.caption.weight(.medium))
                                    .foregroundStyle(FlotillaColors.textPrimary)
                                Text("18×18")
                                    .font(FlotillaTypography.caption3.monospaced())
                                    .foregroundStyle(FlotillaColors.textTertiary)
                            }
                        }
                    }
                    .padding(FlotillaSpacing.medium)
                    .background(FlotillaColors.surface)
                    .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                            .strokeBorder(FlotillaColors.separator, lineWidth: 1)
                    }

                    Spacer()
                }
                .frame(width: 140)
            }

            // Footer action buttons
            HStack {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption.weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .padding(.horizontal, FlotillaSpacing.large)
                    .padding(.vertical, FlotillaSpacing.small)
                    .background(FlotillaColors.surfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))

                Spacer()

                Button {
                    applyCrop()
                } label: {
                    if isExporting {
                        ProgressView()
                            .scaleEffect(0.7)
                            .frame(width: 60)
                    } else {
                        Text("Apply Icon")
                            .font(FlotillaTypography.caption.weight(.semibold))
                            .foregroundStyle(FlotillaColors.accentContent)
                            .padding(.horizontal, FlotillaSpacing.large + 4)
                            .padding(.vertical, FlotillaSpacing.small)
                    }
                }
                .buttonStyle(.plain)
                .background(FlotillaColors.accent)
                .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                .disabled(isExporting)
            }
        }
        .padding(FlotillaSpacing.large)
        .background(FlotillaColors.canvas)
    }

    // MARK: - Crop Canvas

    private var cropCanvas: some View {
        ZStack {
            // Dark checkerboard background for transparent icons
            checkerboardBackground

            // Scaled and positioned image
            Image(nsImage: sourceImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: drawnWidth, height: drawnHeight)
                .offset(offset)
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            let rawX = dragStartOffset.width + value.translation.width
                            let rawY = dragStartOffset.height + value.translation.height
                            offset = CGSize(
                                width: max(-maxDragX, min(maxDragX, rawX)),
                                height: max(-maxDragY, min(maxDragY, rawY))
                            )
                        }
                        .onEnded { _ in
                            dragStartOffset = offset
                        }
                )
                .gesture(
                    MagnificationGesture()
                        .onChanged { value in
                            zoom = max(0.4, min(4.0, steadyZoom * value))
                            clampOffset()
                        }
                        .onEnded { _ in
                            steadyZoom = zoom
                        }
                )

            // Outer darkened frame masking the squircle
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.8), lineWidth: 1.5)
                .shadow(color: Color.black.opacity(0.4), radius: 2)

            // Corner guidelines
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(FlotillaColors.accent.opacity(0.4), lineWidth: 0.5)
        }
    }

    // MARK: - Live Preview

    private func livePreview(size: CGFloat) -> some View {
        let factor = size / viewportSize
        let cornerRad = size * 5 / 17

        return ZStack {
            checkerboardBackground
                .frame(width: size, height: size)

            Image(nsImage: sourceImage)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: drawnWidth * factor, height: drawnHeight * factor)
                .offset(x: offset.width * factor, y: offset.height * factor)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRad, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRad, style: .continuous)
                .strokeBorder(FlotillaColors.separatorStrong, lineWidth: 0.5)
        }
    }

    private var checkerboardBackground: some View {
        ZStack {
            Color(red: 0.12, green: 0.12, blue: 0.14)
            GeometryReader { proxy in
                Path { path in
                    let step: CGFloat = 10
                    for x in stride(from: 0, to: proxy.size.width, by: step * 2) {
                        for y in stride(from: 0, to: proxy.size.height, by: step * 2) {
                            path.addRect(CGRect(x: x, y: y, width: step, height: step))
                            path.addRect(CGRect(x: x + step, y: y + step, width: step, height: step))
                        }
                    }
                }
                .fill(Color(red: 0.16, green: 0.16, blue: 0.19))
            }
        }
    }

    private func clampOffset() {
        offset = CGSize(
            width: max(-maxDragX, min(maxDragX, offset.width)),
            height: max(-maxDragY, min(maxDragY, offset.height))
        )
        dragStartOffset = offset
    }

    private func applyCrop() {
        isExporting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let pngData = ProjectIconCropRenderer.render(
                image: sourceImage,
                viewportSize: viewportSize,
                zoom: effectiveZoom,
                offset: offset
            )
            DispatchQueue.main.async {
                isExporting = false
                if let pngData {
                    onApply(pngData)
                }
            }
        }
    }
}
