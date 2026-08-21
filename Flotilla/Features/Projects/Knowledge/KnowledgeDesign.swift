import SwiftUI
import DesignSystem

/// The four candidate designs for the Skills and Rules tabs.
///
/// This is a deliberate bake-off scaffold, the same one `CreateSession` went
/// through: four designs live side by side behind an in-view picker so they can
/// be compared against real data, and once a winner is picked the other three
/// are deleted along with this enum and `KnowledgeDesignPicker`.
///
/// They differ by interaction model, not just styling — a grid, a table, a
/// reader, and a mosaic — because that is the choice actually worth making.
enum KnowledgeDesign: String, CaseIterable, Identifiable, Sendable {
    /// Editorial card grid, floating modal detail. The refined evolution of
    /// what these tabs looked like before.
    case atlas
    /// Dense keyboard-navigable table with a docked inspector. Closest to the
    /// IDE posture `.impeccable.md` asks for.
    case ledger
    /// Source-list rail plus an always-visible reading pane. Built for reading
    /// long instruction files rather than scanning many.
    case shelf
    /// Weighted mosaic that zooms a tile into full-bleed detail. The bold one.
    case constellation

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .atlas: return "Atlas"
        case .ledger: return "Ledger"
        case .shelf: return "Shelf"
        case .constellation: return "Constellation"
        }
    }

    var summary: String {
        switch self {
        case .atlas: return "Card grid with a floating detail card"
        case .ledger: return "Dense table with a docked inspector"
        case .shelf: return "Source list with a reading pane"
        case .constellation: return "Weighted mosaic that zooms to detail"
        }
    }

    var symbolName: String {
        switch self {
        case .atlas: return "square.grid.2x2"
        case .ledger: return "list.bullet.rectangle"
        case .shelf: return "sidebar.left"
        case .constellation: return "rectangle.3.group"
        }
    }

    /// Designs that keep a detail pane on screen manage their own selection and
    /// must not also raise the modal overlay.
    var usesInlineDetail: Bool {
        switch self {
        case .ledger, .shelf: return true
        case .atlas, .constellation: return false
        }
    }

    /// Split designs host search, scope, and sort above their own list column
    /// instead of in the window-wide header. A control strip that spans a
    /// reading pane it does not filter reads as global when it is not.
    var usesInlineListControls: Bool { usesInlineDetail }

    static let storageKey = "projects.knowledgeDesign"
}

/// Compact icon-only segmented control for switching designs from the header.
///
/// Icon-only because the header already carries a title, a count, a search
/// field and a scope picker; four spelled-out design names would dominate it.
/// Each segment keeps a `.help` tooltip and an accessibility label so the name
/// is still reachable.
struct KnowledgeDesignPicker: View {
    @Binding var selection: KnowledgeDesign

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: KnowledgeDesign?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(KnowledgeDesign.allCases) { design in
                let isSelected = design == selection
                Button {
                    withAnimation(reduceMotion ? nil : FlotillaMotion.fast.curve) {
                        selection = design
                    }
                } label: {
                    Image(systemName: design.symbolName)
                        .font(.system(size: FlotillaIconSize.small, weight: .medium))
                        .foregroundStyle(isSelected ? FlotillaColors.accentContent : FlotillaColors.textSecondary)
                        .frame(width: 26, height: 20)
                        .background {
                            RoundedRectangle(cornerRadius: FlotillaRadius.control - 2, style: .continuous)
                                .fill(background(for: design, isSelected: isSelected))
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovered = $0 ? design : (hovered == design ? nil : hovered) }
                .help("\(design.displayName) — \(design.summary)")
                .accessibilityLabel("\(design.displayName) design")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                .accessibilityIdentifier("Knowledge.Design.\(design.rawValue)")
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                .fill(FlotillaColors.surfaceElevated)
                .overlay {
                    RoundedRectangle(cornerRadius: FlotillaRadius.control, style: .continuous)
                        .strokeBorder(FlotillaColors.separator, lineWidth: FlotillaBorderWidth.hairline)
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AXID.knowledgeDesignPicker.rawValue)
    }

    private func background(for design: KnowledgeDesign, isSelected: Bool) -> Color {
        if isSelected { return FlotillaColors.accent }
        if hovered == design { return FlotillaColors.textPrimary.opacity(FlotillaStateOpacity.hover) }
        return .clear
    }
}
