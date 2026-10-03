import Foundation

struct WorkstreamID: RawRepresentable, Hashable, Sendable, Codable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Short, human-facing description of where a workstream stands right now.
struct StatusLine: Hashable, Sendable, Codable {
    var headline: String
    var detail: String?
    /// The system the current status is about; lets the UI label the row with the relevant reference.
    var focus: EventSource?
}

/// Everything the engine derives for a workstream. Written only by `AttentionEngine`.
struct WorkstreamEvaluation: Hashable, Sendable, Codable {
    var decision: AttentionDecision
    var status: StatusLine
    var lastMeaningfulChange: Date?
    var transition: AttentionTransition

    static let initial = WorkstreamEvaluation(
        decision: .initial,
        status: StatusLine(headline: "No activity yet"),
        lastMeaningfulChange: nil,
        transition: .initial
    )
}

/// One piece of work, tracked across Plane, GitHub, agents and the calendar.
struct Workstream: Identifiable, Hashable, Sendable {
    let id: WorkstreamID
    var title: String
    var planeItem: PlaneItemReference?
    var pullRequest: PullRequestReference?
    var agentSessions: [AgentSession]
    /// Derived from calendar events; context only, never used for ownership.
    var calendarContext: CalendarContext?
    /// Event history in chronological order.
    var events: [WorkEvent]
    var evaluation: WorkstreamEvaluation

    init(
        id: WorkstreamID,
        title: String,
        planeItem: PlaneItemReference? = nil,
        pullRequest: PullRequestReference? = nil,
        agentSessions: [AgentSession] = [],
        calendarContext: CalendarContext? = nil,
        events: [WorkEvent] = [],
        evaluation: WorkstreamEvaluation = .initial
    ) {
        self.id = id
        self.title = title
        self.planeItem = planeItem
        self.pullRequest = pullRequest
        self.agentSessions = agentSessions
        self.calendarContext = calendarContext
        self.events = events
        self.evaluation = evaluation
    }

    // Derived values, exposed for convenience.
    var state: WorkstreamState { evaluation.decision.state }
    var nextOwner: Owner { evaluation.decision.nextOwner }
    var attention: AttentionLevel { evaluation.decision.attention }
    var nextAction: NextAction? { evaluation.decision.nextAction }
    var status: StatusLine { evaluation.status }
    var lastMeaningfulChange: Date? { evaluation.lastMeaningfulChange }
}
