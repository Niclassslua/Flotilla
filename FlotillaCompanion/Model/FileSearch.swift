import Foundation

/// One line matching a file-viewer search.
struct FileSearchMatch: Identifiable, Equatable {
    var id: Int { lineIndex }
    let lineIndex: Int
}

/// Searches the file's lines as currently loaded — the file is fetched
/// whole, so there's no older/paged content to miss.
enum FileSearch {
    static func matches(in lines: [String], query: String) -> [FileSearchMatch] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }
        return lines.indices.compactMap { index in
            lines[index].range(of: needle, options: .caseInsensitive) != nil ? FileSearchMatch(lineIndex: index) : nil
        }
    }
}
