import Foundation

/// Which side of the user's life Tern is looking at. Only the active context's work takes
/// part in the attention queue, ranking, notifications and the menu bar badge.
enum TernContext: String, Hashable, Sendable, Codable, CaseIterable {
    case personal
    case professional

    var title: String {
        switch self {
        case .personal: "Personal"
        case .professional: "Professional"
        }
    }
}

/// Where an attention subject (a workstream or a meeting) belongs. An `unclassified` subject
/// takes part in neither context until the user classifies its repository or calendar.
enum SubjectContext: Hashable, Sendable {
    case personal
    case professional
    case unclassified

    var title: String {
        switch self {
        case .personal: "Personal"
        case .professional: "Professional"
        case .unclassified: "Unclassified"
        }
    }

    init(_ context: TernContext) {
        switch context {
        case .personal: self = .personal
        case .professional: self = .professional
        }
    }

    func isIn(_ context: TernContext) -> Bool {
        self == SubjectContext(context)
    }
}

extension TernContext {
    /// `nil` for an unclassified subject, which belongs to neither context.
    init?(_ context: SubjectContext) {
        switch context {
        case .personal: self = .personal
        case .professional: self = .professional
        case .unclassified: return nil
        }
    }
}

/// The user's statement of which GitHub owners, repositories and calendars are personal and
/// which are professional. Nothing is inferred: anything matching no rule is unclassified.
///
/// Workstreams are classified as follows:
/// - A repository rule wins over its owner's rule.
/// - Plane is professional-only: a workstream with a Plane item is professional, unless its
///   repository is explicitly personal, which is a conflict and leaves it unclassified.
/// - Without a repository or a Plane item (e.g. a Claude session outside a GitHub checkout),
///   a workstream is unclassified.
struct ContextRules: Hashable, Sendable, Codable {
    /// GitHub users and organizations, lower-cased (`makeplane` → professional).
    var owners: [String: TernContext] = [:]
    /// Exceptions for single repositories, keyed `github.com/owner/name`.
    var repositories: [String: TernContext] = [:]
    /// macOS calendars by `calendarIdentifier`. A calendar without a rule is unclassified.
    var calendars: [String: TernContext] = [:]

    static let none = ContextRules()

    init() {}

    /// Tolerates rules saved before calendars could be classified.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        owners = try container.decodeIfPresent([String: TernContext].self, forKey: .owners) ?? [:]
        repositories = try container.decodeIfPresent([String: TernContext].self, forKey: .repositories) ?? [:]
        calendars = try container.decodeIfPresent([String: TernContext].self, forKey: .calendars) ?? [:]
    }

    func context(forCalendar calendarID: String) -> SubjectContext {
        calendars[calendarID].map(SubjectContext.init) ?? .unclassified
    }

    /// Sets (or with `nil`, clears) a calendar's context.
    mutating func set(_ context: TernContext?, forCalendar calendarID: String) {
        calendars[calendarID] = context
    }

    /// `github.com/owner/name` (or `owner/name`) → its context.
    func context(forRepository repository: String) -> SubjectContext {
        let key = RepositoryImportance.key(forRepository: repository)
        if let context = repositories[key] { return SubjectContext(context) }
        if let owner = Self.owner(of: key), let context = owners[owner] { return SubjectContext(context) }
        return .unclassified
    }

    func context(of workstream: Workstream) -> SubjectContext {
        let repository = workstream.repositoryKey.map(context(forRepository:))
        if workstream.planeItem != nil {
            return repository == .personal ? .unclassified : .professional
        }
        return repository ?? .unclassified
    }

    /// Sets (or with `nil`, clears) the context of everything an owner has.
    mutating func set(_ context: TernContext?, forOwner owner: String) {
        owners[owner.lowercased()] = context
    }

    /// Sets (or with `nil`, clears) one repository's context, overriding its owner.
    mutating func set(_ context: TernContext?, forRepository repository: String) {
        repositories[RepositoryImportance.key(forRepository: repository)] = context
    }

    /// `github.com/owner/name` → `owner`.
    static func owner(of repositoryKey: String) -> String? {
        let parts = RepositoryImportance.key(forRepository: repositoryKey).split(separator: "/")
        return parts.count >= 3 ? String(parts[1]) : nil
    }
}
