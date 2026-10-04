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
    /// The last transition surfaced to the user for each workstream.
    var shownTransitions: [ShownTransition] = []
    /// Most recent notifications, newest last.
    var notifications: [NotificationRecord] = []

    static let notificationHistoryLimit = 200
    static let unresolvedAssociationLimit = 50

    enum CodingKeys: String, CodingKey {
        case version, workstreams, links, hints, unresolvedAssociations, shownTransitions, notifications
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
        shownTransitions = try container.decode([ShownTransition].self, forKey: .shownTransitions)
        notifications = try container.decode([NotificationRecord].self, forKey: .notifications)
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

struct ShownTransition: Hashable, Sendable, Codable {
    let workstreamID: WorkstreamID
    let transition: AttentionTransition
}
