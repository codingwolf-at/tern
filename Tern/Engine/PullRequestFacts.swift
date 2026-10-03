import Foundation

/// Pull request facts, folded from GitHub-style events. Reviews and CI are tracked per
/// reviewer and per check, so one signal never hides another, and every fact keeps the
/// event that established it.
struct PullRequestFacts: Hashable, Sendable {
    typealias Stamp = WorkstreamFacts.Stamp

    enum Role: Hashable, Sendable {
        /// The user wrote the pull request.
        case author
        /// Someone else's pull request the user reviews.
        case reviewer
    }

    enum Verdict: Hashable, Sendable {
        case approved
        case changesRequested(comments: Int?)
    }

    struct Reviewer: Hashable, Sendable {
        /// Outstanding review request, if any.
        var requested: Stamp?
        /// Latest approval or change request. A plain comment review doesn't replace it.
        var verdict: Verdict?
        var verdictStamp: Stamp?
    }

    /// Feedback from someone else that may need a reply.
    struct IncomingComment: Hashable, Sendable {
        let stamp: Stamp
        let count: Int
        let threadID: String?
    }

    struct Check: Hashable, Sendable {
        enum Status: Hashable, Sendable {
            case pending
            case passed
            case failed
        }

        let name: String
        let headSHA: String?
        let status: Status
        let stamp: Stamp
    }

    enum CIState: Hashable, Sendable {
        case unknown
        case running(pending: Int, total: Int, Stamp)
        case passed(Stamp)
        case failed(checks: [String], Stamp)
    }

    var opened: Stamp?
    var role: Role = .author
    var author: String?
    var isDraft = false
    var reviewers: [String: Reviewer] = [:]
    var incoming: [IncomingComment] = []
    var resolvedThreads: Set<String> = []
    /// The user's latest reply, review, resolution or push.
    var myLastActivity: Stamp?
    var lastPush: Stamp?
    /// Someone asked the user to review (reviewer role).
    var requestedFromMe: Stamp?
    var myLastReview: Stamp?
    var headSHA: String?
    /// Checks keyed by name; a re-run replaces the earlier result.
    var checks: [String: Check] = [:]

    /// Applies a GitHub-style event. Returns `false` for kinds it doesn't handle.
    mutating func apply(_ event: WorkEvent, stamp: Stamp) -> Bool {
        let reviewer = event[.reviewer] ?? event[.actor] ?? "reviewer"
        switch event.kind {
        case .pullRequestOpened:
            if opened == nil {
                opened = stamp
                role = event[.role] == "reviewer" ? .reviewer : .author
                author = event[.actor]
                isDraft = event[.isDraft] == "true"
            }
        case .pullRequestReadyForReview:
            isDraft = false
        case .pullRequestConvertedToDraft:
            isDraft = true

        case .reviewRequested:
            if event[.reviewerIsMe] == "true" {
                requestedFromMe = stamp
            } else {
                reviewers[reviewer, default: Reviewer()].requested = stamp
            }
        case .reviewRequestRemoved:
            if event[.reviewerIsMe] == "true" {
                requestedFromMe = nil
            } else {
                reviewers[reviewer]?.requested = nil
            }

        case .changesRequested, .reviewApproved, .reviewCommented:
            if event.isByMe {
                myLastReview = stamp
                myLastActivity = stamp
            } else {
                var state = reviewers[reviewer, default: Reviewer()]
                // Submitting a review answers the request.
                if let requested = state.requested, Stamp.isOrderedBefore(requested, stamp) { state.requested = nil }
                switch event.kind {
                case .changesRequested:
                    state.verdict = .changesRequested(comments: event[.commentCount].flatMap { Int($0) })
                    state.verdictStamp = stamp
                case .reviewApproved:
                    state.verdict = .approved
                    state.verdictStamp = stamp
                default:
                    incoming.append(IncomingComment(stamp: stamp, count: event[.commentCount].flatMap { Int($0) } ?? 1, threadID: nil))
                }
                reviewers[reviewer] = state
            }
        case .reviewDismissed:
            reviewers[reviewer]?.verdict = nil
            reviewers[reviewer]?.verdictStamp = nil
        case .reviewerResponded, .reviewCommentAdded:
            if event.isByMe {
                myLastActivity = stamp
            } else {
                let count = event[.commentCount].flatMap { Int($0) } ?? 1
                incoming.append(IncomingComment(stamp: stamp, count: count, threadID: event[.threadID]))
            }
        case .reviewThreadResolved:
            // Closes that thread only. Resolving one thread says nothing about the others.
            if let thread = event[.threadID] { resolvedThreads.insert(thread) }

        case .commitsPushed:
            headSHA = event[.headSHA] ?? headSHA
            // Pushes count as the user's unless the event says otherwise.
            if event[.actorIsMe] != "false" {
                lastPush = stamp
                myLastActivity = stamp
            }
        case .ciStarted, .ciPassed, .ciFailed:
            let name = event[.checkName] ?? "ci"
            let status: Check.Status = switch event.kind {
            case .ciStarted: .pending
            case .ciPassed: .passed
            default: .failed
            }
            if let existing = checks[name], Stamp.isOrderedBefore(stamp, existing.stamp) { break }
            checks[name] = Check(name: name, headSHA: event[.headSHA], status: status, stamp: stamp)
        default:
            return false
        }
        return true
    }

    /// Checks for the current head commit. Checks from older commits no longer count.
    var currentChecks: [Check] {
        checks.values
            .filter { check in
                guard let headSHA, let checkSHA = check.headSHA else { return true }
                return checkSHA == headSHA
            }
            .sorted { $0.name < $1.name }
    }

    /// Any failure wins; otherwise pending checks keep CI running; otherwise all passed.
    var ci: CIState {
        let checks = currentChecks
        guard !checks.isEmpty else { return .unknown }
        let latest = { (subset: [Check]) in subset.map(\.stamp).max(by: Stamp.isOrderedBefore)! }
        let failed = checks.filter { $0.status == .failed }
        if !failed.isEmpty { return .failed(checks: failed.map(\.name), latest(failed)) }
        let pending = checks.filter { $0.status == .pending }
        if !pending.isEmpty { return .running(pending: pending.count, total: checks.count, latest(pending)) }
        return .passed(latest(checks))
    }

    /// Reviewers with an outstanding request, in a stable order.
    var pendingReviewers: [(name: String, since: Stamp)] {
        reviewers.compactMap { name, state in state.requested.map { (name, $0) } }
            .sorted { $0.name < $1.name }
    }

    /// Feedback from others since the user last acted, excluding resolved threads.
    func unansweredComments(isAddressed: (Stamp) -> Bool) -> [IncomingComment] {
        incoming.filter { comment in
            if let mine = myLastActivity, !Stamp.isOrderedBefore(mine, comment.stamp) { return false }
            if let thread = comment.threadID, resolvedThreads.contains(thread) { return false }
            return !isAddressed(comment.stamp)
        }
    }

    /// The user still owes a review: asked after their last review.
    var owesMyReview: Stamp? {
        guard let requested = requestedFromMe else { return nil }
        if let reviewed = myLastReview, Stamp.isOrderedBefore(requested, reviewed) { return nil }
        return requested
    }
}
