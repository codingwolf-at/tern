import Foundation

/// Converts pull request detail from GitHub into domain `ObservedEvent`s.
///
/// GitHub reports current state; Tern needs a history of transitions. Each transition is
/// emitted with an identity taken from GitHub's own IDs, so re-syncing the same data yields
/// the same events and ingestion drops them as duplicates:
///
/// | Source                       | Event ID                                        |
/// |------------------------------|-------------------------------------------------|
/// | Pull request                 | `github:pr:<repo-id>:<number>:opened`           |
/// | Timeline (requests, draft, merge, close, reopen, dismissal, labels) | `github:timeline:<node-id>` |
/// | Pending request not in timeline | `github:pr:<repo-id>:<number>:pending-request:<reviewer>` |
/// | Label applied before the timeline window | `github:pr:<repo-id>:<number>:label:<name>` |
/// | Review                       | `github:review:<review-id>`                     |
/// | Review thread comment        | `github:comment:<comment-id>`                   |
/// | Thread resolution            | `github:thread:<thread-id>:resolved:<last-comment-id>` |
/// | Conversation comment         | `github:issue-comment:<comment-id>`             |
/// | Head commit                  | `github:commit:<repo-id>:<number>:<sha>`        |
/// | Check run                    | `github:check:<check-run-id>:<status-or-conclusion>` |
/// | Commit status                | `github:status:<node-id>:<state>:<created-at>`  |
///
/// Plane work item identifiers in the head branch (`fix/WEB-9295-…`), the title (`[WEB-9295] …`)
/// or Plane links in the body are passed along as candidates, strongest first, so the pull
/// request can join the work item's workstream. The body itself is not kept.
///
/// Every event records whether the authenticated user caused it, so the user's own reviews,
/// comments and resolutions are never mistaken for someone else's response. Bot comments and
/// reviews are ignored.
struct GitHubNormalizer: Sendable {
    let viewerLogin: String

    func isMe(_ login: String?) -> Bool {
        guard let login else { return false }
        return login.caseInsensitiveCompare(viewerLogin) == .orderedSame
    }

    /// - Parameter requestedViaSearch: the PR appeared in the "review requested from me" search,
    ///   which also covers requests to teams the user belongs to.
    func events(for pr: GitHubPullRequest, requestedViaSearch: Bool) -> [ObservedEvent] {
        let context = Context(pr: pr, normalizer: self, requestedViaSearch: requestedViaSearch)
        var events: [ObservedEvent] = []

        // Opened, with the role and the draft state it started in.
        let draftChanges = pr.timelineItems.items.filter { $0.typename == "ReadyForReviewEvent" || $0.typename == "ConvertToDraftEvent" }
        let startedAsDraft = draftChanges.first.map { $0.typename == "ReadyForReviewEvent" } ?? pr.isDraft
        events.append(context.event(
            EventID(.github, "pr", context.repoID, String(pr.number), "opened"),
            .pullRequestOpened,
            at: pr.createdAt,
            actor: pr.author?.login,
            [
                .role: context.role,
                .isDraft: String(startedAsDraft),
                .pullRequestNodeID: pr.id,
            ]
        ))

        // Timeline transitions.
        var timelineRequests: Set<String> = []
        var timelineLabels: Set<String> = []
        for item in pr.timelineItems.items {
            guard let id = item.id, let at = item.createdAt else { continue }
            let eventID = EventID(.github, "timeline", id)
            switch item.typename {
            case "ReviewRequestedEvent", "ReviewRequestRemovedEvent":
                guard let reviewer = item.requestedReviewer, !reviewer.isBot, let key = reviewer.key else { continue }
                if item.typename == "ReviewRequestedEvent" { timelineRequests.insert(key) }
                events.append(context.event(
                    eventID,
                    item.typename == "ReviewRequestedEvent" ? .reviewRequested : .reviewRequestRemoved,
                    at: at,
                    actor: item.actor?.login,
                    [.reviewer: key, .reviewerIsMe: String(context.reviewerIsMe(reviewer))]
                ))
            case "ReadyForReviewEvent":
                events.append(context.event(eventID, .pullRequestReadyForReview, at: at, actor: item.actor?.login))
            case "ConvertToDraftEvent":
                events.append(context.event(eventID, .pullRequestConvertedToDraft, at: at, actor: item.actor?.login))
            case "MergedEvent":
                events.append(context.event(eventID, .pullRequestMerged, at: at, actor: item.actor?.login))
            case "ClosedEvent" where !pr.merged:
                events.append(context.event(eventID, .pullRequestClosed, at: at, actor: item.actor?.login))
            case "ReopenedEvent":
                events.append(context.event(eventID, .pullRequestReopened, at: at, actor: item.actor?.login))
            case "ReviewDismissedEvent":
                let reviewer = pr.reviews.items.first { $0.databaseId == item.review?.databaseId }?.author?.login
                events.append(context.event(eventID, .reviewDismissed, at: at, actor: item.actor?.login, [.reviewer: reviewer ?? "reviewer"]))
            case "LabeledEvent", "UnlabeledEvent":
                guard let label = item.label?.name else { continue }
                timelineLabels.insert(label.lowercased())
                let kind: WorkEventKind = item.typename == "LabeledEvent" ? .pullRequestLabeled : .pullRequestUnlabeled
                events.append(context.event(eventID, kind, at: at, actor: item.actor?.login, [.label: label]))
            default:
                continue
            }
        }

        // Outstanding requests whose request event is older than the timeline window.
        for request in pr.reviewRequests.items {
            guard let reviewer = request.requestedReviewer, !reviewer.isBot, let key = reviewer.key, !timelineRequests.contains(key) else { continue }
            events.append(context.event(
                EventID(.github, "pr", context.repoID, String(pr.number), "pending-request", key),
                .reviewRequested,
                at: pr.createdAt,
                actor: pr.author?.login,
                [.reviewer: key, .reviewerIsMe: String(context.reviewerIsMe(reviewer))]
            ))
        }

        // Labels applied before the timeline window.
        for label in pr.labels?.items ?? [] where !timelineLabels.contains(label.name.lowercased()) {
            events.append(context.event(
                EventID(.github, "pr", context.repoID, String(pr.number), "label", label.name.lowercased()),
                .pullRequestLabeled,
                at: pr.createdAt,
                actor: pr.author?.login,
                [.label: label.name]
            ))
        }

        // Reviews. Pending (unsubmitted) reviews are private drafts; dismissals arrive via the timeline.
        for review in pr.reviews.items {
            guard let author = review.author, !author.isBot, let submitted = review.submittedAt else { continue }
            let kind: WorkEventKind
            switch review.state {
            case "APPROVED": kind = .reviewApproved
            case "CHANGES_REQUESTED": kind = .changesRequested
            case "COMMENTED": kind = .reviewCommented
            default: continue
            }
            events.append(context.event(
                EventID(.github, "review", String(review.databaseId)),
                kind,
                at: submitted,
                actor: author.login,
                review.commit.map { [.reviewer: author.login, .headSHA: $0.oid] } ?? [.reviewer: author.login]
            ))
        }

        // Review threads: the latest comment, and whether the thread is resolved.
        for thread in pr.reviewThreads.items {
            guard let comment = thread.comments.items.last else { continue }
            if let author = comment.author, !author.isBot {
                events.append(context.event(
                    EventID(.github, "comment", String(comment.databaseId)),
                    .reviewCommentAdded,
                    at: comment.createdAt,
                    actor: author.login,
                    [.threadID: thread.id]
                ))
            }
            if thread.isResolved {
                // GitHub doesn't expose when a thread was resolved; it was after its last comment.
                events.append(context.event(
                    EventID(.github, "thread", thread.id, "resolved", String(comment.databaseId)),
                    .reviewThreadResolved,
                    at: comment.createdAt.addingTimeInterval(1),
                    actor: thread.resolvedBy?.login,
                    [.threadID: thread.id]
                ))
            }
        }

        // Conversation comments.
        for comment in pr.comments.items {
            guard let author = comment.author, !author.isBot else { continue }
            events.append(context.event(
                EventID(.github, "issue-comment", String(comment.databaseId)),
                .reviewCommentAdded,
                at: comment.createdAt,
                actor: author.login
            ))
        }

        // Head commit: a new SHA starts a new round of CI.
        if let head = pr.commits.items.last?.commit {
            let pusher = head.author?.user?.login
            let byMe = pusher.map(isMe) ?? (context.role == "author")
            events.append(context.event(
                EventID(.github, "commit", context.repoID, String(pr.number), head.oid),
                .commitsPushed,
                at: head.committedDate,
                actor: pusher,
                [.headSHA: head.oid, .actorIsMe: String(byMe)]
            ))
        }

        // Checks on the head commit.
        for check in pr.statusCheckRollup?.contexts.items ?? [] {
            if let event = context.checkEvent(check) { events.append(event) }
        }

        return events
    }

    private struct Context {
        let pr: GitHubPullRequest
        let normalizer: GitHubNormalizer
        let requestedViaSearch: Bool

        var repoID: String { String(pr.repository.databaseId) }
        var role: String { normalizer.isMe(pr.author?.login) ? "author" : "reviewer" }

        var references: [ExternalReference] {
            let headRepository = pr.headRepository?.nameWithOwner ?? pr.repository.nameWithOwner
            return [
                .pullRequest(repository: pr.repository.nameWithOwner, number: pr.number),
                .branch(pr.headRefName, repository: ExternalReference.gitHubRepository(headRepository)),
            ]
        }

        /// Requests to a team count as requests to the user when GitHub's own search says the
        /// user's review is requested and no request names the user directly.
        func reviewerIsMe(_ reviewer: GitHubRequestedReviewer) -> Bool {
            if reviewer.isTeam {
                let namedDirectly = pr.reviewRequests.items.contains { normalizer.isMe($0.requestedReviewer?.login) }
                return requestedViaSearch && role == "reviewer" && !namedDirectly
            }
            return normalizer.isMe(reviewer.login)
        }

        /// Plane identifiers this pull request names: branch, then title, then body links.
        var planeCandidates: [ExternalReference] {
            var seen: Set<String> = []
            let identifiers = PlaneIdentifiers.find(in: pr.headRefName)
                + PlaneIdentifiers.find(in: pr.title)
                + PlaneIdentifiers.findInLinks(pr.body ?? "")
            return identifiers.filter { seen.insert($0).inserted }.map(ExternalReference.planeItem)
        }

        func event(
            _ id: EventID,
            _ kind: WorkEventKind,
            at timestamp: Date,
            actor: String?,
            _ extra: [MetadataKey: String] = [:]
        ) -> ObservedEvent {
            var metadata: [MetadataKey: String] = [.actorIsMe: String(normalizer.isMe(actor))]
            if let actor { metadata[.actor] = actor }
            metadata.merge(extra) { _, new in new }
            let reference = references[0]
            return ObservedEvent(
                id: id,
                source: .github,
                kind: kind,
                timestamp: timestamp,
                metadata: metadata,
                references: references,
                suggestedTitle: pr.title,
                workstreamKey: reference,
                pullRequest: PullRequestReference(repository: pr.repository.nameWithOwner, number: pr.number, title: pr.title, url: pr.url),
                candidates: planeCandidates
            )
        }

        func checkEvent(_ check: GitHubPullRequest.CheckContext) -> ObservedEvent? {
            switch check.typename {
            case "CheckRun":
                guard let runID = check.databaseId, let name = check.name, let status = check.status else { return nil }
                let kind: WorkEventKind
                let key: String
                let at: Date?
                if status != "COMPLETED" {
                    (kind, key, at) = (.ciStarted, "started", check.startedAt)
                } else {
                    switch check.conclusion {
                    case "SUCCESS", "NEUTRAL", "SKIPPED": kind = .ciPassed
                    case "FAILURE", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE": kind = .ciFailed
                    default: return nil // CANCELLED, STALE: superseded runs, not a result
                    }
                    key = (check.conclusion ?? "completed").lowercased()
                    at = check.completedAt ?? check.startedAt
                }
                return event(
                    EventID(.github, "check", String(runID), key),
                    kind,
                    at: at ?? pr.updatedAt,
                    actor: nil,
                    [.checkName: name, .headSHA: pr.headRefOid]
                )
            case "StatusContext":
                guard let id = check.id, let name = check.context, let state = check.state, let created = check.createdAt else { return nil }
                let kind: WorkEventKind
                switch state {
                case "PENDING", "EXPECTED": kind = .ciStarted
                case "SUCCESS": kind = .ciPassed
                case "FAILURE", "ERROR": kind = .ciFailed
                default: return nil
                }
                return event(
                    EventID(.github, "status", id, state.lowercased(), String(Int(created.timeIntervalSince1970))),
                    kind,
                    at: created,
                    actor: nil,
                    [.checkName: name, .headSHA: pr.headRefOid]
                )
            default:
                return nil
            }
        }
    }
}
