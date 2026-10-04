import Foundation
import Testing
@testable import Tern

/// Personal vs professional: classification, scoping of the queue and badge, notification
/// bookkeeping, and persistence of the user's choice.
@Suite("Contexts")
@MainActor
struct ContextTests {
    static let work = "makeplane/plane-ee"
    static let side = "atul/blog"
    static let stranger = "someone/else"

    /// Work at `makeplane`, side projects under `atul`; everything else unknown.
    static let rules: ContextRules = {
        var rules = ContextRules()
        rules.set(.professional, forOwner: "makeplane")
        rules.set(.personal, forOwner: "atul")
        return rules
    }()

    /// My pull request in `repository`, with a failing check `minutes` after opening (high, mine).
    private func failingPR(_ repository: String, _ number: Int, at minutes: Double = 1, id: String? = nil) -> [ObservedEvent] {
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number)
        let tag = id ?? "\(repository)#\(number)"
        func event(_ kind: WorkEventKind, _ suffix: String, _ at: Double, _ metadata: [MetadataKey: String]) -> ObservedEvent {
            ObservedEvent(id: EventID(.github, "ctx", tag, suffix), source: .github, kind: kind, timestamp: GH.at(at),
                          metadata: metadata, references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr)
        }
        return [
            event(.pullRequestOpened, "opened", 0, [.role: "author", .actor: GH.me, .actorIsMe: "true"]),
            event(.ciFailed, "ci-\(minutes)", minutes, [.checkName: "build"]),
        ]
    }

    private func service(_ store: InMemoryTernStore = InMemoryTernStore(), active: TernContext = .professional,
                         rules: ContextRules = ContextTests.rules) async throws -> IngestionService {
        let service = IngestionService(store: store, now: { GH.t0 })
        try await service.start()
        try await service.setActiveContext(active)
        for (owner, context) in rules.owners { try await service.setContext(context, forOwner: owner) }
        for (repository, context) in rules.repositories { try await service.setContext(context, repository: repository) }
        return service
    }

    private func model(_ service: IngestionService) async throws -> AppModel {
        let model = AppModel(service: service)
        let expected = await service.snapshot.workstreams.count
        for _ in 0..<200 where !(model.isContextScoped && model.workstreams.count == expected) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.isContextScoped)
        return model
    }

    private func settle(_ model: AppModel, until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    // MARK: Classification

    @Test("Owners and repositories classify deterministically; unknown is unclassified, never guessed")
    func classification() {
        var rules = Self.rules
        #expect(rules.context(forRepository: Self.work) == .professional)
        #expect(rules.context(forRepository: "github.com/MakePlane/Plane") == .professional)
        #expect(rules.context(forRepository: Self.side) == .personal)
        #expect(rules.context(forRepository: Self.stranger) == .unclassified)

        // A repository rule beats its owner's.
        rules.set(.personal, forRepository: "makeplane/dotfiles")
        #expect(rules.context(forRepository: "makeplane/dotfiles") == .personal)
        #expect(rules.context(forRepository: Self.work) == .professional)
        rules.set(nil, forRepository: "makeplane/dotfiles")
        #expect(rules.context(forRepository: "makeplane/dotfiles") == .professional)
    }

    @Test("Plane makes work professional; a Plane item in an explicitly personal repository is a conflict, left unclassified")
    func planeIsProfessional() {
        let planeOnly = Workstream(id: WorkstreamID("p"), title: "Plane", planeItem: PlaneItemReference(identifier: "WEB-1"))
        #expect(Self.rules.context(of: planeOnly) == .professional)
        #expect(ContextRules.none.context(of: planeOnly) == .professional)

        let conflict = Workstream(id: WorkstreamID("c"), title: "C", planeItem: PlaneItemReference(identifier: "WEB-2"),
                                  pullRequest: PullRequestReference(repository: Self.side, number: 1))
        #expect(Self.rules.context(of: conflict) == .unclassified)

        let nowhere = Workstream(id: WorkstreamID("n"), title: "Scratch")
        #expect(Self.rules.context(of: nowhere) == .unclassified)
    }

    @Test("A Claude session in a GitHub checkout is classified by its repository")
    func claudeSessionRepository() async throws {
        let service = try await service(active: .personal)
        let payload = ClaudeHookPayload(hookEventName: "UserPromptSubmit", sessionID: "s1", promptID: "p1", cwd: "/x/blog",
                                        sequence: 1, gitRoot: "/x/blog", gitRemote: Self.side, gitBranch: "main")
        let report = try await service.ingest([try #require(ClaudeHookNormalizer.normalize(payload, receivedAt: GH.t0))])
        #expect(report.accepted.count == 1)
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(ws.repositoryKey == "github.com/atul/blog")
        #expect(Self.rules.context(of: ws) == .personal)
    }

    // MARK: Scoping

    @Test("Personal excludes Plane; Professional includes it")
    func planeOnlyInProfessional() async throws {
        let service = try await service(active: .personal)
        try await service.ingest(PL.events(PL.item(state: PL.todo)), mode: .historyImport)
        let model = try await model(service)
        #expect(model.scoped.isEmpty)
        #expect(model.unclassified.isEmpty)

        model.setActiveContext(.professional)
        #expect(model.scoped.map(\.planeItem?.identifier) == ["WEB-9295"])
    }

    @Test("Each repository's work appears only in its own context; unclassified in neither")
    func repositoriesStayInTheirContext() async throws {
        let service = try await service(active: .professional)
        try await service.ingest(failingPR(Self.work, 1) + failingPR(Self.side, 2) + failingPR(Self.stranger, 3), mode: .historyImport)
        let model = try await model(service)

        #expect(model.needsYou.map(\.pullRequest?.repository) == [Self.work])
        model.setActiveContext(.personal)
        #expect(model.needsYou.map(\.pullRequest?.repository) == [Self.side])
        for context in TernContext.allCases {
            model.setActiveContext(context)
            #expect(!model.scoped.contains { $0.pullRequest?.repository == Self.stranger })
            #expect(model.unclassified.map(\.pullRequest?.repository) == [Self.stranger])
        }
    }

    @Test("Switching context changes Needs you and the badge at once")
    func switchingChangesQueueAndBadge() async throws {
        let service = try await service(active: .professional)
        try await service.ingest(failingPR(Self.work, 1) + failingPR(Self.work, 2) + failingPR(Self.side, 3), mode: .historyImport)
        let model = try await model(service)
        #expect(model.attentionQueue.count == 2)
        #expect(model.needsYou.count == 2)

        model.setActiveContext(.personal)
        #expect(model.attentionQueue.count == 1)
        #expect(model.needsYou.map(\.pullRequest?.number) == [3])

        // Classifying the unknown repository brings it into a context.
        try await service.ingest(failingPR(Self.stranger, 4), mode: .historyImport)
        try await settle(model) { model.unclassified.count == 1 }
        #expect(model.attentionQueue.count == 1)
        model.setContext(.personal, forOwner: "someone")
        #expect(model.attentionQueue.count == 2)
        #expect(model.unclassified.isEmpty)
    }

    @Test("Live events from the inactive context change neither the active queue nor notify")
    func inactiveContextIsQuiet() async throws {
        let service = try await service(active: .personal)
        let model = try await model(service)
        let report = try await service.ingest(failingPR(Self.work, 1) + failingPR(Self.stranger, 2))
        #expect(report.accepted.count == 4)
        #expect(report.notifications.isEmpty)
        try await settle(model) { model.workstreams.count == 2 }
        #expect(model.attentionQueue.isEmpty)
        #expect(model.needsYou.isEmpty)

        // The same kind of event in the active context does notify.
        let personal = try await service.ingest(failingPR(Self.side, 3))
        #expect(personal.notifications.map(\.headline) == ["CI failed"])
    }

    @Test("Notification bookkeeping is per context: work seen while away still notifies in its own context")
    func bookkeepingIsolated() async throws {
        let store = InMemoryTernStore()
        let service = try await service(store, active: .personal)
        // While in Personal, professional CI fails: nothing is shown or recorded as seen.
        #expect(try await service.ingest(failingPR(Self.work, 1)).notifications.isEmpty)
        #expect(store.load().shownTransitions.isEmpty)
        // Personal work still notifies, unaffected by the professional event.
        #expect(try await service.ingest(failingPR(Self.side, 2)).notifications.count == 1)

        // Back in Professional, the next change on that PR is news there.
        try await service.setActiveContext(.professional)
        let later = try await service.ingest([failingPR(Self.work, 1, at: 5)[1]])
        #expect(later.notifications.map(\.headline) == ["CI failed"])
        // And the personal PR's next change, now out of context, is quiet.
        #expect(try await service.ingest([failingPR(Self.side, 2, at: 6)[1]]).notifications.isEmpty)
    }

    @Test("The active context and classifications survive a restart")
    func persists() async throws {
        let store = InMemoryTernStore()
        let first = try await service(store, active: .personal)
        try await first.setContext(.professional, repository: "atul/work-notes")
        let restarted = IngestionService(store: store)
        let snapshot = try await restarted.start()
        #expect(snapshot.activeContext == .personal)
        #expect(snapshot.contextRules.context(forRepository: "atul/work-notes") == .professional)
        #expect(snapshot.contextRules.context(forRepository: Self.work) == .professional)

        // Importance saved under its old name loads as low priority, and saves under the new one.
        let importance = try JSONDecoder().decode([String: RepositoryImportance].self, from: Data(#"{"github.com/a/b":"personal"}"#.utf8))
        #expect(importance == ["github.com/a/b": .lowPriority])
        #expect(String(decoding: try JSONEncoder().encode(RepositoryImportance.lowPriority), as: UTF8.self) == #""lowPriority""#)

        // State written before contexts existed loads as Professional with no rules.
        let legacy = #"{"version":1,"workstreams":[],"links":[],"shownTransitions":[],"notifications":[]}"#
        let decoded = try JSONDecoder().decode(PersistedState.self, from: Data(legacy.utf8))
        #expect(decoded.activeContext == .professional)
        #expect(decoded.contextRules == .none)
    }

    @Test("Debug-only ignoring of contexts (engine tests) lets every workstream take part")
    func unscopedIgnoresContexts() async throws {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 }, scoping: .ignoringContexts)
        try await service.start()
        let report = try await service.ingest(failingPR(Self.stranger, 1))
        #expect(report.notifications.count == 1)
        let model = AppModel(service: service)
        try await settle(model) { model.workstreams.count == 1 }
        #expect(model.attentionQueue.count == 1)
        #expect(model.unclassified.isEmpty)
    }

    @Test("The app's service is always context-scoped; ignoring contexts is an explicit Debug-only opt-out")
    func scopedByDefault() async throws {
        let service = IngestionService(store: InMemoryTernStore())
        #expect(try await service.start().isContextScoped)
        #expect(try await service.ingest(failingPR(Self.stranger, 1)).notifications.isEmpty)
    }

    @Test("Switching back surfaces pending work in the queue without re-notifying; switching alone never notifies")
    func switchingSurfacesWithoutDuplicates() async throws {
        let store = InMemoryTernStore()
        let service = try await service(store, active: .professional)
        let model = try await model(service)
        // A: professional work while Professional is active notifies once.
        #expect(try await service.ingest(failingPR(Self.work, 1)).notifications.count == 1)
        // B, D: switch to Personal; professional work changes quietly, and so does personal work while away later.
        model.setActiveContext(.personal)
        await model.changesSaved()
        #expect(try await service.ingest(failingPR(Self.work, 2)).notifications.isEmpty)
        // C: back in Professional, both professional items are in the queue.
        model.setActiveContext(.professional)
        await model.changesSaved()
        try await settle(model) { model.workstreams.count == 2 }
        #expect(model.needsYou.compactMap(\.pullRequest?.number).sorted() == [1, 2])
        // D: personal work while Professional is active is quiet; E: it surfaces in Personal.
        #expect(try await service.ingest(failingPR(Self.side, 3)).notifications.isEmpty)
        try await settle(model) { model.workstreams.count == 3 }
        #expect(model.needsYou.count == 2)
        model.setActiveContext(.personal)
        #expect(model.needsYou.map(\.pullRequest?.number) == [3])
        // Switching back and forth, and replaying the same events, adds no notifications.
        for context in [TernContext.professional, .personal, .professional] { try await service.setActiveContext(context) }
        #expect(try await service.ingest(failingPR(Self.work, 1) + failingPR(Self.side, 3)).notifications.isEmpty)
        #expect(store.load().notifications.count == 1)
    }

    @Test("Classifying: owner rules apply at once, repository overrides win and stay put, clearing returns to unclassified")
    func classificationEdits() async throws {
        let service = try await service(active: .personal, rules: .none)
        try await service.ingest(failingPR("acme/api", 1) + failingPR("acme/web", 2) + failingPR(Self.side, 3), mode: .historyImport)
        let model = try await model(service)
        #expect(model.unclassified.count == 3)
        #expect(model.needsYou.isEmpty)

        model.setContext(.personal, forOwner: "acme")
        #expect(model.needsYou.compactMap(\.pullRequest?.repository).sorted() == ["acme/api", "acme/web"])
        model.setContext(.professional, repository: "acme/web")
        #expect(model.needsYou.map(\.pullRequest?.repository) == ["acme/api"])
        // Changing the owner again doesn't move the overridden repository.
        model.setContext(.professional, forOwner: "acme")
        model.setActiveContext(.professional)
        #expect(model.needsYou.compactMap(\.pullRequest?.repository).sorted() == ["acme/api", "acme/web"])
        model.setContext(.personal, repository: "acme/api")
        #expect(model.needsYou.map(\.pullRequest?.repository) == ["acme/web"])
        // Clearing the owner leaves only the overrides.
        model.setContext(nil, forOwner: "acme")
        #expect(model.needsYou.map(\.pullRequest?.repository) == ["acme/web"])
        model.setContext(nil, repository: "acme/web")
        #expect(model.needsYou.isEmpty)
        #expect(model.unclassified.compactMap(\.pullRequest?.repository).sorted() == ["acme/web", "atul/blog"])

        // All of it was saved, in order.
        await model.changesSaved()
        let saved = await service.snapshot.contextRules
        #expect(saved == model.contextRules)
        #expect(saved.repositories == ["github.com/acme/api": .personal])
    }

    @Test("Scoping filters; it never changes a workstream's priority")
    func priorityUnchanged() async throws {
        let service = try await service(active: .professional)
        try await service.ingest(failingPR(Self.work, 1) + failingPR(Self.side, 2), mode: .historyImport)
        let model = try await model(service)
        let all = await service.snapshot.workstreams
        let work = try #require(all.first { $0.pullRequest?.repository == Self.work })
        let unscoped = PriorityModel.priority(of: work, importance: .normal, now: model.now())
        #expect(model.priority(of: work) == unscoped)
        model.setActiveContext(.personal)
        #expect(model.priority(of: work) == unscoped)
    }
}

/// The merge hand-off rule, in contexts and against stale approvals.
@Suite("Merge hand-off with contexts")
@MainActor
struct MergeHandOffContextTests {
    private func labeled(_ id: String, at minutes: Double) -> GitHubPullRequest.TimelineItem {
        .init(typename: "LabeledEvent", id: id, createdAt: GH.at(minutes), actor: GH.user("lead"), requestedReviewer: nil, review: nil, label: .init(name: "ready to merge"))
    }

    @Test("An approval made stale by a push isn't handed off: re-requesting review is still mine, low")
    func staleApprovalNotHandedOff() async throws {
        let service = IngestionService(store: InMemoryTernStore(), rules: .standard, now: { GH.t0 })
        try await service.start()
        // sarah approved sha1; the head is now sha2.
        var pr = GH.pr(headSHA: "sha2", reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")],
                       timeline: [labeled("L1", at: 10)], commitAt: GH.at(20))
        pr.labels = GitHubNodes(nodes: [GitHubLabel(name: "ready to merge")])
        try await service.ingest(GH.events(pr))
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .low)
        #expect(ws.evaluation.decision.reason == .approvalOutdated)
    }

    @Test("Handed-off merges stay out of Needs you in the professional context and never notify")
    func handOffInContext() async throws {
        let service = IngestionService(store: InMemoryTernStore(), rules: .standard, now: { GH.t0 })
        try await service.start()
        try await service.setContext(.professional, forOwner: "acme")
        var pr = GH.pr(reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")], timeline: [labeled("L1", at: 10)])
        pr.labels = GitHubNodes(nodes: [GitHubLabel(name: "ready to merge")])
        let report = try await service.ingest(GH.events(pr))
        #expect(report.notifications.isEmpty)

        let model = AppModel(service: service)
        for _ in 0..<200 where model.waiting.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.activeContext == .professional)
        #expect(model.needsYou.isEmpty)
        #expect(model.waiting.map(\.nextOwner) == [.external])
        #expect(model.waiting.first?.status.headline == "Waiting for manager to merge")
    }
}
