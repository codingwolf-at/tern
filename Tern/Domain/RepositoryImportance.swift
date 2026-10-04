/// How much a repository's work matters to the user, for ranking only. Set by the user;
/// `normal` by default. Unrelated to Personal/Professional contexts (see `TernContext`), which
/// decide whether work is shown at all.
enum RepositoryImportance: String, Hashable, Sendable, Codable, CaseIterable {
    /// The user's main work: ranks first.
    case primary
    case normal
    /// Still tracked, ranked below normal work.
    case lowPriority
    /// Tracked but never interrupts.
    case muted

    var title: String {
        switch self {
        case .primary: "Primary"
        case .normal: "Normal"
        case .lowPriority: "Low priority"
        case .muted: "Muted"
        }
    }

    /// Reads current values and `personal`, the name `lowPriority` had before contexts existed.
    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        if raw == "personal" {
            self = .lowPriority
        } else if let value = RepositoryImportance(rawValue: raw) {
            self = value
        } else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown importance \(raw)"))
        }
    }

    /// Canonical key: `github.com/owner/name`, lower-cased.
    static func key(forRepository repository: String) -> String {
        let trimmed = repository.lowercased()
        return trimmed.hasPrefix("github.com/") ? trimmed : "github.com/\(trimmed)"
    }
}
