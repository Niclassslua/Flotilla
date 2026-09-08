import Foundation

struct WorkspaceFileMetadata: Sendable {
    let size: Int64?
    let modificationDate: Date?
}

protocol WorkspaceFileServicing: Sendable {
    func fileTree(at root: URL) async throws -> [FileNode]
    func instructionFiles(in root: URL) async throws -> [RuleFileEntry]
    func globalInstructionFiles() async throws -> [RuleFileEntry]
    func skills(projectRoot: URL) async throws -> [SkillEntry]
    func metadata(at url: URL) async -> WorkspaceFileMetadata
    func readText(at url: URL) async throws -> String
    func writeText(_ text: String, to url: URL) async throws
}

