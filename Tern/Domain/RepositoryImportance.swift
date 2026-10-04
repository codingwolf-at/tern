/// How much a repository's work matters to the user. Set by the user; `normal` by default.
enum RepositoryImportance: String, Hashable, Sendable, Codable, CaseIterable {
    /// The user's main work: ranks first.
    case primary
    case normal
    /// Side projects: still tracked, ranked below normal work.
    case personal
    /// Tracked but never interrupts.
    case muted

    /// Canonical key: `github.com/owner/name`, lower-cased.
    static func key(forRepository repository: String) -> String {
        let trimmed = repository.lowercased()
        return trimmed.hasPrefix("github.com/") ? trimmed : "github.com/\(trimmed)"
    }
}
