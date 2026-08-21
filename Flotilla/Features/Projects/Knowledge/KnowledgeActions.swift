import AppKit
import Foundation

/// The things a design needs to be able to do to its host.
///
/// Follows the `SessionLauncherActions` precedent from `CreateSessionView`:
/// designs get a small explicit contract instead of reaching into a view model,
/// so a design file stays purely presentational and interchangeable with its
/// three siblings.
struct KnowledgeActions {
    /// Open an item — modal designs raise the overlay, inline designs move
    /// their selection.
    let open: (KnowledgeItem) -> Void
    /// Hand the file to whatever app owns it.
    let openExternally: (URL) -> Void
    /// Copy a skill's invocation snippet to the pasteboard.
    let copy: (String) -> Void

    static func standard(open: @escaping (KnowledgeItem) -> Void) -> KnowledgeActions {
        KnowledgeActions(
            open: open,
            openExternally: { NSWorkspace.shared.open($0) },
            copy: { string in
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(string, forType: .string)
            }
        )
    }
}
