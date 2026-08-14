import SwiftUI
import SessionKit
import DesignSystem

struct SessionRow: View {
    let session: Session

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 2)
                .fill(StatusPresentation.color(for: session.status))
                .frame(width: 3, height: 30)
            ZStack(alignment: .bottomTrailing) {
                ProviderLogo(agent: session.agent)
                    .frame(width: 18, height: 18)
                Circle()
                    .fill(StatusPresentation.color(for: session.status))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().strokeBorder(FlotillaPalette.sidebar, lineWidth: 1.5))
                    .offset(x: 3, y: 3)
            }
            .frame(width: 21, height: 21)
            .accessibilityLabel(StatusPresentation.label(for: session.status))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(session.agent.displayName) · \(StatusPresentation.label(for: session.status))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }
}
