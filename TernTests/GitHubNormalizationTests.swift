import Foundation
import Testing
@testable import Tern

private func kinds(_ events: [ObservedEvent]) -> [WorkEventKind] { events.map(\.kind) }
private func first(_ kind: WorkEventKind, in events: [ObservedEvent]) -> ObservedEvent? { events.first { $0.kind == kind } }

@Suite("GitHub normalization")
struct GitHubNormalizationTests {
    @Test("My open PR becomes an authored pull request with its references")
    func authoredPR() throws {
        let events = GH.events(GH.pr())
        let opened = try #require(first(.pullRequestOpened, in: events))
        #expect(opened.id == EventID(rawValue: "github:pr:100:421:opened"))
        #expect(opened.metadata["role"] == "author")
        #expect(opened.metadata["isDraft"] == "false")
        #expect(opened.metadata["actorIsMe"] == "true")
        #expect(opened.metadata["pullRequestNodeID"] == "PR_1")
        #expect(opened.references == [
            .pullRequest(repository: "acme/web", number: 421),
            .branch("feat/avatar-migration", repository: "github.com/acme/web"),
        ])
        #expect(opened.pullRequest?.url?.absoluteString == "https://github.com/acme/web/pull/421")
        #expect(opened.suggestedTitle == "Avatar migration")
        #expect(kinds(events).contains(.commitsPushed))
    }

    @Test("A PR requesting my review is a reviewer-role PR with a request for me")
    func reviewRequestedPR() throws {
        let pr = GH.pr(author: "sarah", requests: [GH.reviewer(GH.me)],
                       timeline: [GH.timeline("ReviewRequestedEvent", id: "RR_1", at: GH.at(5), actor: "sarah", reviewer: GH.reviewer(GH.me))])
        let events = GH.events(pr, requested: true)
        #expect(first(.pullRequestOpened, in: events)?.metadata["role"] == "reviewer")
        let request = try #require(first(.reviewRequested, in: events))
        #expect(request.id == EventID(rawValue: "github:timeline:RR_1"))
        #expect(request.metadata["reviewerIsMe"] == "true")
        // Covered by the timeline event, so no synthetic pending request.
        #expect(events.filter { $0.kind == .reviewRequested }.count == 1)
    }

    @Test("A team request counts as mine only when GitHub's search says so")
    func teamRequest() {
        let pr = GH.pr(author: "sarah", requests: [GH.team("web-core")])
        #expect(first(.reviewRequested, in: GH.events(pr, requested: true))?.metadata["reviewerIsMe"] == "true")
        #expect(first(.reviewRequested, in: GH.events(pr, requested: false))?.metadata["reviewerIsMe"] == "false")
    }

    @Test("Draft and ready states, including the state a PR started in")
    func draftAndReady() {
        #expect(first(.pullRequestOpened, in: GH.events(GH.pr(isDraft: true)))?.metadata["isDraft"] == "true")

        let readied = GH.pr(isDraft: false, timeline: [GH.timeline("ReadyForReviewEvent", id: "RFR_1", at: GH.at(10))])
        let events = GH.events(readied)
        #expect(first(.pullRequestOpened, in: events)?.metadata["isDraft"] == "true")
        #expect(first(.pullRequestReadyForReview, in: events)?.id == EventID(rawValue: "github:timeline:RFR_1"))
    }

    @Test("Merged PRs report the merge, not the close that accompanies it")
    func merged() {
        let pr = GH.pr(state: "MERGED", merged: true, timeline: [
            GH.timeline("MergedEvent", id: "M_1", at: GH.at(30)),
            GH.timeline("ClosedEvent", id: "C_1", at: GH.at(30)),
        ])
        let events = GH.events(pr)
        #expect(kinds(events).contains(.pullRequestMerged))
        #expect(!kinds(events).contains(.pullRequestClosed))
    }

    @Test("Closed without merge")
    func closed() {
        let events = GH.events(GH.pr(state: "CLOSED", timeline: [GH.timeline("ClosedEvent", id: "C_1", at: GH.at(30))]))
        #expect(kinds(events).contains(.pullRequestClosed))
        #expect(!kinds(events).contains(.pullRequestMerged))
    }

    @Test("Review states map to their own events")
    func reviews() throws {
        let pr = GH.pr(
            reviews: [
                GH.review(1, "APPROVED", by: "sarah", at: GH.at(1)),
                GH.review(2, "CHANGES_REQUESTED", by: "priya", at: GH.at(2)),
                GH.review(3, "COMMENTED", by: "omar", at: GH.at(3)),
                GH.review(4, "DISMISSED", by: "lee", at: GH.at(4)),
                GH.review(5, "PENDING", by: GH.me, at: GH.at(5)),
            ],
            timeline: [GH.timeline("ReviewDismissedEvent", id: "D_1", at: GH.at(6), dismissedReview: 4)]
        )
        let events = GH.events(pr)
        #expect(first(.reviewApproved, in: events)?.id == EventID(rawValue: "github:review:1"))
        #expect(first(.changesRequested, in: events)?.metadata["reviewer"] == "priya")
        #expect(first(.reviewCommented, in: events)?.metadata["actorIsMe"] == "false")
        let dismissal = try #require(first(.reviewDismissed, in: events))
        #expect(dismissal.metadata["reviewer"] == "lee")
        // Pending drafts and already-dismissed reviews produce no review event of their own.
        #expect(!events.contains { $0.id == EventID(rawValue: "github:review:4") || $0.id == EventID(rawValue: "github:review:5") })
    }

    @Test("My own review is marked as mine")
    func ownReview() {
        let pr = GH.pr(author: "sarah", reviews: [GH.review(9, "COMMENTED", by: GH.me, at: GH.at(1))])
        #expect(first(.reviewCommented, in: GH.events(pr))?.isMine == true)
    }

    @Test("Comments carry their author, thread and resolution")
    func comments() throws {
        let pr = GH.pr(
            threads: [
                GH.thread("T_1", last: GH.comment(11, by: "priya", at: GH.at(1))),
                GH.thread("T_2", last: GH.comment(12, by: GH.me, at: GH.at(2)), resolvedBy: GH.me),
            ],
            comments: [GH.comment(21, by: "sarah", at: GH.at(3)), GH.comment(22, by: "codecov[bot]", at: GH.at(4))]
        )
        let events = GH.events(pr)
        let reviewer = try #require(events.first { $0.id == EventID(rawValue: "github:comment:11") })
        #expect(reviewer.isMine == false)
        #expect(reviewer.metadata["threadID"] == "T_1")
        #expect(events.first { $0.id == EventID(rawValue: "github:comment:12") }?.isMine == true)
        #expect(events.contains { $0.id == EventID(rawValue: "github:thread:T_2:resolved:12") })
        #expect(events.contains { $0.id == EventID(rawValue: "github:issue-comment:21") })
        #expect(!events.contains { $0.id == EventID(rawValue: "github:issue-comment:22") }, "bot comments are ignored")
    }

    @Test("Checks: each run and state is its own event on the head commit")
    func checks() {
        let pr = GH.pr(headSHA: "abc", checks: [
            GH.check(1, "build", at: GH.at(1)),
            GH.check(2, "lint", conclusion: "FAILURE", at: GH.at(2)),
            GH.check(3, "test", status: "IN_PROGRESS", at: GH.at(3)),
            GH.check(4, "old", conclusion: "CANCELLED", at: GH.at(3)),
            GH.status("SC_1", "deploy/preview", state: "PENDING", at: GH.at(4)),
        ])
        let checks = GH.events(pr).filter { [.ciStarted, .ciPassed, .ciFailed].contains($0.kind) }
        #expect(Set(checks.map(\.id.rawValue)) == [
            "github:check:1:success", "github:check:2:failure", "github:check:3:started",
            "github:status:SC_1:pending:\(Int(GH.at(4).timeIntervalSince1970))",
        ])
        #expect(checks.allSatisfy { $0.metadata["headSHA"] == "abc" })
    }

    @Test("Normalizing the same response twice gives identical events")
    func stableIdentity() {
        let pr = GH.pr(reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(1))],
                       threads: [GH.thread("T_1", last: GH.comment(11, by: "priya", at: GH.at(2)))],
                       checks: [GH.check(1, "build", at: GH.at(3))])
        #expect(GH.events(pr) == GH.events(pr))
    }

    @Test("The query response shape decodes, including non-PR search nodes")
    func decodesIndexResponse() throws {
        let json = #"""
        {"data":{"viewer":{"login":"atul","databaseId":7},"rateLimit":{"cost":1,"remaining":4999,"resetAt":"2026-10-04T05:00:00Z"},
         "authored":{"nodes":[{"id":"PR_1","updatedAt":"2026-10-04T04:00:00Z","headRefOid":"abc","isDraft":false,"state":"OPEN",
           "repository":{"nameWithOwner":"acme/web"},"reviewRequests":{"totalCount":1},"statusCheckRollup":{"state":"PENDING"}}, {}]},
         "requested":{"nodes":[]},"known":[null]}}
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(GitHubGraphQLResponse<GitHubIndexPayload>.self, from: Data(json.utf8))
        let payload = try #require(response.data)
        #expect(payload.viewer.login == "atul")
        #expect(payload.authored.items.compactMap(\.id) == ["PR_1"])
        #expect(payload.authored.items.first?.fingerprint.contains("PENDING") == true)
    }
}

extension ObservedEvent {
    var isMine: Bool { metadata["actorIsMe"] == "true" }
}
