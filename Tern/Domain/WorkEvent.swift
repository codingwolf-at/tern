import Foundation

/// System an event originated from.
enum EventSource: String, Hashable, Sendable, Codable, CaseIterable {
    case github
    case plane
    case agent
    case calendar
}

/// Stable identity of an event, assigned by the integration that observed it.
/// Seeing the same source event again must produce the same ID, e.g.
/// `github:review:<review-id>` or `agent:session:<session-id>:stop:<sequence>`.
/// Ingestion uses it to drop repeats from polling or replays.
struct EventID: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Builds an ID namespaced by source, e.g. `EventID(.github, "review", "123")` → `github:review:123`.
    init(_ source: EventSource, _ components: String...) {
        self.rawValue = ([source.rawValue] + components).joined(separator: ":")
    }

    static func < (lhs: EventID, rhs: EventID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Open-ended event type. Integrations can declare new kinds in their own extensions
/// without changing the core model; the engine ignores kinds it does not understand.
struct WorkEventKind: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension WorkEventKind {
    // Plane
    static let planeItemCreated = WorkEventKind(rawValue: "plane.item.created")
    static let planeItemBlocked = WorkEventKind(rawValue: "plane.item.blocked")
    static let planeItemUnblocked = WorkEventKind(rawValue: "plane.item.unblocked")
    static let planeItemCompleted = WorkEventKind(rawValue: "plane.item.completed")

    // GitHub
    static let pullRequestOpened = WorkEventKind(rawValue: "github.pr.opened")
    static let reviewRequested = WorkEventKind(rawValue: "github.review.requested")
    static let changesRequested = WorkEventKind(rawValue: "github.review.changes_requested")
    static let reviewerResponded = WorkEventKind(rawValue: "github.review.responded")
    static let reviewApproved = WorkEventKind(rawValue: "github.review.approved")
    static let commitsPushed = WorkEventKind(rawValue: "github.commits.pushed")
    static let ciStarted = WorkEventKind(rawValue: "github.ci.started")
    static let ciPassed = WorkEventKind(rawValue: "github.ci.passed")
    static let ciFailed = WorkEventKind(rawValue: "github.ci.failed")
    static let pullRequestMerged = WorkEventKind(rawValue: "github.pr.merged")
    static let pullRequestClosed = WorkEventKind(rawValue: "github.pr.closed")

    // Agents
    static let agentStarted = WorkEventKind(rawValue: "agent.session.started")
    static let agentNeedsInput = WorkEventKind(rawValue: "agent.session.needs_input")
    static let agentCompleted = WorkEventKind(rawValue: "agent.session.completed")
    static let agentFailed = WorkEventKind(rawValue: "agent.session.failed")

    // Calendar
    static let calendarEventScheduled = WorkEventKind(rawValue: "calendar.event.scheduled")
}

/// A normalized event that has been linked to a workstream.
struct WorkEvent: Identifiable, Hashable, Sendable, Codable {
    let id: EventID
    let workstreamID: WorkstreamID
    let source: EventSource
    let kind: WorkEventKind
    let timestamp: Date
    let metadata: [String: String]

    init(
        id: EventID,
        workstreamID: WorkstreamID,
        source: EventSource,
        kind: WorkEventKind,
        timestamp: Date,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.workstreamID = workstreamID
        self.source = source
        self.kind = kind
        self.timestamp = timestamp
        self.metadata = metadata
    }

    subscript(key: MetadataKey) -> String? {
        metadata[key.rawValue]
    }
}

/// Well-known metadata keys. Integrations may store additional keys as plain strings.
struct MetadataKey: RawRepresentable, Hashable, Sendable {
    let rawValue: String

    static let reviewer = MetadataKey(rawValue: "reviewer")
    static let commentCount = MetadataKey(rawValue: "commentCount")
    static let agentName = MetadataKey(rawValue: "agentName")
    static let agentSessionID = MetadataKey(rawValue: "agentSessionID")
    static let prompt = MetadataKey(rawValue: "prompt")
    static let checkName = MetadataKey(rawValue: "checkName")
    static let reason = MetadataKey(rawValue: "reason")
    static let title = MetadataKey(rawValue: "title")
    static let startsAt = MetadataKey(rawValue: "startsAt")
}

extension WorkEvent {
    /// Chronological order with a stable tie-break, so evaluation never depends on insertion order.
    static func chronological(_ lhs: WorkEvent, _ rhs: WorkEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        return lhs.id < rhs.id
    }
}
