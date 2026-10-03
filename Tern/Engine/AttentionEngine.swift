import Foundation

/// Deterministic pipeline that turns events into attention decisions:
///
///     Event → Workstream → State → Ownership → Attention → AttentionDecision
///
/// Raw events never notify directly. A notification is only warranted when the
/// evaluated decision hands the next action back to the user, or escalates it.
struct AttentionEngine: Sendable {
    private let resolver = OwnershipResolver()

    /// Records `event` on the workstream and re-evaluates it.
    func ingest(_ event: WorkEvent, into workstream: Workstream) -> Workstream {
        precondition(event.workstreamID == workstream.id, "Event belongs to a different workstream")
        var updated = workstream
        updated.events.append(event)
        updated.events.sort(by: WorkEvent.chronological)
        Self.applyReferences(from: updated.events, to: &updated)
        updated.evaluation = evaluate(updated.events)
        return updated
    }

    /// Re-derives a workstream's agent sessions and evaluation from its full history.
    func rebuild(_ workstream: Workstream) -> Workstream {
        var updated = workstream
        updated.events.sort(by: WorkEvent.chronological)
        Self.applyReferences(from: updated.events, to: &updated)
        updated.evaluation = evaluate(updated.events)
        return updated
    }

    /// Evaluates a history from scratch. The result depends only on the set of events,
    /// not on the order they were supplied in.
    ///
    /// Events are replayed one at a time so `shouldNotify` reflects the transition caused by
    /// the latest event, and `lastMeaningfulChange` records when the decision last moved.
    func evaluate(_ events: [WorkEvent]) -> WorkstreamEvaluation {
        var facts = WorkstreamFacts()
        var evaluation = WorkstreamEvaluation.initial

        for event in events.sorted(by: WorkEvent.chronological) {
            facts.apply(event)
            let resolution = resolver.resolve(facts)
            let previous = evaluation.decision
            let decision = AttentionDecision(
                shouldNotify: Self.shouldNotify(previous: previous, resolution: resolution),
                state: resolution.state,
                nextOwner: resolution.owner,
                attention: resolution.attention,
                nextAction: resolution.nextAction
            )
            let changed = decision.isMeaningfullyDifferent(from: previous)
            evaluation = WorkstreamEvaluation(
                decision: decision,
                status: resolution.status,
                lastMeaningfulChange: changed ? event.timestamp : evaluation.lastMeaningfulChange
            )
        }
        return evaluation
    }

    /// Quiet by default: only speak up when the turn comes back to the user
    /// with at least medium attention, or when an existing turn gets louder.
    private static func shouldNotify(previous: AttentionDecision, resolution: OwnershipResolver.Resolution) -> Bool {
        guard resolution.owner == .me, resolution.attention >= .medium else { return false }
        if previous.nextOwner != .me { return true }
        return resolution.attention > previous.attention
    }

    /// Event → Workstream: keeps agent sessions and calendar context in step with history.
    private static func applyReferences(from events: [WorkEvent], to workstream: inout Workstream) {
        workstream.agentSessions = agentSessions(from: events)
        if let meeting = events.last(where: { $0.kind == .calendarEventScheduled }),
           let title = meeting[.title],
           let startsAt = meeting[.startsAt].flatMap({ try? Date($0, strategy: .iso8601) }) {
            workstream.calendarContext = CalendarContext(title: title, startsAt: startsAt)
        }
    }

    private static func agentSessions(from events: [WorkEvent]) -> [AgentSession] {
        var sessions: [AgentSession] = []
        for event in events where event.source == .agent {
            let name = event[.agentName] ?? "Agent"
            let id = event[.agentSessionID] ?? name
            let status: AgentSession.Status
            switch event.kind {
            case .agentStarted: status = .working
            case .agentCompleted: status = .completed
            case .agentFailed: status = .failed
            default: continue
            }
            if let index = sessions.firstIndex(where: { $0.id == id }) {
                sessions[index].status = status
                sessions[index].updatedAt = event.timestamp
                if status == .working { sessions[index].startedAt = event.timestamp }
            } else {
                sessions.append(AgentSession(id: id, agentName: name, status: status, startedAt: event.timestamp, updatedAt: event.timestamp))
            }
        }
        return sessions
    }
}
