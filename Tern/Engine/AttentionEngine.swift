import Foundation

/// Deterministic pipeline that turns a workstream's event history into its current state:
///
///     Events → Facts → State & Ownership → Attention → AttentionDecision
///
/// The engine is a pure function of the event set. It does not decide whether to notify;
/// that depends on what the user has already been shown (see `NotificationPolicy`), so
/// every decision it returns has `shouldNotify == false`.
struct AttentionEngine: Sendable {
    private let resolver: OwnershipResolver

    init(rules: WorkflowRules = .none) {
        resolver = OwnershipResolver(rules: rules)
    }

    /// Re-derives a workstream's agent sessions and evaluation from its history.
    func rebuild(_ workstream: Workstream) -> Workstream {
        var updated = workstream
        updated.events.sort(by: WorkEvent.chronological)
        let (evaluation, facts) = replay(updated.events)
        updated.evaluation = evaluation
        updated.agentSessions = facts.orderedAgentRuns.map(Self.session)
        return updated
    }

    /// Evaluates a history from scratch. The result depends only on the set of events,
    /// not on the order they were supplied in.
    func evaluate(_ events: [WorkEvent]) -> WorkstreamEvaluation {
        replay(events.sorted(by: WorkEvent.chronological)).evaluation
    }

    /// Replays sorted events one at a time so `lastMeaningfulChange` records when the decision last moved.
    private func replay(_ sorted: [WorkEvent]) -> (evaluation: WorkstreamEvaluation, facts: WorkstreamFacts) {
        var facts = WorkstreamFacts()
        var evaluation = WorkstreamEvaluation.initial

        for event in sorted {
            facts.apply(event)
            let resolution = resolver.resolve(facts)
            let decision = AttentionDecision(
                shouldNotify: false,
                state: resolution.state,
                nextOwner: resolution.owner,
                attention: resolution.attention,
                nextAction: resolution.nextAction,
                reason: resolution.reason
            )
            let changed = decision.isMeaningfullyDifferent(from: evaluation.decision)
            evaluation = WorkstreamEvaluation(
                decision: decision,
                status: resolution.status,
                lastMeaningfulChange: changed ? event.timestamp : evaluation.lastMeaningfulChange,
                transition: AttentionTransition(
                    state: resolution.state,
                    owner: resolution.owner,
                    attention: resolution.attention,
                    causeID: resolution.cause?.id,
                    causeAt: resolution.cause?.at
                )
            )
        }
        return (evaluation, facts)
    }

    private static func session(from run: WorkstreamFacts.AgentRun) -> AgentSession {
        let status: AgentSession.Status = if run.isEnded {
            .ended
        } else {
            switch run.status {
            case .idle: .idle
            case .working: .working
            case .needsInput: .needsInput
            case .finished: .completed
            case .failed: .failed
            }
        }
        return AgentSession(id: run.sessionID, agentName: run.name, status: status, startedAt: run.started.at, updatedAt: run.updated.at)
    }
}
