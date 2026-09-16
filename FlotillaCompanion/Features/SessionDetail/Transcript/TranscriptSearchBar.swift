import SwiftUI
import DesignSystem

/// Find-in-transcript: a query field, a result count, and next/previous.
struct TranscriptSearchBar: View {
    @Binding var query: String
    let matchCount: Int
    let currentIndex: Int
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(FlotillaColors.textTertiary)
                TextField("Search transcript", text: $query)
                    .textFieldStyle(.plain)
                    .focused($isFocused)
                    .accessibilityIdentifier("Transcript.SearchField")
                if !query.isEmpty {
                    Text(matchCount == 0 ? "No results" : "\(currentIndex + 1) of \(matchCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .accessibilityIdentifier("Transcript.SearchCount")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(FlotillaColors.surfaceElevated, in: RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous))

            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Previous match")
                .accessibilityIdentifier("Transcript.SearchPrevious")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .disabled(matchCount == 0)
                .accessibilityLabel("Next match")
                .accessibilityIdentifier("Transcript.SearchNext")
            Button(action: onClose) { Image(systemName: "xmark") }
                .accessibilityLabel("Close search")
                .accessibilityIdentifier("Transcript.SearchClose")
        }
        .buttonStyle(.plain)
        .foregroundStyle(FlotillaColors.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
    }
}
