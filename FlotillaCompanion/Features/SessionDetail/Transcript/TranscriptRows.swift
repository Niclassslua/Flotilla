import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#elseif canImport(AppKit)
import AppKit
typealias PlatformImage = NSImage
#endif
extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #elseif canImport(AppKit)
        self.init(nsImage: platformImage)
        #endif
    }
}
import ImageIO
import SessionKit
import DesignSystem
import Textual
import CompanionKit

struct UserMessageRow: View, @preconcurrency Equatable {
    let text: String
    var isQueued = false

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.isQueued == rhs.isQueued
    }

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
                            .fill(bubbleFill)
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

    private var bubbleFill: Color {
        guard !isQueued else { return .clear }
        return FlotillaColors.accent.opacity(0.14)
    }
}

struct AssistantMessageRow: View, @preconcurrency Equatable {
    let markdown: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.markdown == rhs.markdown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownCodeFence.segments(in: markdown).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .prose(let text):
                    structuredText(text)
                case .code(let language, let code):
                    CodeBlockView(language: language, code: code)
                }
            }
        }
        .font(.body)
        .foregroundStyle(FlotillaColors.textPrimary)
        .tint(FlotillaColors.statusReady)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func structuredText(_ text: String) -> some View {
        StructuredText(markdown: text)
            .textual.structuredTextStyle(.gitHub)
            .textual.textSelection(.enabled)
    }
}

/// Splits a message's markdown into prose and fenced code segments, so code
/// segments can get a header the default `.gitHub`
/// code block style doesn't offer — `StructuredText`'s per-block style
/// customization hooks (`.textual.codeBlockStyle(_:)`) didn't take effect in
/// this app despite matching the documented usage, so this sidesteps that
/// API rather than depend on it.
enum MarkdownCodeFence {
    enum Segment {
        case prose(String)
        case code(language: String?, code: String)
    }

    static func segments(in markdown: String) -> [Segment] {
        var result: [Segment] = []
        var prose: [Substring] = []
        var lines = markdown.split(separator: "\n", omittingEmptySubsequences: false)[...]

        func flushProse() {
            let text = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { result.append(.prose(text)) }
            prose = []
        }

        while let line = lines.first {
            lines = lines.dropFirst()
            if let fenceStart = line.range(of: "```"), line[..<fenceStart.lowerBound].allSatisfy(\.isWhitespace) {
                flushProse()
                let language = line[fenceStart.upperBound...].trimmingCharacters(in: .whitespaces)
                var code: [Substring] = []
                while let codeLine = lines.first {
                    lines = lines.dropFirst()
                    if codeLine.trimmingCharacters(in: .whitespaces) == "```" { break }
                    code.append(codeLine)
                }
                result.append(.code(language: language.isEmpty ? nil : language, code: code.joined(separator: "\n")))
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return result
    }
}

/// A language badge and Copy button above the code.
/// Reuses `.gitHub`'s code block rendering (syntax highlighting included)
/// for the code itself, nested one level down — see `MarkdownCodeFence`.
private struct CodeBlockView: View {
    let language: String?
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text((language ?? "code").uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FlotillaColors.textTertiary)
                Spacer()
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = code
                    #elseif canImport(AppKit)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    #endif
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(FlotillaColors.textTertiary)
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            StructuredText(markdown: "```\(language ?? "")\n\(code)\n```")
                .textual.structuredTextStyle(.gitHub)
        }
        .background(FlotillaColors.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    @State private var thumbnail: PlatformImage?
    @State private var failed = false

    private static let cache: NSCache<NSString, PlatformImage> = {
        let cache = NSCache<NSString, PlatformImage>()
        cache.countLimit = 30
        return cache
    }()

    /// Shown as a small preview inline in the chat, matching a chat
    /// attachment rather than filling the transcript column; full size is
    /// still one tap away in the fullscreen viewer.
    private static let maxThumbnailWidth: CGFloat = 110
    private static let maxThumbnailHeight: CGFloat = 130

    private struct Prepared: @unchecked Sendable {
        let image: PlatformImage?
    }

    @State private var isFullscreenPresented = false

    var body: some View {
        Group {
            if let thumbnail {
                Button {
                    isFullscreenPresented = true
                } label: {
                    Image(platformImage: thumbnail)
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
                ProgressView().frame(maxWidth: .infinity, minHeight: Self.maxThumbnailHeight)
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
                #if canImport(UIKit)
                return Prepared(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:)))
                #elseif canImport(AppKit)
                return Prepared(image: CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { NSImage(cgImage: $0, size: .zero) })
                #endif
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
    let uiImage: PlatformImage
    let onDismiss: () -> Void

    @State private var showsControls = true

    private var shareImage: Image {
        #if canImport(UIKit)
        Image(uiImage: uiImage)
        #elseif canImport(AppKit)
        Image(nsImage: uiImage)
        #endif
    }

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
                            item: shareImage,
                            preview: SharePreview("Screenshot", image: shareImage)
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

#if canImport(UIKit)
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
#else
private struct ZoomableScrollView: View {
    let image: PlatformImage
    var onSingleTap: (() -> Void)? = nil

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .onTapGesture { onSingleTap?() }
    }
}
#endif

/// Consecutive tool calls between two messages. A single call renders as its
/// own row; several collapse into `Ran 7 tools`.
struct ToolGroupRow: View {
    let sessionID: CompanionSession.ID
    let calls: [ToolCall]
    @Binding var isExpanded: Bool

    var body: some View {
        Group {
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
                            if !isExpanded {
                                toolChips
                            } else {
                                Text(title)
                                if calls.contains(where: \.isError) {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(FlotillaColors.danger)
                                }
                                Spacer()
                            }
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
        .modifier(HapticsOnChange(value: isExpanded, feedback: .impact(weight: .light)))
    }

    private var title: String {
        let running = calls.contains(where: \.isRunning)
        return running ? "Running tools · \(calls.count)" : "Ran \(calls.count) tools"
    }

    /// The collapsed header is a scrolling row of what each call touched,
    /// instead of just a count.
    private var toolChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(calls) { call in
                    Text(call.subject ?? call.displayName)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(FlotillaColors.surfaceElevated, in: Capsule())
                        .opacity(call.isError ? 1 : (call.isRunning ? 0.6 : 0.85))
                }
            }
        }
        .scrollClipDisabled()
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
                        .accessibilityLabel(call.summary)
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
        .modifier(HapticsOnChange(value: isExpanded, feedback: .impact(weight: .light)))
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

struct ResolvedInteractionRow: View, @preconcurrency Equatable {
    let text: String
    let isPositive: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.isPositive == rhs.isPositive
    }

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

struct TurnFailedRow: View, @preconcurrency Equatable {
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.message == rhs.message
    }

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.medium))
            .foregroundStyle(FlotillaColors.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(FlotillaColors.dangerSurface, in: RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous))
    }
}

struct SystemNoteRow: View, @preconcurrency Equatable {
    let text: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(FlotillaColors.textTertiary)
            .frame(maxWidth: .infinity)
    }
}

struct HandoffRow: View, @preconcurrency Equatable {
    let from: AgentKind
    let to: AgentKind

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.from == rhs.from && lhs.to == rhs.to
    }

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
