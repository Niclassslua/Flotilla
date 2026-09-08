import Foundation

struct RuleFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String
    let scope: RuleScope

    var id: URL { url }
    var name: String { relativePath }
}

enum RuleScope: String, Sendable, Hashable {
    case global
    case project
}

