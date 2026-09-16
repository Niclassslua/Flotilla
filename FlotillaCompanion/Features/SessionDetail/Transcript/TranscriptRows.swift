import SwiftUI
import UIKit
import ImageIO
import SessionKit
import DesignSystem
import Textual
import CompanionKit

struct UserMessageRow: View {
    let text: String
    var isQueued = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                Text(text)
                    .font(.body)
                    .foregroundStyle(isQueued ? FlotillaColors.textSecondary : FlotillaColors.textPrimary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(isQueued ? Color.clear : FlotillaColors.surfaceElevated)
                    )
                    .overlay {
                        if isQueued {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(FlotillaColors.separatorStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        }
                    }
                if isQueued {
                    Label("Queued", systemImage: "clock")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(FlotillaColors.textTertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AssistantMessageRow: View {
    let markdown: String

    var body: some View {
        StructuredText(markdown: markdown)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
            .font(.body)
            .foregroundStyle(FlotillaColors.textPrimary)
            .tint(FlotillaColors.statusReady)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Antigravity's stand-in for live text: the tail of the Mac's terminal,
/// replaced by the completed step.
struct TerminalTailPreview: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Live from the terminal", systemImage: "terminal")
                .font(.caption2.weight(.medium))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .padding(10)
        .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
    }
}

/// A screenshot the agent looked at. Decode off the UI actor, and reuse the
/// thumbnail when a lazy row is recycled while scrolling. Tapping it opens fullscreen with zoom.
struct ImageRow: View {
    let id: String
    let mimeType: String
    let base64: String
    @State private var thumbnail: UIImage?
    @State private var failed = false

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 30
        return cache
    }()

    /// Shown as a small preview inline in the chat, matching a chat
    /// attachment rather than filling the transcript column; full size is
    /// still one tap away in the fullscreen viewer.
    private static let maxThumbnailWidth: CGFloat = 110
    private static let maxThumbnailHeight: CGFloat = 130

    private struct Prepared: @unchecked Sendable {
        let image: UIImage?
    }

    @State private var isFullscreenPresented = false

    var body: some View {
        Group {
            if let thumbnail {
                Button {
                    isFullscreenPresented = true
                } label: {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: Self.maxThumbnailWidth, maxHeight: Self.maxThumbnailHeight)
                        .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
                                .strokeBorder(FlotillaColors.separator, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .fullScreenCover(isPresented: $isFullscreenPresented) {
                    FullscreenImageViewer(uiImage: thumbnail) {
                        isFullscreenPresented = false
                    }
                }
            } else if failed {
                Label("Image couldn't be shown", systemImage: "photo.badge.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(FlotillaColors.textTertiary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: id) {
            let key = id as NSString
            if let cached = Self.cache.object(forKey: key) {
                thumbnail = cached
                return
            }
            let prepared = await Task.detached(priority: .utility) { [base64] in
                let sourceOptions: [CFString: Any] = [kCGImageSourceShouldCache: false]
                guard let data = Data(base64Encoded: base64),
                      let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary) else {
                    return Prepared(image: nil)
                }
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 1600,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true
                ]
                return Prepared(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:)))
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = prepared.image
            failed = prepared.image == nil
            if let image = prepared.image { Self.cache.setObject(image, forKey: key) }
        }
    }
}

/// Fullscreen zoomable and pannable image viewer with native gesture support.
struct FullscreenImageViewer: View {
    let uiImage: UIImage
    let onDismiss: () -> Void

    @State private var showsControls = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            ZoomableScrollView(image: uiImage) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showsControls.toggle()
                }
            }
            .ignoresSafeArea()

            if showsControls {
                VStack {
                    HStack {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Close")

                        Spacer()

                        ShareLink(
                            item: Image(uiImage: uiImage),
                            preview: SharePreview("Screenshot", image: Image(uiImage: uiImage))
                        ) {
                            Image(systemName: "square.and.arrow.up")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 36, height: 36)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Share image")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                    Spacer()
                }
                .transition(.opacity)
            }
        }
    }
}

private struct ZoomableScrollView: UIViewRepresentable {
    let image: UIImage
    var onSingleTap: (() -> Void)? = nil

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.maximumZoomScale = 5.0
        scrollView.minimumZoomScale = 1.0
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(imageView)
        context.coordinator.imageView = imageView

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor),
        ])

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleSingleTap(_:)))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        return scrollView
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.onSingleTap = onSingleTap
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        var onSingleTap: (() -> Void)?

        init(onSingleTap: (() -> Void)?) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleSingleTap(_ gesture: UITapGestureRecognizer) {
            onSingleTap?()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scrollView = gesture.view as? UIScrollView else { return }
            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            } else {
                let location = gesture.location(in: scrollView)
                let zoomRect = CGRect(
                    x: location.x - (scrollView.bounds.width / 4),
                    y: location.y - (scrollView.bounds.height / 4),
                    width: scrollView.bounds.width / 2,
                    height: scrollView.bounds.height / 2
                )
                scrollView.zoom(to: zoomRect, animated: true)
            }
        }
    }
}

/// Consecutive tool calls between two messages. A single call renders as its
/// own row; several collapse into `Ran 7 tools`.
struct ToolGroupRow: View {
    let sessionID: CompanionSession.ID
    let calls: [ToolCall]
    @Binding var isExpanded: Bool

    var body: some View {
        if calls.count == 1, let call = calls.first {
            ToolCallRow(sessionID: sessionID, call: call)
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Button {
                    withAnimation(.snappy) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        Text(title)
                        if calls.contains(where: \.isError) {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(FlotillaColors.danger)
                        }
                        Spacer()
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(FlotillaColors.textSecondary)
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(calls) { ToolCallRow(sessionID: sessionID, call: $0) }
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(FlotillaColors.separator).frame(width: 1)
                    }
                }
            }
        }
    }

    private var title: String {
        let running = calls.contains(where: \.isRunning)
        return running ? "Running tools · \(calls.count)" : "Ran \(calls.count) tools"
    }
}

struct ToolCallRow: View {
    let sessionID: CompanionSession.ID
    let call: ToolCall
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: call.systemImage)
                        .font(.caption)
                        .frame(width: 16)
                        .foregroundStyle(FlotillaColors.textTertiary)
                    Text(call.summary)
                        .font(.footnote.monospaced())
                        .foregroundStyle(FlotillaColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    resultBadge
                }
                .contentShape(Rectangle())
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows the tool's input and output")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !call.input.isEmpty {
                        detailBlock("Input", call.input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n"))
                    }
                    if let output = call.output, !output.isEmpty {
                        detailBlock("Output", output, isError: call.isError)
                    }
                    if let path = call.filePath {
                        HStack(spacing: 8) {
                            NavigationLink("View File", value: Route.file(sessionID, path: path))
                            if call.isEdit {
                                NavigationLink("View Diff", value: Route.diff(sessionID, commitHash: nil, focusPath: path))
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.leading, 24)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var resultBadge: some View {
        if call.isRunning {
            ProgressView().controlSize(.mini)
        } else if call.isError {
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(FlotillaColors.danger)
                .accessibilityLabel("Failed")
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(FlotillaColors.success.opacity(0.8))
                .accessibilityLabel("Succeeded")
        }
    }

    private func detailBlock(_ title: String, _ text: String, isError: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(isError ? FlotillaColors.danger : FlotillaColors.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        }
    }
}

struct ResolvedInteractionRow: View {
    let text: String
    let isPositive: Bool

    var body: some View {
        Label {
            Text(text).lineLimit(2)
        } icon: {
            Image(systemName: isPositive ? "checkmark.shield" : "xmark.shield")
                .foregroundStyle(isPositive ? FlotillaColors.success : FlotillaColors.textTertiary)
        }
        .font(.footnote)
        .foregroundStyle(FlotillaColors.textSecondary)
    }
}

struct TurnFailedRow: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(FlotillaColors.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(FlotillaColors.dangerSurface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
    }
}

struct SystemNoteRow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FlotillaColors.textTertiary)
            .frame(maxWidth: .infinity)
    }
}

struct HandoffRow: View {
    let from: AgentKind
    let to: AgentKind

    var body: some View {
        HStack(spacing: 6) {
            ProviderLogo(agent: from).frame(width: 14, height: 14)
            Image(systemName: "arrow.right").font(.caption2)
            ProviderLogo(agent: to).frame(width: 14, height: 14)
            Text("Handed off to \(to.displayName)")
        }
        .font(.caption)
        .foregroundStyle(FlotillaColors.textTertiary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The pulsing last row while the agent works: the in-flight tool and its
/// elapsed time, a retry warning, or Stopping….
struct WorkingIndicator: View {
    let inFlight: ToolCall?
    let retryAttempt: Int?
    let isStopping: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                if retryAttempt != nil {
                    Image(systemName: "exclamationmark.arrow.triangle.2.circlepath")
                        .foregroundStyle(FlotillaColors.warning)
                } else {
                    StatusDot(status: .working, size: 8)
                }
                Text(label(now: context.date))
                    .foregroundStyle(retryAttempt != nil ? FlotillaColors.warning : FlotillaColors.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.footnote)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func label(now: Date) -> String {
        if isStopping { return "Stopping…" }
        if let retryAttempt { return "Retrying · attempt \(retryAttempt)" }
        guard let inFlight else { return "Working…" }
        let elapsed = Int(max(0, now.timeIntervalSince(inFlight.startedAt)))
        return "Running \(inFlight.subject ?? inFlight.tool)… \(elapsed / 60):\(String(format: "%02d", elapsed % 60))"
    }
}
