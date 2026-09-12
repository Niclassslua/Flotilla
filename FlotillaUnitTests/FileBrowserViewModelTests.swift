import XCTest
@testable import Flotilla

@MainActor
final class FileBrowserViewModelTests: XCTestCase {
    private final class MockService: WorkspaceFileServicing, @unchecked Sendable {
        var files: [URL: String] = [:]
        var modDates: [URL: Date] = [:]
        var writeShouldFail = false

        func fileTree(at root: URL) async throws -> [FileNode] { [] }
        func instructionFiles(in root: URL) async throws -> [RuleFileEntry] { [] }
        func globalInstructionFiles() async throws -> [RuleFileEntry] { [] }
        func skills(projectRoot: URL) async throws -> [SkillEntry] { [] }
        func metadata(at url: URL) async -> WorkspaceFileMetadata {
            WorkspaceFileMetadata(size: Int64(files[url]?.utf8.count ?? 0), modificationDate: modDates[url] ?? Date())
        }
        func readText(at url: URL) async throws -> String {
            files[url] ?? ""
        }
        func writeText(_ text: String, to url: URL) async throws {
            if writeShouldFail {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "disk error"])
            }
            files[url] = text
            modDates[url] = Date()
        }
    }

    func testSelectingFileLoadsBaselineContent() async {
        let root = URL(fileURLWithPath: "/workspace")
        let file1 = root.appendingPathComponent("file1.txt")
        let service = MockService()
        service.files[file1] = "hello world"
        service.modDates[file1] = Date()

        let viewModel = FileBrowserViewModel(root: root, service: service)
        let node1 = FileNode(url: file1, isDirectory: false)

        await viewModel.select(node1)

        XCTAssertEqual(viewModel.content, "hello world")
        XCTAssertEqual(viewModel.loadedContent, "hello world")
        XCTAssertFalse(viewModel.isDirty)
    }

    func testEditingContentMarksDirtyAndSwitchingSaves() async {
        let root = URL(fileURLWithPath: "/workspace")
        let file1 = root.appendingPathComponent("file1.txt")
        let file2 = root.appendingPathComponent("file2.txt")
        let service = MockService()
        let initialDate = Date(timeIntervalSince1970: 1000)
        service.files[file1] = "original 1"
        service.modDates[file1] = initialDate
        service.files[file2] = "original 2"
        service.modDates[file2] = initialDate

        let viewModel = FileBrowserViewModel(root: root, service: service)
        let node1 = FileNode(url: file1, isDirectory: false)
        let node2 = FileNode(url: file2, isDirectory: false)

        await viewModel.select(node1)
        viewModel.content = "edited 1"
        XCTAssertTrue(viewModel.isDirty)

        // Switching to file 2 should auto-save file 1
        await viewModel.select(node2)

        XCTAssertEqual(service.files[file1], "edited 1")
        XCTAssertEqual(viewModel.selectedNode?.url, file2)
        XCTAssertEqual(viewModel.content, "original 2")
        XCTAssertFalse(viewModel.isDirty)
    }

    func testWriteConflictPreservesDraftAndDoesNotSwitch() async {
        let root = URL(fileURLWithPath: "/workspace")
        let file1 = root.appendingPathComponent("file1.txt")
        let file2 = root.appendingPathComponent("file2.txt")
        let service = MockService()
        let initialDate = Date(timeIntervalSinceNow: -100)
        service.files[file1] = "original 1"
        service.modDates[file1] = initialDate
        service.files[file2] = "original 2"
        service.modDates[file2] = initialDate

        let viewModel = FileBrowserViewModel(root: root, service: service)
        let node1 = FileNode(url: file1, isDirectory: false)
        let node2 = FileNode(url: file2, isDirectory: false)

        await viewModel.select(node1)
        viewModel.content = "my local unsaved edits"
        XCTAssertTrue(viewModel.isDirty)

        // Simulate external modification on disk
        service.modDates[file1] = Date(timeIntervalSinceNow: 10)

        // Switching should detect conflict, NOT switch, and preserve edits
        await viewModel.select(node2)

        XCTAssertEqual(viewModel.selectedNode?.url, file1, "Selection must not change on conflict")
        XCTAssertEqual(viewModel.content, "my local unsaved edits", "Edits must be preserved")
        XCTAssertTrue(viewModel.isDirty)
        XCTAssertNotNil(viewModel.message)
    }
}
