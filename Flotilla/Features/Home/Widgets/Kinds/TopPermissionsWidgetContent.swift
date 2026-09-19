import SwiftUI
import PersistenceKit
import DesignSystem

struct TopPermissionsWidgetContent: View {
    let size: HomeWidgetSize
    let patterns: [PermissionPatternCount]
    var isLoading = false

    private var ranked: [PermissionPatternCount] { patterns.sorted { $0.count > $1.count } }
    private var total: Int { patterns.map(\.count).reduce(0, +) }
    private var peak: Int { ranked.first?.count ?? 1 }

    var body: some View {
        if isLoading && patterns.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 60)
        } else if patterns.isEmpty {
            HomeWidgetAllClearState(message: "Nothing asked")
        } else if size == .small {
            small
        } else {
            medium
        }
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(ranked.prefix(5), id: \.pattern) { row($0) }
        }
    }

    private func row(_ item: PermissionPatternCount) -> some View {
        let isTop = item.pattern == ranked.first?.pattern
        return HStack(spacing: 7) {
            Image(systemName: PermissionPattern.glyph(forTool: item.tool))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(FlotillaColors.textTertiary)
                .frame(width: 12)
            Text(item.pattern)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(FlotillaColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 150, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(FlotillaColors.textPrimary.opacity(0.06))
                    Capsule()
                        .fill(isTop ? FlotillaColors.accent : FlotillaColors.accent.opacity(0.45))
                        .frame(width: proxy.size.width * CGFloat(item.count) / CGFloat(peak))
                }
            }
            .frame(height: 6)
            Text("\(item.count)")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isTop ? FlotillaColors.accent : FlotillaColors.textSecondary)
                .frame(width: 18, alignment: .trailing)
        }
        .frame(height: 16)
    }

    private var small: some View {
        let top = ranked.first
        let share = total == 0 ? 0 : Int((Double(top?.count ?? 0) / Double(total) * 100).rounded())
        return VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("\(top?.count ?? 0)")
                    .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(FlotillaColors.textPrimary)
                Text("times")
                    .font(FlotillaTypography.caption)
                    .foregroundStyle(FlotillaColors.textSecondary)
            }
            HStack(spacing: 5) {
                if let top {
                    Image(systemName: PermissionPattern.glyph(forTool: top.tool))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(FlotillaColors.textTertiary)
                    Text(top.pattern)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FlotillaColors.textPrimary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(FlotillaColors.textPrimary.opacity(0.07)))
            Spacer(minLength: 0)
            Text("\(share)% of \(total) requests in this window")
                .font(FlotillaTypography.caption2)
                .foregroundStyle(FlotillaColors.textTertiary)
        }
    }
}
