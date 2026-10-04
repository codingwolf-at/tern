import Foundation

/// Everything Tern needs to survive a relaunch. Only source-of-truth data is stored;
/// workstream state, ownership and attention are rebuilt from events on load.
struct PersistedState: Hashable, Sendable, Codable {
    static let currentVersion = 1

    var version = PersistedState.currentVersion
    /// Workstreams with their event history. Event IDs double as the seen-event set.
    var workstreams: [WorkstreamRecord] = []
    var links: [WorkstreamLink] = []
    /// Mentions that may later associate an item with a workstream.
    var hints: [WorkstreamHint] = []
    /// Associations declined as ambiguous or conflicting, newest last.
    var unresolvedAssociations: [AssociationIssue] = []
    /// Sources whose initial history import has finished, e.g. `github:octocat`. Lives with the
    /// events it describes, so the two can never disagree.
    var completedImports: [String] = []
    /// How much each repository matters to the user (`github.com/owner/name` → importance).
    var repositoryImportance: [String: RepositoryImportance] = [:]
    /// Which context the user is looking at, and which repositories belong to which context.
    var activeContext: TernContext = .professional
    var contextRules = ContextRules()
    /// The last transition surfaced to the user for each attention subject (workstream or meeting).
    var shownTransitions: [ShownTransition] = []
    /// Most recent notifications, newest last.
    var notifications: [NotificationRecord] = []

    static let notificationHistoryLimit = 200
    static let unresolvedAssociationLimit = 50

    enum CodingKeys: String, CodingKey {
        case version, workstreams, links, hints, unresolvedAssociations, completedImports, repositoryImportance
        case activeContext, contextRules, shownTransitions, notifications
    }

    init() {}

    /// Tolerates state written before newer fields existed.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        workstreams = try container.decode([WorkstreamRecord].self, forKey: .workstreams)
        links = try container.decode([WorkstreamLink].self, forKey: .links)
        hints = try container.decodeIfPresent([WorkstreamHint].self, forKey: .hints) ?? []
        unresolvedAssociations = try container.decodeIfPresent([AssociationIssue].self, forKey: .unresolvedAssociations) ?? []
        completedImports = try container.decodeIfPresent([String].self, forKey: .completedImports) ?? []
        repositoryImportance = try container.decodeIfPresent([String: RepositoryImportance].self, forKey: .repositoryImportance) ?? [:]
        activeContext = try container.decodeIfPresent(TernContext.self, forKey: .activeContext) ?? .professional
        contextRules = try container.decodeIfPresent(ContextRules.self, forKey: .contextRules) ?? ContextRules()
        shownTransitions = try container.decodeIfPresent([ShownTransition].self, forKey: .shownTransitions) ?? []
        notifications = try container.decodeIfPresent([NotificationRecord].self, forKey: .notifications) ?? []
    }
}

/// The non-derived part of a workstream.
struct WorkstreamRecord: Hashable, Sendable, Codable {
    let id: WorkstreamID
    var title: String
    var planeItem: PlaneItemReference?
    var pullRequest: PullRequestReference?
    var events: [WorkEvent]
}

/// The last transition surfaced for one attention subject.
struct ShownTransition: Hashable, Sendable, Codable {
    let subjectID: SubjectID
    let transition: AttentionTransition
    /// Fingerprints of transitions already shown for this subject (newest last), so coming
    /// back to one — e.g. after an agent turn — isn't news.
    var seen: [String] = []

    static let seenLimit = 50

    enum CodingKeys: String, CodingKey {
        case subjectID, transition, seen
    }

    init(subjectID: SubjectID, transition: AttentionTransition, seen: [String] = []) {
        self.subjectID = subjectID
        self.transition = transition
        self.seen = seen
    }

    /// Reads records saved before subjects existed, keyed `workstreamID` and without `seen`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjectID = try SubjectID.decode(from: decoder, container, key: .subjectID)
        transition = try container.decode(AttentionTransition.self, forKey: .transition)
        seen = try container.decodeIfPresent([String].self, forKey: .seen) ?? [transition.fingerprint]
    }
}

extension SubjectID {
    private struct LegacyKey: CodingKey {
        static let workstreamID = LegacyKey(stringValue: "workstreamID")
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Decodes `key`, falling back to the `workstreamID` key that records used before meetings
    /// existed. A workstream's subject ID equals its workstream ID, so old records keep matching.
    static func decode<Key: CodingKey>(from decoder: any Decoder, _ container: KeyedDecodingContainer<Key>, key: Key) throws -> SubjectID {
        if let id = try container.decodeIfPresent(SubjectID.self, forKey: key) { return id }
        return try decoder.container(keyedBy: LegacyKey.self).decode(SubjectID.self, forKey: .workstreamID)
    }
}
