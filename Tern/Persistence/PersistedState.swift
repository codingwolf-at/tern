import Foundation

/// Everything Tern needs to survive a relaunch. Only source-of-truth data is stored;
/// workstream state, ownership and attention are rebuilt from events on load.
struct PersistedState: Hashable, Sendable, Codable {
    static let currentVersion = 1

    var version = PersistedState.currentVersion
    /// Workstreams with their event history. Event IDs double as the seen-event set.
    var workstreams: [WorkstreamRecord] = []
    var links: [WorkstreamLink] = []
    /// The last transition surfaced to the user for each workstream.
    var shownTransitions: [ShownTransition] = []
    /// Most recent notifications, newest last.
    var notifications: [NotificationRecord] = []

    static let notificationHistoryLimit = 200
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
