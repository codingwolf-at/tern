import Foundation

/// Facts accumulated by folding a workstream's events in chronological order.
/// Each fact keeps a `Stamp` of the event that established it, so the engine can reason
/// about which signals supersede which and name the cause of its decision.
struct WorkstreamFacts: Hashable, Sendable {
    /// The event a fact came from.
    struct Stamp: Hashable, Sendable {
        let id: EventID
        let at: Date

        init(_ event: WorkEvent) {
            id = event.id
            at = event.timestamp
        }

        /// Total order: by time, then by ID, so ties never depend on input order.
        static func isOrderedBefore(_ lhs: Stamp, _ rhs: Stamp) -> Bool {
            lhs.at != rhs.at ? lhs.at < rhs.at : lhs.id < rhs.id
        }
    }

    /// One agent session. Sessions are tracked independently; a new session never
    /// erases what an earlier one produced. A session hosts many turns; `status`
    /// describes the latest turn, and `isEnded` whether the session itself has closed.
    struct AgentRun: Hashable, Sendable {
        enum Status: Hashable, Sendable {
            /// Open, but no turn has run yet.
            case idle
            case working
            case needsInput(prompt: String?)
            /// The turn finished and handed control back to the user.
            case finished
            case failed(reason: String?)
        }

        let sessionID: String
        var name: String
        var status: Status
        /// When the current turn began. Resuming a turn that is still in progress keeps it.
        var started: Stamp
        var updated: Stamp
        /// Set once the user has picked up the turn's outcome.
        var isAcknowledged = false
        /// The session has closed. Its history stays; it no longer claims anything.
        var isEnded = false

        var isInProgress: Bool {
            switch status {
            case .working, .needsInput: !isEnded
            case .idle, .finished, .failed: false
            }
        }

        var shortName: String {
            name.split(separator: " ").first.map(String.init) ?? name
        }
    }

    enum Review: Hashable, Sendable {
        case none
        case awaiting(reviewer: String?, Stamp)
        case changesRequested(reviewer: String?, comments: Int?, Stamp)
        case responded(reviewer: String?, comments: Int?, Stamp)
        case approved(reviewer: String?, Stamp)
    }

    enum CI: Hashable, Sendable {
        case unknown
        case running(Stamp)
        case passed(Stamp)
        case failed(check: String?, Stamp)
    }

    struct Blocked: Hashable, Sendable {
        let reason: String?
        let stamp: Stamp
    }

    struct Completion: Hashable, Sendable {
        let reason: String
        let stamp: Stamp
    }

    var planeItem: Stamp?
    var pullRequest: Stamp?
    /// Agent sessions keyed by session ID.
    var agentRuns: [String: AgentRun] = [:]
    var review: Review = .none
    var ci: CI = .unknown
    var blocked: Blocked?
    var completion: Completion?

    var isComplete: Bool { completion != nil }

    /// Sessions in a stable order (by start, then ID).
    var orderedAgentRuns: [AgentRun] {
        agentRuns.values.sorted { lhs, rhs in
            lhs.started == rhs.started
                ? lhs.sessionID < rhs.sessionID
                : Stamp.isOrderedBefore(lhs.started, rhs.started)
        }
    }

    init() {}

    init(events: [WorkEvent]) {
        for event in events.sorted(by: WorkEvent.chronological) {
            apply(event)
        }
    }

    /// Whether an agent turn that began after `stamp` has taken on (or finished) the work.
    /// Failed turns and sessions closed mid-turn do not count: the requested work was not done.
    func isAddressedByAgent(after stamp: Stamp) -> Bool {
        agentRuns.values.contains { run in
            guard Stamp.isOrderedBefore(stamp, run.started) else { return false }
            switch run.status {
            case .finished: return true
            case .working, .needsInput: return run.isInProgress
            case .idle, .failed: return false
            }
        }
    }

    mutating func apply(_ event: WorkEvent) {
        let stamp = Stamp(event)
        switch event.kind {
        case .planeItemCreated:
            planeItem = planeItem ?? stamp
        case .planeItemBlocked:
            blocked = Blocked(reason: event[.reason], stamp: stamp)
        case .planeItemUnblocked:
            blocked = nil
        case .planeItemCompleted:
            complete(stamp, reason: "Marked done in Plane")

        case .pullRequestOpened:
            pullRequest = pullRequest ?? stamp
        case .reviewRequested:
            review = .awaiting(reviewer: event[.reviewer], stamp)
        case .changesRequested:
            review = .changesRequested(reviewer: event[.reviewer], comments: event[.commentCount].flatMap { Int($0) }, stamp)
        case .reviewerResponded:
            review = .responded(reviewer: event[.reviewer], comments: event[.commentCount].flatMap { Int($0) }, stamp)
        case .reviewApproved:
            review = .approved(reviewer: event[.reviewer], stamp)
        case .commitsPushed:
            // Pushing work means the user has picked up whatever the agents produced.
            for (id, run) in agentRuns where run.status == .finished {
                agentRuns[id]?.isAcknowledged = true
            }
        case .ciStarted:
            ci = .running(stamp)
        case .ciPassed:
            ci = .passed(stamp)
        case .ciFailed:
            ci = .failed(check: event[.checkName], stamp)
        case .pullRequestMerged:
            complete(stamp, reason: "Merged")
        case .pullRequestClosed:
            complete(stamp, reason: "Closed")

        case .agentSessionOpened:
            // Registers the session only. Also fires mid-turn (e.g. after compaction),
            // so it never changes the state of a session that is already known.
            if agentRuns[sessionID(for: event)] == nil {
                updateRun(for: event, stamp: stamp, status: .idle)
            }
        case .agentStarted:
            updateRun(for: event, stamp: stamp, status: .working)
        case .agentNeedsInput:
            updateRun(for: event, stamp: stamp, status: .needsInput(prompt: event[.prompt]))
        case .agentResumed:
            if let run = agentRuns[sessionID(for: event)], case .needsInput = run.status {
                updateRun(for: event, stamp: stamp, status: .working)
            }
        case .agentCompleted:
            updateRun(for: event, stamp: stamp, status: .finished)
        case .agentFailed:
            updateRun(for: event, stamp: stamp, status: .failed(reason: event[.reason]))
        case .agentSessionEnded:
            // Closing the session is the user's own action: whatever it last produced has been seen.
            let id = sessionID(for: event)
            agentRuns[id]?.isEnded = true
            agentRuns[id]?.isAcknowledged = true
            if agentRuns[id] != nil { agentRuns[id]?.updated = stamp }

        default:
            // Unknown or context-only kinds (e.g. calendar) do not change ownership.
            break
        }
    }

    private func sessionID(for event: WorkEvent) -> String {
        event[.agentSessionID] ?? event[.agentName] ?? "agent"
    }

    private mutating func updateRun(for event: WorkEvent, stamp: Stamp, status: AgentRun.Status) {
        let sessionID = sessionID(for: event)
        if var run = agentRuns[sessionID] {
            // A start on a turn that is already in progress is a resume, not a new turn.
            let isNewTurn = status == .working && !run.isInProgress
            if isNewTurn {
                run.started = stamp
                run.isAcknowledged = false
                run.isEnded = false
            }
            run.name = event[.agentName] ?? run.name
            run.status = status
            run.updated = stamp
            agentRuns[sessionID] = run
        } else {
            agentRuns[sessionID] = AgentRun(
                sessionID: sessionID,
                name: event[.agentName] ?? "Agent",
                status: status,
                started: stamp,
                updated: stamp
            )
        }
    }

    private mutating func complete(_ stamp: Stamp, reason: String) {
        if completion == nil {
            completion = Completion(reason: reason, stamp: stamp)
        }
    }
}
