import Foundation

/// An open GitHub issue as the issue picker lists it.
public struct GhIssue: Identifiable, Equatable, Sendable {
    public var number: Int
    public var title: String
    public var url: URL
    public var labels: [String]
    /// Label name → GitHub's hex colour (no `#`), for tinting tags.
    public var labelColors: [String: String]
    public var updatedAt: Date?
    /// Empty when the source left it out (as older list payloads did).
    public var body: String

    public var id: Int { number }

    public init(number: Int, title: String, url: URL, labels: [String] = [], labelColors: [String: String] = [:], updatedAt: Date? = nil, body: String = "") {
        self.number = number
        self.title = title
        self.url = url
        self.labels = labels
        self.labelColors = labelColors
        self.updatedAt = updatedAt
        self.body = body
    }
}

extension GhJSON {
    /// `gh issue list --json number,title,url,labels,updatedAt,body` (an array) or
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
        struct Label: Decodable { let name: String; let color: String? }
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
                labelColors: Dictionary((labels ?? []).compactMap { label in label.color.map { (label.name, $0) } }, uniquingKeysWith: { first, _ in first }),
                updatedAt: updatedAt,
                body: body ?? ""
            )
        }
    }
}
