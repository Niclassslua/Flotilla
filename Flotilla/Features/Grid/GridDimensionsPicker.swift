import SwiftUI
import DesignSystem

/// The toolbar's grid-size control: a chip showing the current column×row
/// count that opens a drag/hover-to-select swatch, the way "Insert Table"
/// pickers in Office apps work.
///
/// Bound straight to the persisted setting — same reasoning as the stepper
/// this replaces: a second copy of the dimensions in local `@State` risks the
/// control disagreeing with what the grid actually renders.
struct GridDimensionsPicker: View {
    @Bindable var settingsViewModel: SettingsViewModel

    @State private var isPresented = false

    private var dimensions: GridDimensions {
        GridDimensions(
            columns: settingsViewModel.settings.workspace.gridColumnCount,
            rows: settingsViewModel.settings.workspace.gridRowCount
        )
    }

    private func apply(_ newDimensions: GridDimensions) {
        settingsViewModel.settings.workspace.gridColumnCount = newDimensions.columns
        settingsViewModel.settings.workspace.gridRowCount = newDimensions.rows
    }

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "square.grid.2x2")
        }
        .help("Grid layout: \(dimensions.label)")
        .accessibilityLabel("Grid layout")
        .accessibilityValue(dimensions.label)
        .accessibilityIdentifier(AXID.gridLayoutPicker.rawValue)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            GridDimensionsSwatch(dimensions: dimensions, onSelect: { selection in
                apply(selection)
                isPresented = false
            })
        }
        // Command-plus/minus mirror the old stepper's shortcuts even though
        // the visible control is now the swatch chip; pinch and
        // Command-scroll on the grid itself do the same thing.
        .background {
            Button { apply(dimensions.zoomedOut()) } label: { EmptyView() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!dimensions.canZoomOut)
            Button { apply(dimensions.zoomedIn()) } label: { EmptyView() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!dimensions.canZoomIn)
            // `⌘+` needs Shift on most layouts, so also bind the unshifted
            // `⌘=` that users actually press.
            Button { apply(dimensions.zoomedIn()) } label: { EmptyView() }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(!dimensions.canZoomIn)
        }
    }
}

/// The N×M swatch itself: hovering previews a selection, clicking commits it.
private struct GridDimensionsSwatch: View {
    let dimensions: GridDimensions
    let onSelect: (GridDimensions) -> Void

    @State private var hovered: GridDimensions?

    private let cellSize: CGFloat = 26
    private let cellSpacing: CGFloat = 5

    private var preview: GridDimensions { hovered ?? dimensions }

    var body: some View {
        VStack(spacing: 10) {
            VStack(spacing: cellSpacing) {
                ForEach(GridDimensions.rowRange, id: \.self) { row in
                    HStack(spacing: cellSpacing) {
                        ForEach(GridDimensions.columnRange, id: \.self) { column in
                            cell(column: column, row: row)
                        }
                    }
                }
            }
            .onHover { inside in
                if !inside { hovered = nil }
            }

            Text(preview.label)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(FlotillaColors.textSecondary)
        }
        .padding(12)
    }

    private func cell(column: Int, row: Int) -> some View {
        let isSelected = column <= preview.columns && row <= preview.rows
        return RoundedRectangle(cornerRadius: 4, style: .continuous)
            .strokeBorder(
                isSelected ? FlotillaColors.textPrimary : FlotillaColors.separator,
                lineWidth: isSelected ? 1.5 : 1
            )
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(isSelected ? FlotillaColors.textPrimary.opacity(0.1) : FlotillaColors.surfaceElevated)
            )
            .frame(width: cellSize, height: cellSize)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hovered = GridDimensions(columns: column, rows: row) }
            }
            .onTapGesture {
                onSelect(GridDimensions(columns: column, rows: row))
            }
            .accessibilityLabel("\(column)×\(row)")
            .accessibilityIdentifier("\(AXID.gridLayoutPickerCell.rawValue)\(column)x\(row)")
            .accessibilityAddTraits(.isButton)
    }
}

#Preview("Grid dimensions swatch") {
    GridDimensionsSwatch(dimensions: GridDimensions(columns: 2, rows: 1), onSelect: { _ in })
        .padding(24)
        .background(FlotillaColors.surface)
}
