import Foundation
import Testing
@testable import Tern

// MARK: - Import state

@Suite("Import state", .serialized)
struct ImportStateTests {
    private func history() -> [GitHubPullRequest] {
        [
            GH.pr(reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")]),
            GH.pr(id: "PR_2", number: 430, title: "Rate limiter", head: "rate", reviews: [GH.review(2, "CHANGES_REQUESTED", by: "priya", at: GH.at(6), on: "sha1")]),
        ]
    }

    @Test("A fresh store imports all history silently and records the import with the events")
    func freshImport() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = history() }
        await h.sync.syncOnce()
        #expect(await h.notificationCount() == 0)
        let saved = h.store.load()
        #expect(saved.completedImports == ["github:atul"])
        #expect(!saved.workstreams.flatMap(\.events).isEmpty)
    }

    @Test("A relaunch on the same store neither re-imports nor re-notifies")
    func relaunch() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = history() }
        await h.sync.syncOnce()
        let relaunched = try await h.relaunched()
        await relaunched.sync.syncOnce()
        #expect(await relaunched.notificationCount() == 0)
        #expect(h.store.load().completedImports == ["github:atul"])
    }

    @Test("Another build's activity on its own store can't make history look new here")
    func separateBuilds() async throws {
        // A debug build (its own, in-memory store) syncs the account first…
        let debug = try await GitHubHarness()
        debug.github.update { $0.pullRequests = history() }
        await debug.sync.syncOnce()
        #expect(await debug.ingestion.hasCompletedImport("github:atul"))

        // …then the release build starts on an empty store: still a silent import.
        let release = try await GitHubHarness()
        release.github.update { $0.pullRequests = history() }
        await release.sync.syncOnce()
        #expect(await release.notificationCount() == 0)
        #expect(await release.ingestion.snapshot.workstreams.count == 2)
    }

    @Test("Rebuilding the app (restarting on saved state) can't turn history into news")
    func rebuild() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = history() }
        await h.sync.syncOnce()
        let shown = h.store.load().shownTransitions

        // Same saved state, new process: everything is re-fetched and re-evaluated.
        let rebuilt = try await h.relaunched()
        await rebuilt.sync.syncOnce()
        #expect(await rebuilt.notificationCount() == 0)
        #expect(h.store.load().shownTransitions == shown)
    }

    @Test("A new event after the import still notifies")
    func newEventNotifies() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("priya")])] }
        await h.sync.syncOnce()
        h.github.update { $0.pullRequests = [GH.pr(updated: GH.at(30), reviews: [GH.review(9, "CHANGES_REQUESTED", by: "priya", at: GH.at(30))])] }
        await h.sync.syncOnce()
        #expect(await h.notificationCount() == 1)
    }

    @Test("Reconnecting Plane after a disconnect imports silently again")
    func planeReconnect() async throws {
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item()] }
        await h.sync.syncOnce()
        let key = PlaneSyncService.importKey(workspace: PL.workspace, userID: PL.me)
        #expect(await h.ingestion.hasCompletedImport(key))
        await h.sync.forgetImport()
        #expect(await !h.ingestion.hasCompletedImport(key))
    }
}

// MARK: - Approvals

@Suite("Approvals on the current head")
struct ApprovalTests {
    private func evaluate(_ prs: GitHubPullRequest...) async throws -> Workstream {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        for pr in prs { try await service.ingest(GH.events(pr)) }
        return try #require(await service.snapshot.workstreams.first)
    }

    @Test("Approved on the current head: merge, with an explanation")
    func currentHead() async throws {
        let ws = try await evaluate(GH.pr(headSHA: "sha1", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")]))
        #expect(ws.nextAction?.title == "Merge")
        #expect(ws.nextAction?.reason == "sarah approved the current head")
        #expect(ws.evaluation.decision.reason == .approvedReadyToMerge)
    }

    @Test("A new commit after the approval removes the merge suggestion")
    func stale() async throws {
        let approved = GH.pr(headSHA: "sha1", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")])
        let pushed = GH.pr(headSHA: "sha2", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")], commitAt: GH.at(10))
        let ws = try await evaluate(approved, pushed)
        #expect(ws.nextAction?.title != "Merge")
        #expect(ws.evaluation.decision.reason == .approvalOutdated)
        #expect(ws.attention == .low)
        #expect(ws.nextAction?.reason == "New commits since sarah approved")
    }

    @Test("Re-approval of the new head brings merge back")
    func reapproved() async throws {
        let pushed = GH.pr(headSHA: "sha2", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")], commitAt: GH.at(10))
        let again = GH.pr(headSHA: "sha2", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1"),
                                                     GH.review(2, "APPROVED", by: "sarah", at: GH.at(20), on: "sha2")], commitAt: GH.at(10))
        let ws = try await evaluate(pushed, again)
        #expect(ws.nextAction?.title == "Merge")
    }

    @Test("Changes requested on the current head need me")
    func changesOnCurrentHead() async throws {
        let ws = try await evaluate(GH.pr(headSHA: "sha2", reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(15), on: "sha2")], commitAt: GH.at(10)))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.evaluation.decision.reason == .changesRequested)
    }

    @Test("Pushing after a change request explains itself")
    func changesPushedWhy() async throws {
        let ws = try await evaluate(GH.pr(headSHA: "sha2", reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5), on: "sha1")], commitAt: GH.at(10)))
        #expect(ws.nextAction?.title == "Re-request review from priya")
        #expect(ws.nextAction?.reason == "You pushed changes after priya's change request")
        #expect(ws.evaluation.decision.reason == .changesPushed)
    }
}

// MARK: - Agents and merge

@Suite("Agents and merge")
struct AgentMergeTests {
    private func claude(_ event: String, seq: Int, notification: String? = nil) throws -> ObservedEvent {
        try #require(ClaudeHookNormalizer.normalize(ClaudeHookPayload(
            hookEventName: event, sessionID: "s1", promptID: "p1", cwd: "/Users/me/web", notificationType: notification,
            sequence: seq, timestampMilliseconds: Int64(GH.at(Double(10 + seq)).timeIntervalSince1970 * 1000),
            gitRoot: "/Users/me/web", gitRemote: "acme/web", gitBranch: "feat/avatar-migration"
        ), receivedAt: GH.t0))
    }

    private let approved = GH.pr(headSHA: "sha1", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")],
                                 checks: [GH.check(1, "build", at: GH.at(6))])

    @Test("An agent at work blocks a merge recommendation")
    func agentBlocksMerge() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        try await service.ingest(GH.events(approved))
        try await service.ingest([try claude("UserPromptSubmit", seq: 1)])
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(await service.snapshot.workstreams.count == 1)
        #expect(ws.nextOwner == .agent)
        #expect(ws.nextAction?.title != "Merge")
        #expect(ws.status.headline == "Claude working")
    }

    @Test("When the agent finishes, the turn comes back to me")
    func agentFinishes() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        try await service.ingest(GH.events(approved))
        try await service.ingest([try claude("UserPromptSubmit", seq: 1), try claude("Stop", seq: 2)])
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(ws.nextOwner == .me)
        #expect(ws.evaluation.decision.reason == .agentCompleted)
    }

    @Test("An agent needing input stays high and outranks a merge elsewhere")
    func needsInputRanks() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        try await service.ingest(GH.events(GH.pr(id: "PR_2", number: 430, title: "Other", head: "other",
                                                 reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")])))
        try await service.ingest([try claude("UserPromptSubmit", seq: 1), try claude("Notification", seq: 2, notification: "permission_prompt")])
        let ranked = PriorityModel.ranked(await service.snapshot.workstreams, importance: { _ in .normal }, now: GH.at(15))
        #expect(ranked.first?.evaluation.decision.reason == .agentNeedsInput)
        #expect(ranked.first?.attention == .high)
    }
}

// MARK: - Priority and the queue

@Suite("Attention queue")
@MainActor
struct AttentionQueueTests {
    /// A model over the given pull requests, with the clock at `now`.
    private func model(_ prs: [GitHubPullRequest], importance: [String: RepositoryImportance] = [:], now: Date = GH.at(60)) async throws -> AppModel {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        for (repository, value) in importance { try await service.setImportance(value, forRepository: repository) }
        try await service.ingest(prs.flatMap { GH.events($0) }, mode: .historyImport)
        let model = AppModel(service: service)
        model.now = { now }
        for _ in 0..<300 where model.workstreams.count < prs.count || model.importance.count < importance.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return model
    }

    @Test("Passive PRs (draft, no reviewer) don't flood Needs You; they're your other work")
    func passiveWork() async throws {
        let m = try await model([
            GH.pr(id: "D", number: 1, title: "Draft", head: "d", isDraft: true),
            GH.pr(id: "N", number: 2, title: "No reviewer", head: "n"),
            GH.pr(id: "C", number: 3, title: "Changes", head: "c", reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(30))]),
        ])
        #expect(m.needsYou.map(\.title) == ["Changes"])
        #expect(Set(m.yourWork.map(\.title)) == ["Draft", "No reviewer"])
        #expect(m.attentionQueue.count == 1)
    }

    @Test("Waiting items are silent and listed as waiting")
    func waiting() async throws {
        let m = try await model([GH.pr(requests: [GH.reviewer("sarah")])])
        #expect(m.needsYou.isEmpty)
        #expect(m.waiting.first?.attention == .silent)
        #expect(m.waiting.first?.status.headline == "Waiting for sarah")
    }

    @Test("At most three items need you; the rest stay reachable under More")
    func capped() async throws {
        let prs = (1...5).map { n in
            GH.pr(id: "P\(n)", number: n, title: "PR \(n)", head: "b\(n)",
                  reviews: [GH.review(n, "CHANGES_REQUESTED", by: "priya", at: GH.at(Double(n)))])
        }
        let m = try await model(prs)
        #expect(m.needsYou.count == 3)
        #expect(m.more.count == 2)
        #expect(Set((m.needsYou + m.more).map(\.title)) == Set(prs.map(\.title)))
    }

    @Test("Primary work outranks low-priority work when otherwise equal")
    func relevance() {
        let now = GH.at(60)
        let lowPriority = workstream(id: "side", reason: .changesRequested, attention: .high, changed: GH.at(50))
        let primary = workstream(id: "work", reason: .changesRequested, attention: .high, changed: GH.at(50))
        let importance: (Workstream) -> RepositoryImportance = { $0.id.rawValue == "work" ? .primary : .lowPriority }
        #expect(PriorityModel.ranked([lowPriority, primary], importance: importance, now: now).map(\.id.rawValue) == ["work", "side"])
    }

    @Test("Marking a repository updates the queue")
    func markRepository() async throws {
        let m = try await model([GH.pr(reviews: [GH.review(1, "CHANGES_REQUESTED", by: "x", at: GH.at(5))])])
        #expect(m.needsYou.count == 1)
        try await m.setImportanceAndWait(.muted, for: m.workstreams[0])
        #expect(m.needsYou.isEmpty)
        #expect(m.more.count == 1)
    }

    @Test("A low-priority CI failure ranks below approved primary work")
    func lowPriorityCIBelowPrimaryMerge() {
        let now = GH.at(60)
        let ci = workstream(reason: .ciFailed, attention: .high, changed: GH.at(55))
        let merge = workstream(reason: .approvedReadyToMerge, attention: .medium, changed: GH.at(10))
        let ciLowPriority = PriorityModel.priority(of: ci, importance: .lowPriority, now: now)
        let mergePrimary = PriorityModel.priority(of: merge, importance: .primary, now: now)
        #expect(mergePrimary > ciLowPriority)
        // And at equal (normal) relevance, the failure still wins: relevance is the user's lever.
        #expect(PriorityModel.priority(of: ci, importance: .normal, now: now) > PriorityModel.priority(of: merge, importance: .normal, now: now))
    }

    @Test("Active work outranks unrelated stale work; recent transitions outrank old ones")
    func activeAndRecent() {
        let now = GH.at(60 * 24 * 30)
        let stale = workstream(reason: .agentCompleted, attention: .medium, changed: GH.at(0))
        let recent = workstream(reason: .agentCompleted, attention: .medium, changed: now.addingTimeInterval(-600))
        #expect(PriorityModel.priority(of: recent, importance: .normal, now: now) > PriorityModel.priority(of: stale, importance: .normal, now: now))

        var active = stale
        active.agentSessions = [AgentSession(id: "s", agentName: "Claude Code", status: .working, startedAt: now, updatedAt: now)]
        #expect(PriorityModel.priority(of: active, importance: .normal, now: now) > PriorityModel.priority(of: stale, importance: .normal, now: now))
    }

    @Test("A muted repository never takes a Needs You slot")
    func muted() async throws {
        let m = try await model([GH.pr(checks: [GH.check(1, "build", conclusion: "FAILURE", at: GH.at(59))])], importance: ["acme/web": .muted])
        #expect(m.needsYou.isEmpty)
        #expect(m.more.count == 1)
    }

    @Test("Ranking is deterministic regardless of input order")
    func deterministic() {
        let now = GH.at(60)
        let items = (0..<6).map { n in workstream(id: "w\(n)", reason: n % 2 == 0 ? .ciFailed : .approvedReadyToMerge, attention: .medium, changed: GH.at(Double(n % 3))) }
        let a = PriorityModel.ranked(items, importance: { _ in .normal }, now: now).map(\.id)
        let b = PriorityModel.ranked(items.reversed(), importance: { _ in .normal }, now: now).map(\.id)
        #expect(a == b)
    }

    @Test("Done shows only what finished today")
    func doneToday() async throws {
        let merged = GH.pr(state: "MERGED", merged: true, timeline: [GH.timeline("MergedEvent", id: "M", at: GH.at(30))])
        #expect(try await model([merged], now: GH.at(60)).doneToday.count == 1)
        #expect(try await model([merged], now: GH.at(60 * 48)).doneToday.isEmpty)
    }

    @Test("Repository importance is saved with Tern's state")
    func importancePersists() async throws {
        let store = InMemoryTernStore()
        let service = IngestionService(store: store, scoping: .ignoringContexts)
        try await service.start()
        try await service.setImportance(.lowPriority, forRepository: "Acme/Web")
        #expect(store.load().repositoryImportance == ["github.com/acme/web": .lowPriority])
        try await service.setImportance(.normal, forRepository: "acme/web")
        #expect(store.load().repositoryImportance.isEmpty)
    }

    /// A bare workstream whose evaluation says the user owns it for `reason`.
    private func workstream(id: String = "w", reason: AttentionReason, attention: AttentionLevel, changed: Date) -> Workstream {
        var ws = Workstream(id: WorkstreamID(id), title: id)
        ws.evaluation = WorkstreamEvaluation(
            decision: AttentionDecision(shouldNotify: false, state: .needsAttention, nextOwner: .me, attention: attention, nextAction: nil, reason: reason),
            status: StatusLine(headline: id),
            lastMeaningfulChange: changed,
            transition: .initial
        )
        return ws
    }
}

extension AppModel {
    /// Sets importance and waits for the change to come back from the service.
    func setImportanceAndWait(_ value: RepositoryImportance, for workstream: Workstream) async throws {
        setImportance(value, for: workstream)
        for _ in 0..<300 where importance(of: workstream) != value {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
