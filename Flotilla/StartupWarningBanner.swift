import SwiftUI

/// Non-blocking startup warning for unavailable tools. Git and the selected
/// agent affect specific actions; tmux and gh are optional enhancements.
struct StartupWarningBanner: View {
    let missingTools: [String]
    @Binding var isDismissed: Bool

    var body: some View {
        if !missingTools.isEmpty && !isDismissed {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Some command-line tools are unavailable")
                        .fontWeight(.semibold)
                    Text(missingTools.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Missing command-line tools: \(missingTools.joined(separator: ", "))")
                        .accessibilityIdentifier("StartupWarningBanner")
                }
                .font(.callout)
                Spacer()
                Button("Dismiss") {
                    withAnimation(.easeOut(duration: 0.2)) {
                        isDismissed = true
                    }
                }
                .accessibilityIdentifier("StartupWarningBanner.DismissButton")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.15))
            // No container-level accessibilityIdentifier: it would
            // override the DismissButton's own identifier on macOS AX
            // (confirmed repeatedly — see memory). The text carries the
            // "banner exists" identifier instead.
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
