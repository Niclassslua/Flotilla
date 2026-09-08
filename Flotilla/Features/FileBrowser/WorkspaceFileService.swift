import Foundation

struct WorkspaceFileService: WorkspaceFileServicing {
    let homeDirectoryProvider: @Sendable () -> URL

    init(homeDirectoryProvider: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }) {
        self.homeDirectoryProvider = homeDirectoryProvider
    }

    func fileTree(at root: URL) async throws -> [FileNode] {
        return try await Task.detached {
            try WorkspaceFileDiscovery.loadChildren(of: root, depth: 0, fileManager: .default)
        }.value
    }

    func instructionFiles(in root: URL) async throws -> [RuleFileEntry] {
        return try await Task.detached {
            try WorkspaceFileDiscovery.discoverInstructionFiles(in: root, fileManager: .default)
        }.value
    }

    func readText(at url: URL) async throws -> String {
        try await Task.detached {
            try String(contentsOf: url, encoding: .utf8)
        }.value
    }

    func writeText(_ text: String, to url: URL) async throws {
        try await Task.detached {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }.value
    }

    func globalInstructionFiles() async throws -> [RuleFileEntry] {
        let home = homeDirectoryProvider()
        return try await Task.detached {
            WorkspaceFileDiscovery.discoverGlobalInstructionFiles(home: home, fileManager: .default)
        }.value
    }

    func skills(projectRoot: URL) async throws -> [SkillEntry] {
        let home = homeDirectoryProvider()
        return try await Task.detached {
            WorkspaceFileDiscovery.discoverSkills(projectRoot: projectRoot, home: home, fileManager: .default)
        }.value
    }

    func metadata(at url: URL) async -> WorkspaceFileMetadata {
        await Task.detached {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return WorkspaceFileMetadata(size: attributes?[.size] as? Int64,
                                         modificationDate: attributes?[.modificationDate] as? Date)
        }.value
    }

    static func isTCCProtected(_ url: URL) -> Bool {
        WorkspaceFileDiscovery.isTCCProtected(url)
    }
}
