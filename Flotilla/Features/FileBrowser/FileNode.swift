import Foundation

struct FileNode: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    var children: [FileNode]?

    var id: URL { url }
    var name: String { url.lastPathComponent }
}

