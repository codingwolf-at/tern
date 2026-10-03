import Foundation

/// Facts accumulated by folding a workstream's events in chronological order.
/// Each fact keeps the timestamp it became true, so the engine can reason about
/// which signals supersede which.
struct WorkstreamFacts: Hashable, Sendable {
    enum AgentActivity: Hashable, Sendable {
        case idle
        case working(name: String, since: Date)
        case finished(name: String, startedAt: Date, at: Date)
        case failed(name: String, startedAt: Date, at: Date, reason: String?)

        /// When the agent's most recent run began, if any.
        var startedAt: Date? {
            switch self {
            case .idle: nil
            case .working(_, let since): since
            case .finished(_, let startedAt, _), .failed(_, let startedAt, _, _): startedAt
            }
        }
    }

    enum Review: Hashable, Sendable {
        case none
        case awaiting(reviewer: String?, since: Date)
        case changesRequested(reviewer: String?, comments: Int?, at: Date)
        case responded(reviewer: String?, comments: Int?, at: Date)
        case approved(reviewer: String?, at: Date)
    }

    struct Blocked: Hashable, Sendable {
        let reason: String?
        let since: Date
    }

    enum CI: Hashable, Sendable {
        case unknown
        case running(since: Date)
        case passed(at: Date)
        case failed(check: String?, at: Date)
    }

    var hasPlaneItem = false
    var hasPullRequest = false
    var agent: AgentActivity = .idle
    var review: Review = .none
    var ci: CI = .unknown
    var blocked: Blocked?
    var completedAt: Date?
    var completionReason: String?

    var isComplete: Bool { completedAt != nil }

    init() {}

    init(events: [WorkEvent]) {
        for event in events.sorted(by: WorkEvent.chronological) {
            apply(event)
        }
    }

    mutating func apply(_ event: WorkEvent) {
        let at = event.timestamp
        switch event.kind {
        case .planeItemCreated:
            hasPlaneItem = true
        case .planeItemBlocked:
            blocked = Blocked(reason: event[.reason], since: at)
        case .planeItemUnblocked:
            blocked = nil
        case .planeItemCompleted:
            complete(at: at, reason: "Marked done in Plane")

        case .pullRequestOpened:
            hasPullRequest = true
        case .reviewRequested:
            review = .awaiting(reviewer: event[.reviewer], since: at)
        case .changesRequested:
            review = .changesRequested(reviewer: event[.reviewer], comments: event[.commentCount].flatMap { Int($0) }, at: at)
        case .reviewerResponded:
            review = .responded(reviewer: event[.reviewer], comments: event[.commentCount].flatMap { Int($0) }, at: at)
        case .reviewApproved:
            review = .approved(reviewer: event[.reviewer], at: at)
        case .commitsPushed:
            // Pushing work means the user has picked up whatever the agent produced.
            if case .finished = agent { agent = .idle }
        case .ciStarted:
            ci = .running(since: at)
        case .ciPassed:
            ci = .passed(at: at)
        case .ciFailed:
            ci = .failed(check: event[.checkName], at: at)
        case .pullRequestMerged:
            complete(at: at, reason: "Merged")
        case .pullRequestClosed:
            complete(at: at, reason: "Closed")

        case .agentStarted:
            agent = .working(name: event[.agentName] ?? "Agent", since: at)
        case .agentCompleted:
            agent = .finished(name: event[.agentName] ?? agentName, startedAt: agent.startedAt ?? at, at: at)
        case .agentFailed:
            agent = .failed(name: event[.agentName] ?? agentName, startedAt: agent.startedAt ?? at, at: at, reason: event[.reason])

        default:
            // Unknown or context-only kinds (e.g. calendar) do not change ownership.
            break
        }
    }

    private var agentName: String {
        switch agent {
        case .idle: "Agent"
        case .working(let name, _), .finished(let name, _, _), .failed(let name, _, _, _): name
        }
    }

    private mutating func complete(at: Date, reason: String) {
        if completedAt == nil {
            completedAt = at
            completionReason = reason
        }
    }
}
