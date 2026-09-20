import XCTest
import AppKit
import SessionKit
import GitKit
import SettingsKit
@testable import PersistenceKit
@testable import Flotilla

final class ProjectIconTests: XCTestCase {
    func testProjectIconCodableRoundtrip() throws {
        let symbolIcon = ProjectIcon.symbol(name: "terminal.fill")
        let emojiIcon = ProjectIcon.emoji("🚀")
        let customIcon = ProjectIcon.custom(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let symbolData = try encoder.encode(symbolIcon)
        let decodedSymbol = try decoder.decode(ProjectIcon.self, from: symbolData)
        XCTAssertEqual(symbolIcon, decodedSymbol)

        let emojiData = try encoder.encode(emojiIcon)
        let decodedEmoji = try decoder.decode(ProjectIcon.self, from: emojiData)
        XCTAssertEqual(emojiIcon, decodedEmoji)

        let customData = try encoder.encode(customIcon)
        let decodedCustom = try decoder.decode(ProjectIcon.self, from: customData)
        XCTAssertEqual(customIcon, decodedCustom)
    }

    func testProjectRecordConversion() throws {
        let root = URL(fileURLWithPath: "/Users/dev/TestProject")

        // 1. Symbol
        let symbolProject = Project(name: "SymbolProj", rootPath: root, icon: .symbol(name: "star.fill"))
        let symbolRecord = ProjectRecord(project: symbolProject)
        XCTAssertEqual(symbolRecord.iconType, "symbol")
        XCTAssertEqual(symbolRecord.iconValue, "star.fill")
        XCTAssertNil(symbolRecord.iconData)
        let symbolRestored = try symbolRecord.toDomain()
        XCTAssertEqual(symbolRestored.icon, ProjectIcon.symbol(name: "star.fill"))

        // 2. Emoji
        let emojiProject = Project(name: "EmojiProj", rootPath: root, icon: .emoji("⚡"))
        let emojiRecord = ProjectRecord(project: emojiProject)
        XCTAssertEqual(emojiRecord.iconType, "emoji")
        XCTAssertEqual(emojiRecord.iconValue, "⚡")
        XCTAssertNil(emojiRecord.iconData)
        let emojiRestored = try emojiRecord.toDomain()
        XCTAssertEqual(emojiRestored.icon, ProjectIcon.emoji("⚡"))

        // 3. Custom
        let rawData = Data([1, 2, 3, 4, 5])
        let customProject = Project(name: "CustomProj", rootPath: root, icon: .custom(data: rawData))
        let customRecord = ProjectRecord(project: customProject)
        XCTAssertEqual(customRecord.iconType, "custom")
        XCTAssertNil(customRecord.iconValue)
        XCTAssertEqual(customRecord.iconData, rawData)
        let customRestored = try customRecord.toDomain()
        XCTAssertEqual(customRestored.icon, ProjectIcon.custom(data: rawData))

        // 4. Nil
        let nilProject = Project(name: "NilProj", rootPath: root, icon: nil)
        let nilRecord = ProjectRecord(project: nilProject)
        XCTAssertNil(nilRecord.iconType)
        XCTAssertNil(nilRecord.iconValue)
        XCTAssertNil(nilRecord.iconData)
        let nilRestored = try nilRecord.toDomain()
        XCTAssertNil(nilRestored.icon)
    }

    func testGRDBSessionRepositoryMigrationV16AndPersistence() throws {
        let repo = try GRDBSessionRepository()
        let root = URL(fileURLWithPath: "/Users/dev/PersistenceProject")

        // Initial save with symbol
        var project = Project(name: "PersistenceProj", rootPath: root, icon: .symbol(name: "folder.fill"))
        try repo.save(project)

        var (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.icon, ProjectIcon.symbol(name: "folder.fill"))

        // Update to emoji
        project.icon = .emoji("🎯")
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.first?.icon, ProjectIcon.emoji("🎯"))

        // Update to custom PNG data
        let testImage = makeTestImage(size: NSSize(width: 64, height: 64), color: .systemPurple)
        let tiffData = testImage.tiffRepresentation!
        let bitmapRep = NSBitmapImageRep(data: tiffData)!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!

        project.icon = .custom(data: pngData)
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.first?.icon, ProjectIcon.custom(data: pngData))

        // Clear icon
        project.icon = nil
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertNil(projects.first?.icon)
    }

    func testProjectIconCropRendererGeneratesValidPNG() throws {
        let sourceImage = makeTestImage(size: NSSize(width: 400, height: 200), color: .systemBlue)
        let renderedData = ProjectIconCropRenderer.render(
            image: sourceImage,
            viewportSize: 280,
            zoom: 1.5,
            offset: CGSize(width: 10, height: -10),
            outputDimension: 512
        )

        XCTAssertNotNil(renderedData, "Crop renderer must produce PNG data")
        guard let data = renderedData else { return }

        let decoded = NSImage(data: data)
        XCTAssertNotNil(decoded, "Rendered PNG data must be decodable by NSImage")

        // Check pixel dimensions from representation
        if let rep = decoded?.representations.first {
            XCTAssertEqual(rep.pixelsWide, 512)
            XCTAssertEqual(rep.pixelsHigh, 512)
        }
    }

    func testProjectIconImageLoaderFromDataAndAssets() throws {
        // Test loading from direct PNG data
        let testImage = makeTestImage(size: NSSize(width: 80, height: 80), color: .systemOrange)
        let pngData = NSBitmapImageRep(data: testImage.tiffRepresentation!)!.representation(using: .png, properties: [:])!

        let loadedFromData = ProjectIconImageLoader.load(from: pngData)
        XCTAssertNotNil(loadedFromData)

        // Test loading Flotilla.icon from repository root
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FlotillaUnitTests
            .deletingLastPathComponent() // Repository root
        let flotillaIconURL = repoRoot.appendingPathComponent("Flotilla.icon")

        if FileManager.default.fileExists(atPath: flotillaIconURL.path) {
            let loadedIcon = ProjectIconImageLoader.load(from: flotillaIconURL)
            XCTAssertNotNil(loadedIcon, "ProjectIconImageLoader must load .icon bundles")
        }
    }

    @MainActor
    func testAppStoreUpdateProjectIcon() throws {
        let repository = try GRDBSessionRepository()
        let factory = RecordingProcessFactory()
        let processManager = SessionProcessManager(
            locator: AppLayerExecutableLocator(executable: URL(fileURLWithPath: "/usr/bin/env")),
            processFactory: factory,
            tmuxServerProbe: AppLayerTmuxServerProbe(usable: false),
            hookSupportDirectory: TmuxSessionWrapping.defaultSupportDirectory()
        )
        let store = AppStore(
            repository: repository,
            gitService: MockGitService(),
            processManager: processManager,
            worktreeBaseDirectoryProvider: { URL(fileURLWithPath: "/tmp/worktrees") },
            settingsProvider: { AppSettings() }
        )

        store.addProject(at: URL(fileURLWithPath: "/tmp/AppStoreIconTest"))
        guard let project = store.projects.first(where: { $0.name == "AppStoreIconTest" }) else {
            XCTFail("Project was not added")
            return
        }

        XCTAssertNil(project.icon)

        // Update to symbol
        store.updateProjectIcon(id: project.id, icon: .symbol(name: "cube.fill"))
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.icon, ProjectIcon.symbol(name: "cube.fill"))

        // Update to nil
        store.updateProjectIcon(id: project.id, icon: nil)
        XCTAssertNil(store.projects.first(where: { $0.id == project.id })?.icon)
    }

    // MARK: - Helpers

    private func makeTestImage(size: NSSize, color: NSColor) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        return image
    }
}
