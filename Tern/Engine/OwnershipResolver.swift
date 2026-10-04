import Foundation

/// Turns accumulated facts into who owns the next action and how loudly it matters.
///
/// Rules, in order:
/// 1. Completed work is silent and owned by nobody.
/// 2. Anything that is the user's turn wins. Loudest claim wins; ties go to the newest.
///    - Agents: needs input or failed (high), finished turn (medium). Closed sessions claim nothing.
///    - My pull request: failing check (high), changes requested (high; low once changes are
///      pushed but review not re-requested), unanswered comments from others (high),
///      approved with CI green and nothing outstanding (medium), draft (low).
///    - Someone else's pull request: asked for my review since my last review (high).
///    Review and CI feedback count as handled while an agent turn that started after it is
///    in progress or has finished; a failed turn does not handle it. The user's own reviews,
///    comments and resolutions never create claims.
/// 3. Externally blocked work is owned by `external`.
/// 4. Otherwise the ball is with an agent, CI, reviewers, or (for someone else's pull
///    request) its author, in that order, and stays silent.
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
        // Plane closing the item finishes the workstream only when no pull request is still open:
        // a merge or close on GitHub is authoritative, and an open PR still has a next action.
        let planeClosedWithoutOpenPR = facts.pullRequest.opened == nil ? facts.planeClosed : nil
        if let completion = facts.completion ?? planeClosedWithoutOpenPR {
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

        let pr = facts.pullRequest
        let working = facts.orderedAgentRuns.filter { $0.status == .working && $0.isInProgress }
        if let latest = working.last {
            let headline = working.count == 1 ? "\(latest.shortName) working" : "\(working.count) agents working"
            return waiting(on: .agent, state: .active, StatusLine(headline: headline, focus: .agent), latest.started)
        }
        if pr.role == .reviewer, let opened = pr.opened {
            let author = pr.author.map { "With \($0)" } ?? "With the author"
            return waiting(on: .external, state: .waiting, StatusLine(headline: author, focus: .github), opened)
        }
        if case .running(let pending, let total, let stamp) = pr.ci {
            let detail = total > 1 ? "\(pending) of \(total) checks pending" : nil
            return waiting(on: .ci, state: .waiting, StatusLine(headline: "CI running", detail: detail, focus: .github), stamp)
        }
        let pending = pr.pendingReviewers
        if let first = pending.first {
            let headline = pending.count == 1 ? "Waiting for \(first.name)" : "Waiting for \(pending.count) reviewers"
            let since = pending.map(\.since).max(by: Stamp.isOrderedBefore) ?? first.since
            return waiting(on: .reviewer, state: .waiting, StatusLine(headline: headline, focus: .github), since)
        }

        if let opened = pr.opened {
            return Resolution(
                state: .active,
                owner: .me,
                attention: .low,
                nextAction: NextAction(title: "Request a review", reason: "Pull request has no reviewer yet", estimatedMinutes: 2),
                status: StatusLine(headline: "PR open", detail: "No reviewer yet", focus: .github),
                cause: opened
            )
        }
        if let created = facts.planeItem, let plane = facts.planeState {
            // Only Plane knows about this work: show its Plane state, but don't invent an owner.
            return Resolution(
                state: .active,
                owner: .none,
                attention: .silent,
                nextAction: nil,
                status: StatusLine(headline: plane.name, detail: "No pull request or session yet", focus: .plane),
                cause: plane.stamp.at < created.at ? created : plane.stamp
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
        var claims = facts.pullRequest.role == .reviewer
            ? reviewerClaims(facts.pullRequest)
            : authorClaims(facts)

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

    /// Claims on a pull request the user wrote (or a workstream with no pull request yet).
    private func authorClaims(_ facts: WorkstreamFacts) -> [Claim] {
        let pr = facts.pullRequest
        var claims: [Claim] = []

        if case .failed(let names, let stamp) = pr.ci, !facts.isAddressedByAgent(after: stamp) {
            let label = names.count == 1 ? names[0] : "\(names.count) checks"
            claims.append(Claim(
                attention: .high,
                cause: stamp,
                action: NextAction(title: "Fix failing CI", reason: "\(label) failed", estimatedMinutes: 15),
                status: StatusLine(headline: "CI failed", detail: names.joined(separator: ", "), focus: .github)
            ))
        }

        var hasOutstandingChanges = false
        for (name, reviewer) in pr.reviewers.sorted(by: { $0.key < $1.key }) {
            guard case .changesRequested(let comments) = reviewer.verdict, let stamp = reviewer.verdictStamp else { continue }
            hasOutstandingChanges = true
            if let requested = reviewer.requested, Stamp.isOrderedBefore(stamp, requested) { continue }
            if facts.isAddressedByAgent(after: stamp) { continue }
            if let push = pr.lastPush, Stamp.isOrderedBefore(stamp, push) {
                claims.append(Claim(
                    attention: .low,
                    cause: push,
                    action: NextAction(title: "Re-request review from \(name)", reason: "Changes pushed since \(name)'s review", estimatedMinutes: 1),
                    status: StatusLine(headline: "Changes pushed", detail: "Re-request \(name)'s review", focus: .github)
                ))
            } else {
                claims.append(Claim(
                    attention: .high,
                    cause: stamp,
                    action: NextAction(title: "Address requested changes", reason: "\(name) requested changes", estimatedMinutes: 30),
                    status: StatusLine(headline: "Changes requested", detail: commentSummary(comments), focus: .github)
                ))
            }
        }

        let unanswered = pr.unansweredComments(isAddressed: facts.isAddressedByAgent(after:))
        if let latest = unanswered.map(\.stamp).max(by: Stamp.isOrderedBefore) {
            claims.append(Claim(
                attention: .high,
                cause: latest,
                action: NextAction(title: "Reply to review", reason: "New feedback on your pull request", estimatedMinutes: 10),
                status: StatusLine(headline: "Reviewer responded", detail: commentSummary(unanswered.reduce(0) { $0 + $1.count }), focus: .github)
            ))
        }

        let approvals = pr.reviewers.filter { $0.value.verdict == .approved }
        if let approved = approvals.compactMap(\.value.verdictStamp).max(by: Stamp.isOrderedBefore),
           !hasOutstandingChanges, pr.pendingReviewers.isEmpty, !pr.isDraft {
            switch pr.ci {
            case .unknown, .passed:
                let names = approvals.keys.sorted().joined(separator: ", ")
                claims.append(Claim(
                    attention: .medium,
                    cause: approved,
                    action: NextAction(title: "Merge", reason: "Approved by \(names)", estimatedMinutes: 2),
                    status: StatusLine(headline: "Approved", detail: "Ready to merge", focus: .github)
                ))
            case .running, .failed:
                break
            }
        }

        if pr.isDraft, let opened = pr.opened {
            claims.append(Claim(
                attention: .low,
                cause: opened,
                action: NextAction(title: "Mark ready for review", reason: "Pull request is a draft", estimatedMinutes: 1),
                status: StatusLine(headline: "Draft", focus: .github)
            ))
        }
        return claims
    }

    /// Claims on someone else's pull request: only an outstanding request for my review.
    private func reviewerClaims(_ pr: PullRequestFacts) -> [Claim] {
        guard let requested = pr.owesMyReview else { return [] }
        return [Claim(
            attention: .high,
            cause: requested,
            action: NextAction(title: "Review", reason: "\(pr.author ?? "The author") asked for your review", estimatedMinutes: 20),
            status: StatusLine(headline: "Review requested", detail: pr.author.map { "From \($0)" }, focus: .github)
        )]
    }

    private func commentSummary(_ comments: Int?) -> String? {
        guard let comments, comments > 0 else { return nil }
        return comments == 1 ? "1 new comment" : "\(comments) new comments"
    }
}
