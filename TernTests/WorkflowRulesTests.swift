import Foundation
import Testing
@testable import Tern

/// Team workflow rules: a "ready to merge" label hands an approved pull request to a lead.
@Suite("Workflow rules")
@MainActor
struct WorkflowRulesTests {
    private static let label = "ready to merge"

    private func labeled(_ id: String, at minutes: Double, name: String = label) -> GitHubPullRequest.TimelineItem {
        .init(typename: "LabeledEvent", id: id, createdAt: GH.at(minutes), actor: GH.user("lead"), requestedReviewer: nil, review: nil, label: .init(name: name))
    }

    private func unlabeled(_ id: String, at minutes: Double, name: String = label) -> GitHubPullRequest.TimelineItem {
        .init(typename: "UnlabeledEvent", id: id, createdAt: GH.at(minutes), actor: GH.user("lead"), requestedReviewer: nil, review: nil, label: .init(name: name))
    }

    /// My PR, approved by sarah on the current head, with optional extra reviews and timeline.
    private func pr(
        reviews: [GitHubPullRequest.Review] = [],
        timeline: [GitHubPullRequest.TimelineItem] = [],
        comments: [GitHubPullRequest.Comment] = [],
        labels: [String] = []
    ) -> GitHubPullRequest {
        var pr = GH.pr(reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5), on: "sha1")] + reviews,
                       comments: comments, timeline: timeline)
        pr.labels = GitHubNodes(nodes: labels.map { GitHubLabel(name: $0) })
        return pr
    }

    private func service(_ rules: WorkflowRules = .standard) async throws -> IngestionService {
        let service = IngestionService(store: InMemoryTernStore(), rules: rules, now: { GH.t0 })
        try await service.start()
        return service
    }

    private func only(_ service: IngestionService) async throws -> Workstream {
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        return try #require(workstreams.first)
    }

    @Test("Approved + ready-to-merge label: the manager owns the merge; it waits, silently")
    func handedOff() async throws {
        let service = try await service()
        let report = try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label])))
        let ws = try await only(service)
        #expect(ws.nextOwner == .external)
        #expect(ws.state == .waiting)
        #expect(ws.attention == .silent)
        #expect(ws.nextAction == nil)
        #expect(ws.status.headline == "Waiting for manager to merge")
        #expect(!ws.needsAttentionNow)
        #expect(report.notifications.isEmpty)
    }

    @Test("Approved without the label: the normal decision, merge is mine")
    func withoutLabel() async throws {
        let service = try await service()
        let report = try await service.ingest(GH.events(pr(labels: ["bug"])))
        let ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.nextAction?.title == "Merge")
        #expect(ws.attention == .medium)
        #expect(report.notifications.map(\.headline) == ["Approved"])
    }

    @Test("The label is configuration, not GitHub logic: without rules it changes nothing")
    func noRules() async throws {
        let service = try await service(.none)
        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label])))
        #expect(try await only(service).nextAction?.title == "Merge")
    }

    @Test("A label applied before the timeline window still counts; matching ignores case")
    func labelFromCurrentLabels() async throws {
        let service = try await service()
        try await service.ingest(GH.events(pr(labels: ["Ready To Merge"])))
        #expect(try await only(service).nextOwner == .external)
    }

    @Test("Removing the label re-evaluates ownership: the merge comes back to me")
    func labelRemoved() async throws {
        let service = try await service()
        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label])), mode: .historyImport)
        #expect(try await only(service).nextOwner == .external)

        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10), unlabeled("L2", at: 20)])))
        let ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.nextAction?.title == "Merge")
    }

    @Test("Changes requested after ready-to-merge: the next action is mine, high")
    func changesRequestedAfterLabel() async throws {
        let service = try await service()
        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label])), mode: .historyImport)
        let report = try await service.ingest(GH.events(pr(
            reviews: [GH.review(2, "CHANGES_REQUESTED", by: "lead", at: GH.at(20), on: "sha1")],
            timeline: [labeled("L1", at: 10)], labels: [Self.label]
        )))
        let ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
        #expect(ws.nextAction?.title == "Address requested changes")
        #expect(report.notifications.map(\.headline) == ["Changes requested"])
    }

    @Test("New review feedback after ready-to-merge brings it back to me")
    func feedbackAfterLabel() async throws {
        let service = try await service()
        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label])), mode: .historyImport)
        try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], comments: [GH.comment(7, by: "lead", at: GH.at(30))], labels: [Self.label])))
        let ws = try await only(service)
        #expect(ws.nextOwner == .me)
        #expect(ws.nextAction?.title == "Reply to review")
    }

    @Test("A manager-owned merge never notifies, and stays out of Needs you")
    func neverNotifies() async throws {
        let service = try await service()
        var headlines: [String] = []
        // Opened and approved while I'm watching, then labeled, then re-synced and re-labeled.
        headlines += try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label]))).notifications.map(\.headline)
        headlines += try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10)], labels: [Self.label]))).notifications.map(\.headline)
        headlines += try await service.ingest(GH.events(pr(timeline: [labeled("L1", at: 10), unlabeled("L2", at: 20), labeled("L3", at: 21)],
                                                           labels: [Self.label]))).notifications.map(\.headline)
        #expect(!headlines.contains("Approved"))
        #expect(try await only(service).nextOwner == .external)

        let model = AppModel(service: service)
        for _ in 0..<200 where model.waiting.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.needsYou.isEmpty)
        #expect(model.attentionQueue.isEmpty)
        #expect(model.waiting.map(\.status.headline) == ["Waiting for manager to merge"])
    }

    @Test("Rules are read from defaults; absent or unreadable means the standard rule")
    func configuration() throws {
        let defaults = try #require(UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)"))
        #expect(WorkflowRules.load(from: defaults) == .standard)
        #expect(WorkflowRules.standard.mergeHandOffs.map(\.label) == [Self.label])

        defaults.set(#"{"mergeHandOffs":[{"label":"merge-me","mergedBy":"lead"}]}"#, forKey: WorkflowRules.defaultsKey)
        #expect(WorkflowRules.load(from: defaults).mergeHandOffs == [.init(label: "merge-me", mergedBy: "lead")])

        defaults.set(#"{"mergeHandOffs":[]}"#, forKey: WorkflowRules.defaultsKey)
        #expect(WorkflowRules.load(from: defaults) == .none)

        defaults.set("not json", forKey: WorkflowRules.defaultsKey)
        #expect(WorkflowRules.load(from: defaults) == .standard)
    }

    @Test("GitHub label changes become ordered label events")
    func normalization() {
        let events = GH.events(pr(timeline: [labeled("L1", at: 10), unlabeled("L2", at: 20)], labels: []))
        let labels = events.filter { $0.kind == .pullRequestLabeled || $0.kind == .pullRequestUnlabeled }
        #expect(labels.map(\.kind) == [.pullRequestLabeled, .pullRequestUnlabeled])
        #expect(labels.map(\.id.rawValue) == ["github:timeline:L1", "github:timeline:L2"])
        #expect(labels.allSatisfy { $0.metadata[MetadataKey.label.rawValue] == Self.label })
    }
}
