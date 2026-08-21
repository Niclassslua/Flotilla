import SwiftUI

/// A single-line text view that smoothly marquees back and forth when active/hovered
/// if the text content exceeds the available container width.
public struct MarqueeText: View {
    private let text: String
    private let font: Font
    private let color: Color
    private let isHovered: Bool
    private let truncationMode: Text.TruncationMode
    private let speed: Double

    @State private var containerWidth: CGFloat = 0
    @State private var textWidth: CGFloat = 0
    @State private var scrollOffset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    @Environment(\.flotillaReduceMotion) private var flotillaReduceMotion
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var shouldReduceMotion: Bool {
        flotillaReduceMotion || systemReduceMotion
    }

    private var overflow: CGFloat {
        max(0, textWidth - containerWidth)
    }

    private var isMarqueeActive: Bool {
        isHovered && overflow > 4 && !shouldReduceMotion
    }

    public init(
        _ text: String,
        font: Font = .body,
        color: Color = .primary,
        isHovered: Bool = false,
        truncationMode: Text.TruncationMode = .middle,
        speed: Double = 36
    ) {
        self.text = text
        self.font = font
        self.color = color
        self.isHovered = isHovered
        self.truncationMode = truncationMode
        self.speed = speed
    }

    public var body: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .truncationMode(truncationMode)
            .foregroundStyle(color)
            .opacity(isMarqueeActive ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                if isMarqueeActive {
                    Text(text)
                        .font(font)
                        .foregroundStyle(color)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: true)
                        .offset(x: scrollOffset)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                }
            }
            .clipped()
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
                if abs(containerWidth - newWidth) > 0.5 {
                    containerWidth = newWidth
                }
            }
            .background {
                Text(text)
                    .font(font)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { newWidth in
                        if abs(textWidth - newWidth) > 0.5 {
                            textWidth = newWidth
                        }
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .help(text)
            .onAppear {
                if isHovered {
                    updateAnimation(hovered: true)
                }
            }
            .onChange(of: isHovered) { _, newValue in
                updateAnimation(hovered: newValue)
            }
            .onChange(of: overflow) { _, _ in
                if isHovered {
                    updateAnimation(hovered: true)
                }
            }
            .onChange(of: text) { _, _ in
                if isHovered {
                    updateAnimation(hovered: true)
                }
            }
            .onDisappear {
                cancelAnimation()
            }
    }

    private func cancelAnimation() {
        animationTask?.cancel()
        animationTask = nil
        scrollOffset = 0
    }

    private func updateAnimation(hovered: Bool) {
        animationTask?.cancel()
        animationTask = nil

        guard hovered, overflow > 4, !shouldReduceMotion else {
            withAnimation(.easeOut(duration: 0.2)) {
                scrollOffset = 0
            }
            return
        }

        let currentOverflow = overflow
        let ptsPerSec = max(speed, 10)
        let scrollDuration = max(1.2, Double(currentOverflow) / ptsPerSec)

        animationTask = Task { @MainActor in
            // Initial pause so the user can read the start of the path
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            while !Task.isCancelled {
                // Scroll from start (0) to end (-overflow)
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    scrollOffset = -currentOverflow
                }
                try? await Task.sleep(for: .seconds(scrollDuration))
                guard !Task.isCancelled else { break }

                // Pause at end so the user can read the project/folder name
                try? await Task.sleep(for: .milliseconds(1000))
                guard !Task.isCancelled else { break }

                // Scroll back to the start
                withAnimation(.easeInOut(duration: scrollDuration)) {
                    scrollOffset = 0
                }
                try? await Task.sleep(for: .seconds(scrollDuration))
                guard !Task.isCancelled else { break }

                // Pause at the start before repeating
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled else { break }
            }
        }
    }
}
