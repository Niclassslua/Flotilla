import XCTest
import AppKit
@testable import Flotilla

/// The ⌘V monitor swallows the paste whenever `fromPasteboard` returns
/// anything, so a wrong answer here either eats a text paste or drops an image.
@MainActor
final class SessionAttachmentTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private var scratch: URL!

    override func setUp() {
        super.setUp()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("SessionAttachmentTests-\(UUID().uuidString)"))
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        return rep.representation(using: .png, properties: [:])!
    }

    func testScreenshotOnClipboardIsAttached() {
        pasteboard.clearContents()
        pasteboard.setData(pngData(), forType: .png)

        let attachments = SessionAttachment.fromPasteboard(pasteboard)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.fileExtension, "png")
    }

    /// Rich text copied from Pages or Notes carries an image of the selection.
    func testTextWithAnImageRenderingStaysATextPaste() {
        pasteboard.clearContents()
        pasteboard.setString("fix the login bug", forType: .string)
        pasteboard.setData(pngData(), forType: .png)

        XCTAssertTrue(SessionAttachment.fromPasteboard(pasteboard).isEmpty)
    }

    func testCopiedImageFilesAreAttachedKeepingTheirFormat() throws {
        let file = scratch.appendingPathComponent("shot.png")
        try pngData().write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])

        let attachments = SessionAttachment.fromPasteboard(pasteboard)

        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments.first?.fileExtension, "png")
    }

    /// Finder puts the file's icon on the clipboard too; it must not be
    /// attached in place of the file.
    func testCopiedNonImageFileIsNotAttached() throws {
        let file = scratch.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setData(pngData(), forType: .png)

        XCTAssertTrue(SessionAttachment.fromPasteboard(pasteboard).isEmpty)
    }

    func testGoalListsEscapedPathsOfTheWrittenImages() throws {
        let support = scratch.appendingPathComponent("Application Support", isDirectory: true)
        let sessionID = UUID()
        let attachment = try XCTUnwrap(SessionAttachment(image: NSImage(data: pngData())!))

        let goal = try SessionAttachment.goal(
            "Match this design",
            attaching: [attachment, attachment],
            sessionID: sessionID,
            supportDirectory: support
        )

        let directory = SessionAttachment.directory(for: sessionID, supportDirectory: support)
        let first = directory.appendingPathComponent("image-1.png")
        let second = directory.appendingPathComponent("image-2.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let escaped = { (url: URL) in url.path.replacingOccurrences(of: " ", with: "\\ ") }
        XCTAssertEqual(goal, "Match this design\n\nAttached images:\n\(escaped(first))\n\(escaped(second))")
    }

    func testNoAttachmentsLeavesGoalAndDiskUntouched() throws {
        let goal = try SessionAttachment.goal("Ship it", attaching: [], sessionID: UUID(), supportDirectory: scratch)

        XCTAssertEqual(goal, "Ship it")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Attachments").path))
    }
}
