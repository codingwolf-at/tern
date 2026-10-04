import Foundation
import Testing
@testable import Tern

/// Ownership and attention for pull requests, through ingestion.
@Suite("GitHub ownership")
struct GitHubOwnershipTests {
    private func evaluate(_ prs: GitHubPullRequest..., requested: Bool = false) async throws -> Workstream {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        for pr in prs {
            try await service.ingest(GH.events(pr, requested: requested))
        }
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        return try #require(workstreams.first)
    }

    @Test("My PR waiting for a reviewer is theirs, silently")
    func waitingForReviewer() async throws {
        let ws = try await evaluate(GH.pr(requests: [GH.reviewer("sarah")]))
        #expect(ws.nextOwner == .reviewer)
        #expect(ws.attention == .silent)
        #expect(ws.state == .waiting)
        #expect(ws.status.headline == "Waiting for sarah")
        #expect(ws.pullRequest?.number == 421)
    }

    @Test("A reviewer requesting changes on my PR is mine, high")
    func changesRequested() async throws {
        let ws = try await evaluate(GH.pr(reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5))]))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.nextAction?.reason == "priya requested changes")
    }

    @Test("A request for my review is mine, high")
    func reviewRequestForMe() async throws {
        let ws = try await evaluate(GH.pr(author: "sarah", requests: [GH.reviewer(GH.me)]), requested: true)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.status.headline == "Review requested")
        #expect(ws.status.detail == "From sarah")
    }

    @Test("My own review and comments never create attention for me")
    func ownActivity() async throws {
        // My comment on my own PR.
        let mine = try await evaluate(GH.pr(
            requests: [GH.reviewer("sarah")],
            threads: [GH.thread("T_1", last: GH.comment(1, by: GH.me, at: GH.at(5)))],
            comments: [GH.comment(2, by: GH.me, at: GH.at(6))]
        ))
        #expect(mine.nextOwner == .reviewer)

        // My review on someone else's PR hands it back to its author.
        let reviewed = try await evaluate(GH.pr(
            author: "sarah",
            reviews: [GH.review(3, "CHANGES_REQUESTED", by: GH.me, at: GH.at(5))],
            timeline: [GH.timeline("ReviewRequestedEvent", id: "RR_1", at: GH.at(1), actor: "sarah", reviewer: GH.reviewer(GH.me))]
        ))
        #expect(reviewed.nextOwner == .external)
        #expect(reviewed.attention == .silent)
        #expect(reviewed.status.headline == "With sarah")
    }

    @Test("A reviewer's comment needs my reply; replying hands it back")
    func reviewerComment() async throws {
        let asked = try await evaluate(GH.pr(threads: [GH.thread("T_1", last: GH.comment(1, by: "priya", at: GH.at(5)))]))
        #expect(asked.nextOwner == .me)
        #expect(asked.status.headline == "Reviewer responded")
        #expect(asked.status.detail == "1 new comment")

        let replied = try await evaluate(GH.pr(
            requests: [GH.reviewer("priya")],
            threads: [GH.thread("T_1", last: GH.comment(2, by: GH.me, at: GH.at(6)))],
            comments: [GH.comment(1, by: "priya", at: GH.at(5))]
        ))
        #expect(replied.nextOwner == .reviewer)
    }

    @Test("Resolving my own thread doesn't hide a reviewer's other comment")
    func resolutionIsPerThread() async throws {
        let ws = try await evaluate(GH.pr(threads: [
            GH.thread("T_1", last: GH.comment(1, by: "priya", at: GH.at(5))),
            GH.thread("T_2", last: GH.comment(2, by: "priya", at: GH.at(4)), resolvedBy: GH.me),
        ]))
        #expect(ws.nextOwner == .me)
        #expect(ws.status.detail == "1 new comment")
    }

    @Test("Approved with green CI: merge is next")
    func approvedAndGreen() async throws {
        let ws = try await evaluate(GH.pr(
            reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5))],
            checks: [GH.check(1, "build", at: GH.at(6)), GH.check(2, "test", at: GH.at(6))]
        ))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .medium)
        #expect(ws.nextAction?.title == "Merge")
    }

    @Test("Draft PRs are a low nudge, not a review wait")
    func draft() async throws {
        let ws = try await evaluate(GH.pr(isDraft: true))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .low)
        #expect(ws.nextAction?.title == "Mark ready for review")
    }

    @Test("Merged or closed PRs are complete")
    func complete() async throws {
        #expect(try await evaluate(GH.pr(state: "MERGED", merged: true, timeline: [GH.timeline("MergedEvent", id: "M", at: GH.at(9))])).state == .complete)
        #expect(try await evaluate(GH.pr(state: "CLOSED", timeline: [GH.timeline("ClosedEvent", id: "C", at: GH.at(9))])).state == .complete)
    }

    @Test("Multiple checks: a failure can't be hidden by passes, pending waits on CI")
    func checks() async throws {
        let mixed = try await evaluate(GH.pr(checks: [
            GH.check(1, "build", at: GH.at(1)),
            GH.check(2, "lint", conclusion: "FAILURE", at: GH.at(2)),
            GH.check(3, "test", at: GH.at(9)),
        ]))
        #expect(mixed.attention == .high)
        #expect(mixed.status.headline == "CI failed")
        #expect(mixed.status.detail == "lint")

        let pending = try await evaluate(GH.pr(requests: [GH.reviewer("sarah")], checks: [
            GH.check(1, "build", at: GH.at(1)),
            GH.check(2, "test", status: "IN_PROGRESS", at: GH.at(2)),
        ]))
        #expect(pending.nextOwner == .ci)
        #expect(pending.attention == .silent)
    }

    @Test("A new head commit replaces the previous commit's checks")
    func newHeadSHA() async throws {
        let failing = GH.pr(headSHA: "old", requests: [GH.reviewer("sarah")], checks: [GH.check(1, "lint", conclusion: "FAILURE", at: GH.at(1))])
        let pushed = GH.pr(headSHA: "new", requests: [GH.reviewer("sarah")], checks: [GH.check(2, "lint", status: "QUEUED", at: GH.at(6))], commitAt: GH.at(5))
        let ws = try await evaluate(failing, pushed)
        #expect(ws.nextOwner == .ci)

        let passed = GH.pr(headSHA: "new", requests: [GH.reviewer("sarah")], checks: [GH.check(2, "lint", at: GH.at(8))], commitAt: GH.at(5))
        let green = try await evaluate(failing, pushed, passed)
        #expect(green.nextOwner == .reviewer)
    }

    @Test("The review loop: reviewer → me → reviewer → me")
    func reviewLoop() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        func step(_ pr: GitHubPullRequest) async throws -> Workstream {
            try await service.ingest(GH.events(pr))
            return try #require(await service.snapshot.workstreams.first)
        }
        let request = GH.timeline("ReviewRequestedEvent", id: "RR_1", at: GH.at(1), reviewer: GH.reviewer("priya"))
        let changes = GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(10))
        let rerequest = GH.timeline("ReviewRequestedEvent", id: "RR_2", at: GH.at(30), reviewer: GH.reviewer("priya"))

        #expect(try await step(GH.pr(requests: [GH.reviewer("priya")], timeline: [request])).nextOwner == .reviewer)

        var ws = try await step(GH.pr(reviews: [changes], timeline: [request]))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)

        // I push fixes: still my move (re-request), but quieter.
        ws = try await step(GH.pr(headSHA: "sha2", reviews: [changes], timeline: [request], commitAt: GH.at(20)))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .low)
        #expect(ws.nextAction?.title == "Re-request review from priya")

        ws = try await step(GH.pr(headSHA: "sha2", requests: [GH.reviewer("priya")], reviews: [changes], timeline: [request, rerequest], commitAt: GH.at(20)))
        #expect(ws.nextOwner == .reviewer)

        ws = try await step(GH.pr(headSHA: "sha2", reviews: [changes, GH.review(2, "APPROVED", by: "priya", at: GH.at(40))], timeline: [request, rerequest], commitAt: GH.at(20)))
        #expect(ws.nextOwner == .me)
        #expect(ws.nextAction?.title == "Merge")
    }

    @Test("A dismissed change request no longer blocks")
    func dismissed() async throws {
        let ws = try await evaluate(GH.pr(
            reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5)), GH.review(2, "APPROVED", by: "sarah", at: GH.at(6))],
            timeline: [GH.timeline("ReviewDismissedEvent", id: "D_1", at: GH.at(7), dismissedReview: 1)]
        ))
        #expect(ws.nextAction?.title == "Merge")
    }
}

@Suite("GitHub workstream linking")
struct GitHubLinkingTests {
    @Test("A PR joins the Claude workstream on the same repository and branch")
    func joinsClaudeWorkstream() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        let receiver = await ClaudeHookReceiver(service: service)
        let payload = ClaudeHookPayload(
            hookEventName: "UserPromptSubmit", sessionID: "s1", promptID: "p1", cwd: "/Users/me/web",
            sequence: 1, timestampMilliseconds: Int64(GH.t0.timeIntervalSince1970 * 1000),
            gitRoot: "/Users/me/web", gitRemote: "acme/web", gitBranch: "feat/avatar-migration"
        )
        await receiver.handle(try ClaudeHookURL.encode(payload))

        let report = try await service.ingest(GH.events(GH.pr()))
        #expect(report.createdWorkstreams.isEmpty)
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        #expect(workstreams.first?.pullRequest?.number == 421)
        #expect(workstreams.first?.agentSessions.count == 1)
    }

    @Test("An unmatched PR creates its own workstream, once")
    func createsOnce() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        let first = try await service.ingest(GH.events(GH.pr()))
        #expect(first.createdWorkstreams.count == 1)
        let again = try await service.ingest(GH.events(GH.pr(updated: GH.at(5))))
        #expect(again.createdWorkstreams.isEmpty)
        #expect(again.accepted.isEmpty)
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(ws.title == "Avatar migration")
        #expect(ws.pullRequest?.title == "Avatar migration")
    }

    @Test("Existing links are not re-pointed")
    func linksStay() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        try await service.register(WorkstreamID("a"), title: "A", pullRequest: PullRequestReference(repository: "acme/web", number: 421))
        try await service.register(WorkstreamID("b"), title: "B", references: [.branch("feat/avatar-migration", repository: "github.com/acme/web")])
        try await service.ingest(GH.events(GH.pr()))
        let snapshot = await service.snapshot
        #expect(snapshot.workstreams.first { $0.id == WorkstreamID("a") }?.events.isEmpty == false)
        #expect(snapshot.workstreams.first { $0.id == WorkstreamID("b") }?.events.isEmpty == true)
    }
}
