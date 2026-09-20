import XCTest
import AppKit
import SessionKit
import GitKit
import SettingsKit
import DesignSystem
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

        // 1. Symbol with Accent Color
        let symbolProject = Project(name: "SymbolProj", rootPath: root, icon: .symbol(name: "star.fill"), accentColor: "#6366F1")
        let symbolRecord = ProjectRecord(project: symbolProject)
        XCTAssertEqual(symbolRecord.iconType, "symbol")
        XCTAssertEqual(symbolRecord.iconValue, "star.fill")
        XCTAssertNil(symbolRecord.iconData)
        XCTAssertEqual(symbolRecord.accentColor, "#6366F1")
        let symbolRestored = try symbolRecord.toDomain()
        XCTAssertEqual(symbolRestored.icon, ProjectIcon.symbol(name: "star.fill"))
        XCTAssertEqual(symbolRestored.accentColor, "#6366F1")

        // 2. Emoji
        let emojiProject = Project(name: "EmojiProj", rootPath: root, icon: .emoji("⚡"))
        let emojiRecord = ProjectRecord(project: emojiProject)
        XCTAssertEqual(emojiRecord.iconType, "emoji")
        XCTAssertEqual(emojiRecord.iconValue, "⚡")
        XCTAssertNil(emojiRecord.iconData)
        XCTAssertNil(emojiRecord.accentColor)
        let emojiRestored = try emojiRecord.toDomain()
        XCTAssertEqual(emojiRestored.icon, ProjectIcon.emoji("⚡"))
        XCTAssertNil(emojiRestored.accentColor)

        // 3. Custom
        let rawData = Data([1, 2, 3, 4, 5])
        let customProject = Project(name: "CustomProj", rootPath: root, icon: .custom(data: rawData), accentColor: "#10B981")
        let customRecord = ProjectRecord(project: customProject)
        XCTAssertEqual(customRecord.iconType, "custom")
        XCTAssertNil(customRecord.iconValue)
        XCTAssertEqual(customRecord.iconData, rawData)
        XCTAssertEqual(customRecord.accentColor, "#10B981")
        let customRestored = try customRecord.toDomain()
        XCTAssertEqual(customRestored.icon, ProjectIcon.custom(data: rawData))
        XCTAssertEqual(customRestored.accentColor, "#10B981")

        // 4. Nil
        let nilProject = Project(name: "NilProj", rootPath: root, icon: nil)
        let nilRecord = ProjectRecord(project: nilProject)
        XCTAssertNil(nilRecord.iconType)
        XCTAssertNil(nilRecord.iconValue)
        XCTAssertNil(nilRecord.iconData)
        XCTAssertNil(nilRecord.accentColor)
        let nilRestored = try nilRecord.toDomain()
        XCTAssertNil(nilRestored.icon)
        XCTAssertNil(nilRestored.accentColor)
    }

    func testGRDBSessionRepositoryMigrationV16V17AndPersistence() throws {
        let repo = try GRDBSessionRepository()
        let root = URL(fileURLWithPath: "/Users/dev/PersistenceProject")

        // Initial save with symbol and custom accent color
        var project = Project(name: "PersistenceProj", rootPath: root, icon: .symbol(name: "folder.fill"), accentColor: "#6366F1")
        try repo.save(project)

        var (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.icon, ProjectIcon.symbol(name: "folder.fill"))
        XCTAssertEqual(projects.first?.accentColor, "#6366F1")

        // Update to emoji and change accent color
        project.icon = .emoji("🎯")
        project.accentColor = "#F59E0B"
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.first?.icon, ProjectIcon.emoji("🎯"))
        XCTAssertEqual(projects.first?.accentColor, "#F59E0B")

        // Update to custom PNG data
        let testImage = makeTestImage(size: NSSize(width: 64, height: 64), color: .systemPurple)
        let tiffData = testImage.tiffRepresentation!
        let bitmapRep = NSBitmapImageRep(data: tiffData)!
        let pngData = bitmapRep.representation(using: .png, properties: [:])!

        project.icon = .custom(data: pngData)
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertEqual(projects.first?.icon, ProjectIcon.custom(data: pngData))
        XCTAssertEqual(projects.first?.accentColor, "#F59E0B")

        // Clear icon and reset accent color
        project.icon = nil
        project.accentColor = nil
        try repo.save(project)
        (projects, _) = try repo.loadAll()
        XCTAssertNil(projects.first?.icon)
        XCTAssertNil(projects.first?.accentColor)
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
        XCTAssertNil(project.accentColor)

        // Update to symbol
        store.updateProjectIcon(id: project.id, icon: .symbol(name: "cube.fill"))
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.icon, ProjectIcon.symbol(name: "cube.fill"))

        // Update accent color
        store.updateProjectAccentColor(id: project.id, accentColor: "#6366F1")
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.accentColor, "#6366F1")
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.icon, ProjectIcon.symbol(name: "cube.fill"))

        // Update both via identity
        store.updateProjectIdentity(id: project.id, icon: .emoji("🚀"), accentColor: "#10B981")
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.icon, ProjectIcon.emoji("🚀"))
        XCTAssertEqual(store.projects.first(where: { $0.id == project.id })?.accentColor, "#10B981")

        // Update to nil
        store.updateProjectIdentity(id: project.id, icon: nil, accentColor: nil)
        XCTAssertNil(store.projects.first(where: { $0.id == project.id })?.icon)
        XCTAssertNil(store.projects.first(where: { $0.id == project.id })?.accentColor)
    }

    func testProjectMarkTintUsesAccentColor() {
        let root = URL(fileURLWithPath: "/Users/dev/ProjectMarkTest")

        // 1. Project without custom accentColor uses deterministic hash
        let autoProject = Project(name: "AutoProject", rootPath: root, accentColor: nil)
        let expectedAuto = ProjectMark.tint(forKey: "AutoProject")
        XCTAssertEqual(ProjectMark.tint(for: autoProject), expectedAuto)

        // 2. Project with custom accentColor uses custom color
        let customProject = Project(name: "CustomColorProject", rootPath: root, accentColor: "#F59E0B")
        let expectedCustom = FlotillaAccent.makeColor(for: "#F59E0B")
        XCTAssertEqual(ProjectMark.tint(for: customProject), expectedCustom)
    }

    func testCuratedPickerSymbolsAndEmojisAreValidAndUnique() {
        // 1. Verify every curated SF Symbol exists and is unique
        var seenSymbols = Set<String>()
        for symbol in ProjectIconPickerSheet.curatedSymbols {
            XCTAssertFalse(seenSymbols.contains(symbol), "Duplicate symbol found in curatedSymbols: \(symbol)")
            seenSymbols.insert(symbol)

            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            XCTAssertNotNil(image, "Curated SF Symbol does not exist in system glyphs: \(symbol)")
        }

        // 2. Verify every curated Emoji is unique
        var seenEmojis = Set<String>()
        for emoji in ProjectIconPickerSheet.curatedEmojis {
            XCTAssertFalse(seenEmojis.contains(emoji), "Duplicate emoji found in curatedEmojis: \(emoji)")
            seenEmojis.insert(emoji)
        }
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
