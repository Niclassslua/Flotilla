import Foundation

/// The review's file list as a directory tree.
///
/// A flat list of repository-relative paths is unreadable past a dozen files:
/// every row repeats the same directory prefix, and files that belong together
/// are only adjacent by luck of alphabetical order. The tree restores the
/// shape the reviewer already knows from the project.
struct ReviewTreeNode: Identifiable {
    enum Kind {
        case directory
        case file(ReviewFile)
    }

    /// Full repository-relative path. Unique, so it doubles as the identity
    /// and as the disclosure state's key.
    let path: String
    /// What this row shows. A chain of single-child directories is collapsed
    /// into one row (`Sources/Network`), the way every file navigator does,
    /// because each such directory would otherwise cost a row and a level of
    /// indent to convey nothing.
    let name: String
    let kind: Kind
    var children: [ReviewTreeNode]

    var id: String { path }

    var isDirectory: Bool {
        if case .directory = kind { return true }
        return false
    }

    var file: ReviewFile? {
        if case let .file(file) = kind { return file }
        return nil
    }

    /// Every file at or below this node.
    var files: [ReviewFile] {
        switch kind {
        case let .file(file): [file]
        case .directory: children.flatMap(\.files)
        }
    }
}

enum ReviewFileTreeBuilder {
    /// Builds the tree, sorting directories before files and each group by
    /// name, so the order does not shuffle as files change.
    static func build(from files: [ReviewFile]) -> [ReviewTreeNode] {
        var roots: [String: MutableNode] = [:]
        var order: [String] = []

        for file in files {
            let components = file.path.split(separator: "/").map(String.init)
            guard let first = components.first else { continue }

            if roots[first] == nil {
                roots[first] = MutableNode(name: first, path: first)
                order.append(first)
            }
            roots[first]?.insert(components.dropFirst(), file: file, parentPath: first)
        }

        return order
            .compactMap { roots[$0]?.materialize() }
            .sorted(by: ordering)
    }

    private static func ordering(_ lhs: ReviewTreeNode, _ rhs: ReviewTreeNode) -> Bool {
        if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    /// Mutable while building; `materialize` freezes it and performs the
    /// single-child directory collapsing.
    private final class MutableNode {
        var name: String
        let path: String
        var file: ReviewFile?
        var children: [String: MutableNode] = [:]
        var order: [String] = []

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }

        func insert(_ components: ArraySlice<String>, file: ReviewFile, parentPath: String) {
            guard let next = components.first else {
                self.file = file
                return
            }
            let childPath = "\(parentPath)/\(next)"
            if children[next] == nil {
                children[next] = MutableNode(name: next, path: childPath)
                order.append(next)
            }
            children[next]?.insert(components.dropFirst(), file: file, parentPath: childPath)
        }

        func materialize() -> ReviewTreeNode {
            if let file {
                return ReviewTreeNode(path: path, name: name, kind: .file(file), children: [])
            }

            // Collapse `a/b/c` into one row while each level has exactly one
            // child and holds no file of its own.
            var displayName = name
            var node = self
            while node.children.count == 1, node.file == nil, let only = node.children[node.order[0]], only.file == nil {
                displayName += "/\(only.name)"
                node = only
            }

            let children = node.order
                .compactMap { node.children[$0]?.materialize() }
                .sorted(by: ReviewFileTreeBuilder.ordering)

            return ReviewTreeNode(
                path: node.path,
                name: displayName,
                kind: .directory,
                children: children
            )
        }
    }
}
