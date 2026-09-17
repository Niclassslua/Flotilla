import SwiftUI
import DesignSystem
import SessionKit

/// The canonical Git branch mark (Octicon `git-branch`), rendered as a vector template asset
/// rather than Apple's generic three-way fork SF Symbol `arrow.triangle.branch`.
public struct GitBranchIcon: View {
    public var size: CGFloat

    public init(size: CGFloat = FlotillaIconSize.small) {
        self.size = size
    }

    public var body: some View {
        Group {
            if NSImage(named: "GitBranch") != nil {
                Image("GitBranch")
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

public struct GitBranchLabel: View {
    public var title: String
    public var size: CGFloat

    public init(_ title: String, size: CGFloat = FlotillaIconSize.small) {
        self.title = title
        self.size = size
    }

    public var body: some View {
        Label {
            Text(BranchNaming.displayName(for: title))
        } icon: {
            GitBranchIcon(size: size)
        }
    }
}

extension Image {
    /// The canonical Git branch icon.
    public static var gitBranch: Image {
        Image("GitBranch").renderingMode(.template)
    }
}
