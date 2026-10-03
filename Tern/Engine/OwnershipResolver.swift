import Foundation

/// Turns accumulated facts into who owns the next action and how loudly it matters.
///
/// Rules, in order:
/// 1. Completed work is silent and owned by nobody.
/// 2. Anything that is the user's turn wins (CI failure, review feedback, finished agent run,
///    approval ready to merge). Review/CI feedback is considered handled while an agent run
///    that started *after* it is working or has finished. Loudest claim wins; ties go to the newest.
/// 3. Externally blocked work is owned by `external`.
/// 4. Otherwise the ball is with an agent, CI, or a reviewer, in that order, and stays silent.
/// 5. With nothing pending, an open PR or Plane item is a low-priority nudge for the user.
struct OwnershipResolver: Sendable {
    struct Resolution: Hashable, Sendable {
        let state: WorkstreamState
        let owner: Owner
        let attention: AttentionLevel
        let nextAction: NextAction?
        let status: StatusLine
    }

    private struct Claim {
        let attention: AttentionLevel
        let at: Date
        let action: NextAction
        let status: StatusLine
    }

    func resolve(_ facts: WorkstreamFacts) -> Resolution {
        if facts.isComplete {
            return Resolution(
                state: .complete,
                owner: .none,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: "Done", detail: facts.completionReason)
            )
        }

        if let claim = strongestClaimOnMe(facts) {
            return Resolution(
                state: .needsAttention,
                owner: .me,
                attention: claim.attention,
                nextAction: claim.action,
                status: claim.status
            )
        }

        if let blocked = facts.blocked {
            return Resolution(
                state: .blocked,
                owner: .external,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: "Blocked", detail: blocked.reason, focus: .plane)
            )
        }

        if case .working(let name, _) = facts.agent {
            return waiting(on: .agent, state: .active, StatusLine(headline: "\(shortName(name)) working", focus: .agent))
        }
        if case .running = facts.ci {
            return waiting(on: .ci, state: .waiting, StatusLine(headline: "CI running", focus: .github))
        }
        if case .awaiting(let reviewer, _) = facts.review {
            let headline = reviewer.map { "Waiting for \($0)" } ?? "Waiting for review"
            return waiting(on: .reviewer, state: .waiting, StatusLine(headline: headline, focus: .github))
        }

        if facts.hasPullRequest {
            return Resolution(
                state: .active,
                owner: .me,
                attention: .low,
                nextAction: NextAction(title: "Request a review", reason: "Pull request has no reviewer yet", estimatedMinutes: 2),
                status: StatusLine(headline: "PR open", detail: "No reviewer yet", focus: .github)
            )
        }
        if facts.hasPlaneItem {
            return Resolution(
                state: .active,
                owner: .me,
                attention: .low,
                nextAction: NextAction(title: "Start work", reason: "Work item is ready to pick up"),
                status: StatusLine(headline: "Ready to start", focus: .plane)
            )
        }

        return Resolution(
            state: .active,
            owner: .none,
            attention: .silent,
            nextAction: nil,
            status: WorkstreamEvaluation.initial.status
        )
    }

    private func waiting(on owner: Owner, state: WorkstreamState, _ status: StatusLine) -> Resolution {
        Resolution(state: state, owner: owner, attention: .silent, nextAction: nil, status: status)
    }

    private func strongestClaimOnMe(_ facts: WorkstreamFacts) -> Claim? {
        var claims: [Claim] = []
        let agentStart = facts.agent.startedAt

        /// Feedback is handled when an agent run began after it arrived.
        func isHandledByAgent(_ at: Date) -> Bool {
            guard let agentStart else { return false }
            return agentStart > at
        }

        if case .failed(let check, let at) = facts.ci, !isHandledByAgent(at) {
            claims.append(Claim(
                attention: .high,
                at: at,
                action: NextAction(title: "Fix failing CI", reason: "\(check ?? "A check") failed", estimatedMinutes: 15),
                status: StatusLine(headline: "CI failed", detail: check, focus: .github)
            ))
        }

        switch facts.review {
        case .changesRequested(let reviewer, let comments, let at) where !isHandledByAgent(at):
            claims.append(Claim(
                attention: .high,
                at: at,
                action: NextAction(
                    title: "Address requested changes",
                    reason: "\(reviewer ?? "Reviewer") requested changes",
                    estimatedMinutes: 30
                ),
                status: StatusLine(headline: "Changes requested", detail: commentSummary(comments), focus: .github)
            ))
        case .responded(let reviewer, let comments, let at) where !isHandledByAgent(at):
            claims.append(Claim(
                attention: .high,
                at: at,
                action: NextAction(
                    title: "Reply to review",
                    reason: "\(reviewer ?? "Reviewer") left new feedback",
                    estimatedMinutes: 10
                ),
                status: StatusLine(headline: "Reviewer responded", detail: commentSummary(comments), focus: .github)
            ))
        case .approved(let reviewer, let at):
            switch facts.ci {
            case .unknown, .passed:
                claims.append(Claim(
                    attention: .medium,
                    at: at,
                    action: NextAction(title: "Merge", reason: "Approved by \(reviewer ?? "reviewer")", estimatedMinutes: 2),
                    status: StatusLine(headline: "Approved", detail: "Ready to merge", focus: .github)
                ))
            case .running, .failed:
                break
            }
        default:
            break
        }

        switch facts.agent {
        case .finished(let name, _, let at):
            claims.append(Claim(
                attention: .medium,
                at: at,
                action: NextAction(title: "Review \(shortName(name))'s changes", reason: "\(name) finished its run", estimatedMinutes: 10),
                status: StatusLine(headline: "\(shortName(name)) finished", focus: .agent)
            ))
        case .failed(let name, _, let at, let reason):
            claims.append(Claim(
                attention: .medium,
                at: at,
                action: NextAction(title: "Check on \(shortName(name))", reason: reason ?? "\(name) stopped before finishing", estimatedMinutes: 5),
                status: StatusLine(headline: "\(shortName(name)) stopped", detail: reason, focus: .agent)
            ))
        case .idle, .working:
            break
        }

        // Loudest wins; ties go to the most recent signal. Claims are collected in a fixed
        // order, so even identical timestamps resolve the same way every time.
        return claims.max { lhs, rhs in
            if lhs.attention != rhs.attention { return lhs.attention < rhs.attention }
            return lhs.at < rhs.at
        }
    }

    private func commentSummary(_ comments: Int?) -> String? {
        guard let comments, comments > 0 else { return nil }
        return comments == 1 ? "1 new comment" : "\(comments) new comments"
    }

    private func shortName(_ name: String) -> String {
        name.split(separator: " ").first.map(String.init) ?? name
    }
}
