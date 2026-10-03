import Foundation

/// Turns accumulated facts into who owns the next action and how loudly it matters.
///
/// Rules, in order:
/// 1. Completed work is silent and owned by nobody.
/// 2. Anything that is the user's turn wins (agent needs input or failed, CI failure, review
///    feedback, finished agent turn, approval ready to merge). Review/CI feedback counts as
///    handled while an agent turn that started *after* it is in progress or has finished;
///    a failed turn does not handle it. Closed sessions claim nothing. Loudest claim wins;
///    ties go to the newest.
/// 3. Externally blocked work is owned by `external`.
/// 4. Otherwise the ball is with an agent, CI, or a reviewer, in that order, and stays silent.
/// 5. With nothing pending, an open PR or Plane item is a low-priority nudge for the user.
/// 6. An open or closed agent session with nothing pending is owned by nobody.
///
/// Every resolution names the event that caused it, which makes the result's
/// `AttentionTransition` stable across replays.
struct OwnershipResolver: Sendable {
    typealias Stamp = WorkstreamFacts.Stamp

    struct Resolution: Hashable, Sendable {
        let state: WorkstreamState
        let owner: Owner
        let attention: AttentionLevel
        let nextAction: NextAction?
        let status: StatusLine
        let cause: Stamp?
    }

    private struct Claim {
        let attention: AttentionLevel
        let cause: Stamp
        let action: NextAction
        let status: StatusLine
    }

    func resolve(_ facts: WorkstreamFacts) -> Resolution {
        if let completion = facts.completion {
            return Resolution(
                state: .complete,
                owner: .none,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: "Done", detail: completion.reason),
                cause: completion.stamp
            )
        }

        if let claim = strongestClaimOnMe(facts) {
            return Resolution(
                state: .needsAttention,
                owner: .me,
                attention: claim.attention,
                nextAction: claim.action,
                status: claim.status,
                cause: claim.cause
            )
        }

        if let blocked = facts.blocked {
            return Resolution(
                state: .blocked,
                owner: .external,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: "Blocked", detail: blocked.reason, focus: .plane),
                cause: blocked.stamp
            )
        }

        let working = facts.orderedAgentRuns.filter { $0.status == .working && $0.isInProgress }
        if let latest = working.last {
            let headline = working.count == 1 ? "\(latest.shortName) working" : "\(working.count) agents working"
            return waiting(on: .agent, state: .active, StatusLine(headline: headline, focus: .agent), latest.started)
        }
        if case .running(let stamp) = facts.ci {
            return waiting(on: .ci, state: .waiting, StatusLine(headline: "CI running", focus: .github), stamp)
        }
        if case .awaiting(let reviewer, let stamp) = facts.review {
            let headline = reviewer.map { "Waiting for \($0)" } ?? "Waiting for review"
            return waiting(on: .reviewer, state: .waiting, StatusLine(headline: headline, focus: .github), stamp)
        }

        if let opened = facts.pullRequest {
            return Resolution(
                state: .active,
                owner: .me,
                attention: .low,
                nextAction: NextAction(title: "Request a review", reason: "Pull request has no reviewer yet", estimatedMinutes: 2),
                status: StatusLine(headline: "PR open", detail: "No reviewer yet", focus: .github),
                cause: opened
            )
        }
        if let created = facts.planeItem {
            return Resolution(
                state: .active,
                owner: .me,
                attention: .low,
                nextAction: NextAction(title: "Start work", reason: "Work item is ready to pick up"),
                status: StatusLine(headline: "Ready to start", focus: .plane),
                cause: created
            )
        }

        if let latest = facts.orderedAgentRuns.max(by: { Stamp.isOrderedBefore($0.updated, $1.updated) }) {
            let headline = latest.isEnded ? "\(latest.shortName) session ended" : "\(latest.shortName) idle"
            return Resolution(
                state: .active,
                owner: .none,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: headline, focus: .agent),
                cause: latest.updated
            )
        }

        return Resolution(
            state: .active,
            owner: .none,
            attention: .silent,
            nextAction: nil,
            status: WorkstreamEvaluation.initial.status,
            cause: nil
        )
    }

    private func waiting(on owner: Owner, state: WorkstreamState, _ status: StatusLine, _ cause: Stamp) -> Resolution {
        Resolution(state: state, owner: owner, attention: .silent, nextAction: nil, status: status, cause: cause)
    }

    private func strongestClaimOnMe(_ facts: WorkstreamFacts) -> Claim? {
        var claims: [Claim] = []

        if case .failed(let check, let stamp) = facts.ci, !facts.isAddressedByAgent(after: stamp) {
            claims.append(Claim(
                attention: .high,
                cause: stamp,
                action: NextAction(title: "Fix failing CI", reason: "\(check ?? "A check") failed", estimatedMinutes: 15),
                status: StatusLine(headline: "CI failed", detail: check, focus: .github)
            ))
        }

        switch facts.review {
        case .changesRequested(let reviewer, let comments, let stamp) where !facts.isAddressedByAgent(after: stamp):
            claims.append(Claim(
                attention: .high,
                cause: stamp,
                action: NextAction(
                    title: "Address requested changes",
                    reason: "\(reviewer ?? "Reviewer") requested changes",
                    estimatedMinutes: 30
                ),
                status: StatusLine(headline: "Changes requested", detail: commentSummary(comments), focus: .github)
            ))
        case .responded(let reviewer, let comments, let stamp) where !facts.isAddressedByAgent(after: stamp):
            claims.append(Claim(
                attention: .high,
                cause: stamp,
                action: NextAction(
                    title: "Reply to review",
                    reason: "\(reviewer ?? "Reviewer") left new feedback",
                    estimatedMinutes: 10
                ),
                status: StatusLine(headline: "Reviewer responded", detail: commentSummary(comments), focus: .github)
            ))
        case .approved(let reviewer, let stamp):
            switch facts.ci {
            case .unknown, .passed:
                claims.append(Claim(
                    attention: .medium,
                    cause: stamp,
                    action: NextAction(title: "Merge", reason: "Approved by \(reviewer ?? "reviewer")", estimatedMinutes: 2),
                    status: StatusLine(headline: "Approved", detail: "Ready to merge", focus: .github)
                ))
            case .running, .failed:
                break
            }
        default:
            break
        }

        for run in facts.orderedAgentRuns where !run.isEnded {
            switch run.status {
            case .needsInput(let prompt):
                claims.append(Claim(
                    attention: .high,
                    cause: run.updated,
                    action: NextAction(title: "Answer \(run.shortName)", reason: "\(run.name) is waiting for input", estimatedMinutes: 2),
                    status: StatusLine(headline: "\(run.shortName) needs your input", detail: prompt, focus: .agent)
                ))
            case .finished where !run.isAcknowledged:
                claims.append(Claim(
                    attention: .medium,
                    cause: run.updated,
                    action: NextAction(title: "Review \(run.shortName)'s changes", reason: "\(run.name) finished its run", estimatedMinutes: 10),
                    status: StatusLine(headline: "\(run.shortName) finished", focus: .agent)
                ))
            case .failed(let reason) where !run.isAcknowledged:
                claims.append(Claim(
                    attention: .high,
                    cause: run.updated,
                    action: NextAction(title: "Check on \(run.shortName)", reason: reason ?? "\(run.name) stopped before finishing", estimatedMinutes: 5),
                    status: StatusLine(headline: "\(run.shortName) stopped", detail: reason, focus: .agent)
                ))
            case .idle, .working, .finished, .failed:
                break
            }
        }

        // Loudest wins; ties go to the most recent cause, then the larger event ID.
        return claims.max { lhs, rhs in
            if lhs.attention != rhs.attention { return lhs.attention < rhs.attention }
            return Stamp.isOrderedBefore(lhs.cause, rhs.cause)
        }
    }

    private func commentSummary(_ comments: Int?) -> String? {
        guard let comments, comments > 0 else { return nil }
        return comments == 1 ? "1 new comment" : "\(comments) new comments"
    }
}
