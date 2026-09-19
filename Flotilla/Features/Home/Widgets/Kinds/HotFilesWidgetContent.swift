import SwiftUI
import DesignSystem

struct HotFilesWidgetContent: View {
    struct File: Identifiable {
        let id: String
        var name: String { (id as NSString).lastPathComponent }
        var directory: String {
            let dir = (id as NSString).deletingLastPathComponent
            return dir == "." ? "" : dir
        }
        let edits: Int
    }

    let size: HomeWidgetSize
    /// Path → edit count, as `HomeInsights.fileChurn` returns it.
    let churn: [String: Int]
    var isLoading = false

    private var files: [File] {
        churn.map { File(id: $0.key, edits: $0.value) }.sorted { $0.edits > $1.edits }
    }

    private var peak: Int { files.first?.edits ?? 1 }

    var body: some View {
        if isLoading && churn.isEmpty {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            HomeWidgetAllClearState(message: "No changes in this window.")
        } else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(files.prefix(size == .large ? 13 : 5)) { file in row(file) }
            }
        }
    }

    private func row(_ file: File) -> some View {
        let heat = Double(file.edits) / Double(peak)
        return HStack(spacing: 7) {
            ZStack(alignment: .leading) {
                Capsule().fill(FlotillaColors.textPrimary.opacity(0.07))
                Capsule()
                    .fill(LinearGradient(colors: [.yellow, FlotillaColors.accent, FlotillaColors.statusCrashed], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 30 * heat)
            }
            .frame(width: 30, height: 5)

            HStack(spacing: 4) {
                Text(file.name)
                    .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(FlotillaColors.textPrimary)
                    .lineLimit(1)
                    .layoutPriority(1)
                if !file.directory.isEmpty {
                    Text(file.directory)
                        .font(FlotillaTypography.caption2)
                        .foregroundStyle(FlotillaColors.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            Spacer(minLength: 2)
            Text("\(file.edits)")
                .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(heat > 0.66 ? FlotillaColors.accent : FlotillaColors.textSecondary)
                .frame(width: 24, alignment: .trailing)
        }
    }
}
