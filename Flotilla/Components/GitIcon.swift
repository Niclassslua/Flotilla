import SwiftUI
import DesignSystem

/// The canonical Git logo mark, rendered as a vector template asset that adapts to the UI color.
public struct GitIcon: View {
    public var size: CGFloat

    public init(size: CGFloat = FlotillaIconSize.small) {
        self.size = size
    }

    public var body: some View {
        Group {
            if NSImage(named: "GitLogo") != nil {
                Image("GitLogo")
                    .renderingMode(.template)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public struct GitLabel: View {
    public var title: String
    public var size: CGFloat

    public init(_ title: String, size: CGFloat = FlotillaIconSize.small) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        Label {
            Text(title)
        } icon: {
            GitIcon(size: size)
        }
    }
}

extension Image {
    /// The canonical Git logo icon.
    public static var gitLogo: Image {
        Image("GitLogo").renderingMode(.template)
    }
}
