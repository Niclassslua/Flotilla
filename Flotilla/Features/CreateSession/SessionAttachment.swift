import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// An image attached to a session's goal — a pasted screenshot or a dropped
/// image file.
///
/// The goal reaches the agent as typed terminal input, so an image can't ride
/// along as an object. Instead each one is written to disk at launch and its
/// path is appended to the goal: Claude Code turns an image path in a prompt
/// into an attached image, and every other agent can open the file itself.
struct SessionAttachment: Identifiable {
    let id = UUID()
    let data: Data
    /// One of the formats the agents' vision APIs accept as-is; anything else
    /// is converted to PNG on the way in.
    let fileExtension: String
    let thumbnail: NSImage

    private static let passthroughTypes: [UTType] = [.png, .jpeg, .gif, .webP]

    /// An image file's own bytes when it is already in an accepted format, so a
    /// JPEG isn't bloated into a PNG; otherwise a PNG conversion.
    init?(fileURL url: URL) {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url),
              let image = NSImage(data: data) else { return nil }
        if let passthrough = Self.passthroughTypes.first(where: { type.conforms(to: $0) }),
           let ext = passthrough.preferredFilenameExtension {
            self.init(data: data, fileExtension: ext, thumbnail: image)
        } else {
            self.init(image: image)
        }
    }

    init?(image: NSImage) {
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return nil }
        self.init(data: png, fileExtension: "png", thumbnail: image)
    }

    private init(data: Data, fileExtension: String, thumbnail: NSImage) {
        self.data = data
        self.fileExtension = fileExtension
        self.thumbnail = thumbnail
    }

    // MARK: - Pasteboard

    /// The images a ⌘V should attach, or an empty array when the paste belongs
    /// to the text field.
    ///
    /// Copying text from Pages, Word or Notes often carries an image rendering
    /// of the selection alongside the string, so text wins whenever there is
    /// any. A Finder copy also carries the file names as text, which is why
    /// file URLs are checked first.
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> [SessionAttachment] {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        // A Finder copy of a non-image file also carries its icon as an image,
        // so any file copy is decided by the files alone.
        if !urls.isEmpty { return urls.compactMap(SessionAttachment.init(fileURL:)) }
        guard pasteboard.string(forType: .string) == nil else { return [] }

        if let png = pasteboard.data(forType: .png), let image = NSImage(data: png) {
            return [SessionAttachment(data: png, fileExtension: "png", thumbnail: image)]
        }
        let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage] ?? []
        return images.compactMap(SessionAttachment.init(image:))
    }

    // MARK: - Disk

    /// Where a session's attachments live; removed with the session.
    static func directory(for sessionID: UUID, supportDirectory: URL) -> URL {
        supportDirectory
            .appendingPathComponent("Attachments", isDirectory: true)
            .appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    /// Writes `attachments` for `sessionID` and returns `goal` with their paths
    /// appended. Spaces are backslash-escaped — the form a Finder drag into a
    /// terminal produces, which is what Claude Code recognises as an image.
    static func goal(
        _ goal: String,
        attaching attachments: [SessionAttachment],
        sessionID: UUID,
        supportDirectory: URL
    ) throws -> String {
        guard !attachments.isEmpty else { return goal }
        let directory = directory(for: sessionID, supportDirectory: supportDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var paths: [String] = []
        for (index, attachment) in attachments.enumerated() {
            let file = directory.appendingPathComponent("image-\(index + 1).\(attachment.fileExtension)")
            try attachment.data.write(to: file, options: .atomic)
            paths.append(file.path.replacingOccurrences(of: " ", with: "\\ "))
        }
        let list = paths.joined(separator: "\n")
        let heading = attachments.count == 1 ? "Attached image:" : "Attached images:"
        return goal.isEmpty ? "\(heading)\n\(list)" : "\(goal)\n\n\(heading)\n\(list)"
    }
}

// MARK: - ⌘V

/// Attaches images pasted with ⌘V anywhere in the launcher's window.
///
/// The goal field's AppKit field editor handles `paste:` itself and drops
/// image data on the floor, so SwiftUI's `onPasteCommand` never sees it. A
/// local key monitor runs before the field editor; it consumes ⌘V only when
/// the clipboard holds images, so a text paste reaches the field untouched.
struct ImagePasteCatcher: NSViewRepresentable {
    let onPaste: ([SessionAttachment]) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(in: view, onPaste: onPaste)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onPaste = onPaste
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var onPaste: (([SessionAttachment]) -> Void)?
        private weak var view: NSView?
        private var monitor: Any?

        func install(in view: NSView, onPaste: @escaping ([SessionAttachment]) -> Void) {
            self.view = view
            self.onPaste = onPaste
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window, event.window === window,
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command,
                      event.charactersIgnoringModifiers?.lowercased() == "v" else { return event }
                let attachments = SessionAttachment.fromPasteboard()
                guard !attachments.isEmpty else { return event }
                self.onPaste?(attachments)
                return nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
