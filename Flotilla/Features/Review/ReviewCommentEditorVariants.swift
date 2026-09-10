import SwiftUI
import DesignSystem

/// Four candidate looks for the inline comment composer, switchable live from
/// a small brush menu in the composer's top-right corner so they can be
/// compared in place before one is kept.
///
/// Exploration scaffolding: once a variant is chosen the others and this enum
/// collapse to a single ``ReviewCommentEditor`` body.
enum ReviewCommentEditorVariant: String, CaseIterable, Identifiable, Sendable {
    /// A chat input: a rounded field with a circular send button.
    case messenger
    /// Monospace, styled like a code annotation with keycap hints.
    case terminal
    /// A tilted paper card with a folded corner and a soft shadow.
    case stickyNote
    /// Frameless: a single underlined line that glows on focus.
    case commandBar

    var id: Self { self }

    static let `default`: ReviewCommentEditorVariant = .messenger
    static let storageKey = "review.commentEditorVariant"

    var title: String {
        switch self {
        case .messenger: "Messenger"
        case .terminal: "Terminal"
        case .stickyNote: "Sticky note"
        case .commandBar: "Command bar"
        }
    }

    var icon: String {
        switch self {
        case .messenger: "bubble.right"
        case .terminal: "chevron.left.forwardslash.chevron.right"
        case .stickyNote: "note.text"
        case .commandBar: "command"
        }
    }
}

/// The live switcher, dropped into every variant's top-trailing corner.
struct ReviewCommentVariantMenu: View {
    @Binding var selection: ReviewCommentEditorVariant

    var body: some View {
        Menu {
            Picker("Comment box style", selection: $selection) {
                ForEach(ReviewCommentEditorVariant.allCases) { option in
                    Label(option.title, systemImage: option.icon).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "paintbrush.pointed.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textSecondary)
                .frame(width: 20, height: 20)
                .background(FlotillaColors.surface, in: Circle())
                .overlay { Circle().strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline) }
                .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Switch comment box style")
        .accessibilityIdentifier("Review.CommentVariantMenu")
    }
}

// MARK: - Shared helpers

private func canSubmit(_ text: String) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// A borderless `TextEditor` with a top-leading placeholder, sized to grow
/// from `minHeight` to `maxHeight`.
private struct PlaceholderEditor: View {
    @Binding var text: String
    let placeholder: String
    var font: Font = FlotillaTypography.caption
    var minHeight: CGFloat = 40
    var maxHeight: CGFloat = 130
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(font)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .padding(.leading, 5)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .font(font)
                .foregroundStyle(FlotillaColors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(.clear)
                .focused($isFocused)
                .accessibilityIdentifier(AXID.reviewCommentEditor.rawValue)
        }
        .frame(minHeight: minHeight, maxHeight: maxHeight)
    }
}

// MARK: - Variant 1 · Messenger

struct ReviewCommentEditorMessenger: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text(title)
                .font(FlotillaTypography.caption3.weight(.medium))
                .foregroundStyle(FlotillaColors.textTertiary)
                .padding(.horizontal, FlotillaSpacing.small)
                .padding(.vertical, 2)
                .background(FlotillaColors.surfaceElevated, in: Capsule())
                .padding(.leading, FlotillaSpacing.small)

            HStack(alignment: .bottom, spacing: FlotillaSpacing.small) {
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .frame(width: 30, height: 30)
                        .background(FlotillaColors.surfaceElevated, in: Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)

                PlaceholderEditor(
                    text: $text,
                    placeholder: "Message…",
                    minHeight: 22,
                    maxHeight: 110,
                    isFocused: $isFocused
                )
                .padding(.horizontal, FlotillaSpacing.medium)
                .padding(.vertical, 6)
                .background(
                    FlotillaColors.surfaceElevated,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(
                            isFocused ? FlotillaColors.accent.opacity(0.6) : FlotillaColors.separator,
                            lineWidth: isFocused ? 1 : FlotillaBorderWidth.hairline
                        )
                }

                Button(action: onSubmit) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(FlotillaColors.accentContent)
                        .frame(width: 30, height: 30)
                        .background(
                            canSubmit(text) ? FlotillaColors.accent : FlotillaColors.accent.opacity(0.35),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit(text))
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
            }
        }
        .animation(FlotillaMotion.fast.curve, value: isFocused)
        .onAppear { isFocused = true }
    }
}

// MARK: - Variant 2 · Terminal

struct ReviewCommentEditorTerminal: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text("// \(title.lowercased())")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(FlotillaColors.statusWorking)

            HStack(alignment: .top, spacing: FlotillaSpacing.xSmall) {
                Text(">")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.accent)
                    .padding(.top, 8)

                PlaceholderEditor(
                    text: $text,
                    placeholder: "type a note, then ⏎",
                    font: .system(size: 12, design: .monospaced),
                    minHeight: 24,
                    maxHeight: 130,
                    isFocused: $isFocused
                )
            }
            .padding(FlotillaSpacing.small)
            .background(FlotillaColors.canvas, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(isFocused ? FlotillaColors.accent : FlotillaColors.separatorStrong)
                    .frame(width: 2)
            }
            .clipShape(RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                    .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
            }

            HStack(spacing: FlotillaSpacing.xSmall) {
                keycap("⏎", "submit", tint: canSubmit(text) ? FlotillaColors.accent : nil, action: onSubmit)
                    .disabled(!canSubmit(text))
                    .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
                    .keyboardShortcut(.return, modifiers: .command)
                keycap("esc", "cancel", tint: nil, action: onCancel)
                    .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)
                    .keyboardShortcut(.cancelAction)
                Spacer(minLength: 0)
            }
        }
        .animation(FlotillaMotion.fast.curve, value: isFocused)
        .onAppear { isFocused = true }
    }

    private func keycap(_ key: String, _ label: String, tint: Color?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(key)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        (tint ?? FlotillaColors.surfaceElevated),
                        in: RoundedRectangle(cornerRadius: 3, style: .continuous)
                    )
                    .foregroundStyle(tint == nil ? FlotillaColors.textSecondary : FlotillaColors.accentContent)
                Text(label)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Variant 3 · Sticky note

struct ReviewCommentEditorStickyNote: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    private let paper = Color(red: 0.99, green: 0.87, blue: 0.42)

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Label(title, systemImage: "pin.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.black.opacity(0.55))

            PlaceholderEditor(
                text: $text,
                placeholder: "Jot a note…",
                font: .system(size: 13, design: .rounded),
                minHeight: 46,
                maxHeight: 150,
                isFocused: $isFocused
            )
            .tint(.black)
            .environment(\.colorScheme, .light)

            HStack(spacing: FlotillaSpacing.medium) {
                Spacer(minLength: 0)
                Button("Discard", action: onCancel)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.black.opacity(0.45))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)
                Button("Stick it →", action: onSubmit)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(canSubmit(text) ? .black.opacity(0.8) : .black.opacity(0.3))
                    .disabled(!canSubmit(text))
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
            }
        }
        .padding(FlotillaSpacing.medium)
        .background {
            ZStack(alignment: .topTrailing) {
                Rectangle().fill(paper)
                // Folded corner.
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 16, y: 0))
                    path.addLine(to: CGPoint(x: 16, y: 16))
                    path.closeSubpath()
                }
                .fill(.black.opacity(0.16))
                .frame(width: 16, height: 16)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .shadow(color: .black.opacity(0.32), radius: 12, x: 0, y: 7)
        .rotationEffect(.degrees(-1.5))
        .onAppear { isFocused = true }
    }
}

// MARK: - Variant 4 · Command bar

struct ReviewCommentEditorCommandBar: View {
    let title: String
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: FlotillaSpacing.xSmall) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(FlotillaTypography.Tracking.loose)
                .foregroundStyle(FlotillaColors.textTertiary)

            HStack(alignment: .top, spacing: FlotillaSpacing.small) {
                Image(systemName: "text.append")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isFocused ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    .padding(.top, 7)

                PlaceholderEditor(
                    text: $text,
                    placeholder: "Add a comment — ⌘↩ to save, esc to dismiss",
                    minHeight: 24,
                    maxHeight: 130,
                    isFocused: $isFocused
                )
            }
            .padding(.bottom, 6)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(isFocused ? FlotillaColors.accent : FlotillaColors.separator)
                    .frame(height: isFocused ? 1.5 : FlotillaBorderWidth.hairline)
                    .shadow(color: isFocused ? FlotillaColors.accent.opacity(0.55) : .clear, radius: 4, y: 1)
            }

            HStack(spacing: FlotillaSpacing.medium) {
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption2)
                    .foregroundStyle(FlotillaColors.textTertiary)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AXID.reviewCommentCancel.rawValue)
                Button("Comment", action: onSubmit)
                    .buttonStyle(.plain)
                    .font(FlotillaTypography.caption2.weight(.semibold))
                    .foregroundStyle(canSubmit(text) ? FlotillaColors.accent : FlotillaColors.textTertiary)
                    .disabled(!canSubmit(text))
                    .keyboardShortcut(.return, modifiers: .command)
                    .accessibilityIdentifier(AXID.reviewCommentSubmit.rawValue)
            }
            .opacity(isFocused || canSubmit(text) ? 1 : 0)
        }
        .animation(FlotillaMotion.fast.curve, value: isFocused)
        .animation(FlotillaMotion.fast.curve, value: canSubmit(text))
        .onAppear { isFocused = true }
    }
}
