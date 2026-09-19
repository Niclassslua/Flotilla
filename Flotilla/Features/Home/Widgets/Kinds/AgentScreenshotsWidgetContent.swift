import SwiftUI
import DesignSystem

struct AgentScreenshotsWidgetContent: View {
    let size: HomeWidgetSize
    let shots: [HomeScreenshotFeed.Shot]
    var isLoading = false

    var body: some View {
        if isLoading && shots.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if shots.isEmpty {
            HomeWidgetAllClearState(message: "No screenshots yet")
        } else {
            switch size {
            case .medium:
                HStack(spacing: FlotillaSpacing.small) {
                    tile(shots[safe: 0])
                    tile(shots[safe: 1])
                }
            case .wide:
                HStack(spacing: FlotillaSpacing.small) {
                    ForEach(0..<4, id: \.self) { tile(shots[safe: $0]) }
                }
            default:
                Grid(horizontalSpacing: FlotillaSpacing.small, verticalSpacing: FlotillaSpacing.small) {
                    GridRow { tile(shots[safe: 0]); tile(shots[safe: 1]) }
                    GridRow { tile(shots[safe: 2]); tile(shots[safe: 3]) }
                }
            }
        }
    }

    @ViewBuilder
    private func tile(_ shot: HomeScreenshotFeed.Shot?) -> some View {
        let shape = RoundedRectangle(cornerRadius: FlotillaRadius.card, style: .continuous)
        ZStack(alignment: .bottomLeading) {
            Color.clear
                .overlay(alignment: .topLeading) {
                    if let shot {
                        Image(nsImage: shot.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        FlotillaColors.textPrimary.opacity(0.06)
                    }
                }
                .clipped()
            LinearGradient(colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
            if let shot {
                HStack(spacing: 4) {
                    ProviderLogo(agent: shot.agent).frame(width: 10, height: 10)
                    Text(shot.sessionTitle).font(.system(size: 10, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 2)
                    Text(HomeTimestamp.compact(shot.timestamp))
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .opacity(0.75)
                }
                .foregroundStyle(.white)
                .padding(6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
