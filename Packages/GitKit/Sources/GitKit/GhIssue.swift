import Foundation

/// An open GitHub issue as the issue picker lists it.
public struct GhIssue: Identifiable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: URL
    public var labels: [String]
    public var updatedAt: Date?
    /// Filled by `gh issue view` only; the list call leaves it empty so a
    /// search over a large backlog stays a small payload.
    public var body: String

    public var id: Int { number }

    public init(number: Int, title: String, url: URL, labels: [String] = [], updatedAt: Date? = nil, body: String = "") {
        self.number = number
        self.title = title
        self.url = url
        self.labels = labels
        self.updatedAt = updatedAt
        self.body = body
    }
}

extension GhJSON {
    /// `gh issue list --json number,title,url,labels,updatedAt` (an array) or
    /// `gh issue view --json number,title,url,labels,updatedAt,body` (one object).
    public static func issues(from data: Data) throws -> [GhIssue] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([IssuePayload].self, from: data) {
            return list.compactMap(\.issue)
        }
        let single = try decoder.decode(IssuePayload.self, from: data)
        return single.issue.map { [$0] } ?? []
    }

    private struct IssuePayload: Decodable {
        struct Label: Decodable { let name: String }
        let number: Int
        let title: String
        let url: String
        let labels: [Label]?
        let updatedAt: Date?
        let body: String?

        var issue: GhIssue? {
            guard let url = URL(string: url) else { return nil }
            return GhIssue(
                number: number,
                title: title,
                url: url,
                labels: labels?.map(\.name) ?? [],
                updatedAt: updatedAt,
                body: body ?? ""
            )
        }
    }
}
