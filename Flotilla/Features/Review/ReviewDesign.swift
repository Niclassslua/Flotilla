import SwiftUI
import SessionKit
import DesignSystem

/// Four candidate designs for the session review window, switchable live from
/// a menu in every design's header so the whole surface can be compared side
/// by side before one is kept.
///
/// Exploration scaffolding: once a design is chosen the other three files and
/// this enum collapse to a single layout.
enum ReviewDesign: String, CaseIterable, Identifiable, Sendable {
    /// Calm and familiar: a flat file list and bordered diff cards.
    case editorial
    /// Code-editor focus: one file at a time, full-bleed diff, prev/next.
    case workbench
    /// Guided walkthrough: a numbered step rail and floating hunk cards.
    case timeline
    /// Dense command centre: a full stats header and a persistent action bar.
    case commandDeck

    var id: Self { self }

    static let `default`: ReviewDesign = .editorial
    static let storageKey = "review.designExploration"

    var title: String {
        switch self {
        case .editorial: "Editorial"
        case .workbench: "Workbench"
        case .timeline: "Timeline"
        case .commandDeck: "Command Deck"
        }
    }

    var blurb: String {
        switch self {
        case .editorial: "Calm, familiar, bordered diff cards"
        case .workbench: "One file at a time, code-editor focus"
        case .timeline: "Numbered step rail, floating hunk cards"
        case .commandDeck: "Dense stats header, persistent action bar"
        }
    }

    var systemImage: String {
        switch self {
        case .editorial: "doc.text"
        case .workbench: "sidebar.squares.left"
        case .timeline: "list.number"
        case .commandDeck: "square.grid.3x3.topleft.filled"
        }
    }
}

/// The live switcher. Rendered in every design's header, styled to sit
/// quietly at the trailing edge.
struct ReviewDesignMenu: View {
    @Binding var design: ReviewDesign

    var body: some View {
        Menu {
            Picker("Design", selection: $design) {
                ForEach(ReviewDesign.allCases) { option in
                    Label(option.title, systemImage: option.systemImage).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: "paintpalette")
                    .font(.system(size: FlotillaIconSize.xSmall, weight: .semibold))
                Text(design.title)
                    .font(FlotillaTypography.caption2.weight(.medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(FlotillaColors.textSecondary)
            .padding(.horizontal, FlotillaSpacing.small)
            .padding(.vertical, 5)
            .background(
                FlotillaColors.surface,
                in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .help("Switch review design")
        .accessibilityIdentifier("Review.DesignMenu")
    }
}

// MARK: - Diff canvas style

/// The knobs each design turns on the shared diff renderer
/// (``ReviewDiffPane`` / ``ReviewFileSection``). Everything about *how a hunk
/// is drawn* stays shared; this is only the container around it.
struct ReviewDiffStyle: Equatable {
    enum FileContainer: Equatable {
        /// Surface fill, card radius, hairline border. Today's look.
        case card
        /// Surface fill, panel radius, soft drop shadow, no border.
        case floating
        /// Surface fill, no radius, a hairline rule underneath.
        case plain
        /// No fill, no radius, no border — the diff meets the pane edges.
        case fullBleed
    }

    var outerPadding: CGFloat = FlotillaSpacing.large
    var sectionSpacing: CGFloat = FlotillaSpacing.large
    var fileContainer: FileContainer = .card
    var showHunkHeaders = true
    var stickyHeaders = true
    var canvas: Color = FlotillaColors.canvas

    static let standard = ReviewDiffStyle()

    static let editorial = ReviewDiffStyle(
        outerPadding: FlotillaSpacing.large,
        sectionSpacing: FlotillaSpacing.large,
        fileContainer: .card,
        showHunkHeaders: true,
        stickyHeaders: true,
        canvas: FlotillaColors.canvas
    )

    static let workbench = ReviewDiffStyle(
        outerPadding: 0,
        sectionSpacing: 0,
        fileContainer: .fullBleed,
        showHunkHeaders: true,
        stickyHeaders: false,
        canvas: FlotillaColors.canvas
    )

    static let timeline = ReviewDiffStyle(
        outerPadding: FlotillaSpacing.xLarge,
        sectionSpacing: FlotillaSpacing.xLarge,
        fileContainer: .floating,
        showHunkHeaders: true,
        stickyHeaders: false,
        canvas: FlotillaColors.sidebar
    )

    static let commandDeck = ReviewDiffStyle(
        outerPadding: FlotillaSpacing.small,
        sectionSpacing: FlotillaSpacing.small,
        fileContainer: .plain,
        showHunkHeaders: true,
        stickyHeaders: true,
        canvas: FlotillaColors.canvas
    )
}

// MARK: - Shared header pieces

/// A compact segmented control matching the review header's own, exposed so
/// the leaner designs can offer scope / mode / display switching without the
/// full ``ReviewHeaderBar``.
struct ReviewMiniControls: View {
    @Bindable var viewModel: SessionReviewViewModel
    var includeDisplay = true

    var body: some View {
        HStack(spacing: FlotillaSpacing.small) {
            Menu {
                Picker("Scope", selection: scopeBinding) {
                    ForEach(ReviewScope.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                pill(icon: "arrow.triangle.branch", text: viewModel.scope.displayName)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()

            Menu {
                Picker("Layout", selection: $viewModel.diffMode) {
                    ForEach(ReviewDiffMode.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                }
                if includeDisplay {
                    Picker("Files", selection: $viewModel.fileDisplay) {
                        ForEach(ReviewFileDisplay.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
                    }
                }
            } label: {
                pill(icon: viewModel.diffMode.systemImage, text: viewModel.diffMode.title)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
        }
    }

    private var scopeBinding: Binding<ReviewScope> {
        Binding(get: { viewModel.scope }, set: { scope in Task { await viewModel.setScope(scope) } })
    }

    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: FlotillaSpacing.xSmall) {
            Image(systemName: icon).font(.system(size: FlotillaIconSize.xSmall))
            Text(text).font(FlotillaTypography.caption2.weight(.medium))
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(FlotillaColors.textSecondary)
        .padding(.horizontal, FlotillaSpacing.small)
        .padding(.vertical, 5)
        .background(FlotillaColors.surface, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
        }
    }
}

/// The Send button, shared by the designs that don't use ``ReviewHeaderBar``.
struct ReviewSendButton: View {
    @Bindable var viewModel: SessionReviewViewModel
    let onSend: () -> Void
    var prominent = true

    var body: some View {
        Button(action: onSend) {
            HStack(spacing: FlotillaSpacing.xSmall) {
                Image(systemName: "paperplane.fill").font(.system(size: FlotillaIconSize.xSmall))
                Text("Send Review")
                if !viewModel.unsentComments.isEmpty {
                    Text("\(viewModel.unsentComments.count)")
                        .font(FlotillaTypography.caption3.weight(.bold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(FlotillaColors.accentContent.opacity(0.25), in: Capsule())
                }
            }
            .font(FlotillaTypography.caption.weight(.medium))
        }
        .buttonStyle(.borderedProminent)
        .tint(FlotillaColors.accent)
        .disabled(!viewModel.canSend)
        .help(viewModel.canSend ? "Send comments to an agent" : "No unsent comments")
        .accessibilityIdentifier(AXID.reviewSend.rawValue)
    }
}

/// A thin viewed-progress bar, reused by Editorial and Timeline.
struct ReviewProgressBar: View {
    let viewed: Int
    let total: Int
    var height: CGFloat = 4

    private var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(viewed) / Double(total)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(FlotillaColors.separator.opacity(0.6))
                Capsule()
                    .fill(FlotillaColors.statusReady)
                    .frame(width: max(0, geo.size.width * fraction))
            }
        }
        .frame(height: height)
        .animation(FlotillaMotion.normal.curve, value: fraction)
        .accessibilityIdentifier(AXID.reviewProgress.rawValue)
        .accessibilityLabel("\(viewed) of \(total) files viewed")
    }
}
