import Foundation
import Testing
@testable import Tern

@Suite("Ingestion")
struct IngestionServiceTests {
    private var history: [ObservedEvent] {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya", .commentCount: "3"])
        return fixture.observed
    }

    @Test("Re-ingesting the same events changes nothing")
    func duplicatesIgnored() async throws {
        let service = try await makeService()
        try await service.ingest(history)
        let before = try #require(await service.workstream())

        let report = try await service.ingest(history)
        let after = try #require(await service.workstream())

        #expect(report.accepted.isEmpty)
        #expect(report.duplicates == history.map(\.id))
        #expect(report.notifications.isEmpty)
        #expect(after.events == before.events)
        #expect(after.state == before.state)
        #expect(after.nextOwner == before.nextOwner)
        #expect(after.attention == before.attention)
        #expect(after.evaluation == before.evaluation)
    }

    @Test("Duplicates within one batch are dropped")
    func duplicatesWithinBatch() async throws {
        let service = try await makeService()
        let event = history[0]
        let report = try await service.ingest([event, event])
        #expect(report.accepted == [event.id])
        #expect(report.duplicates == [event.id])
        #expect(await service.workstream()?.events.count == 1)
    }

    @Test("A source event keeps its identity when observed again by a later poll")
    func stableIdentityAcrossPolls() async throws {
        let service = try await makeService()
        let timestamp = EventFixture.origin
        let firstPoll = EventFixture.event(.ciFailed, from: .github, id: "check-1", at: timestamp, [.checkName: "lint"])
        let secondPoll = EventFixture.event(.ciFailed, from: .github, id: "check-1", at: timestamp, [.checkName: "lint"])

        try await service.ingest([firstPoll])
        let report = try await service.ingest([secondPoll])

        #expect(firstPoll.id == secondPoll.id)
        #expect(report.duplicates == [secondPoll.id])
        #expect(await service.workstream()?.events.map(\.id) == [firstPoll.id])
    }

    @Test("Events resolve to a workstream through their references, and links are learned")
    func resolvesThroughReferences() async throws {
        let service = try await makeService()
        let session = ExternalReference.agentSession("s1")
        let start = ObservedEvent(
            id: EventID(.agent, "session", "s1", "start"), source: .agent, kind: .agentStarted,
            timestamp: EventFixture.origin, metadata: EventFixture.claude(), references: [session, EventFixture.reference]
        )
        // Later events only carry the session; the link learned from `start` places them.
        let stop = ObservedEvent(
            id: EventID(.agent, "session", "s1", "stop"), source: .agent, kind: .agentCompleted,
            timestamp: EventFixture.origin.addingTimeInterval(60), metadata: EventFixture.claude(), references: [session]
        )

        let report = try await service.ingest([start, stop])
        #expect(report.accepted == [start.id, stop.id])
        #expect(report.createdWorkstreams.isEmpty)
        #expect(await service.workstream()?.events.map(\.workstreamID) == [EventFixture.workstreamID, EventFixture.workstreamID])
    }

    @Test("Unknown references start a new workstream that later events join")
    func unknownReferencesCreateWorkstream() async throws {
        let service = try await makeService()
        let pr = ExternalReference.pullRequest(repository: "acme/app", number: 7)
        let opened = ObservedEvent(
            id: EventID(.github, "pr", "7", "opened"), source: .github, kind: .pullRequestOpened,
            timestamp: EventFixture.origin, references: [pr], suggestedTitle: "Fix login"
        )
        let ci = ObservedEvent(
            id: EventID(.github, "check-run", "1"), source: .github, kind: .ciStarted,
            timestamp: EventFixture.origin.addingTimeInterval(60), references: [pr]
        )

        let first = try await service.ingest([opened])
        let second = try await service.ingest([ci])

        let id = try #require(first.createdWorkstreams.first)
        #expect(second.createdWorkstreams.isEmpty)
        let workstream = try #require(await service.workstream(id))
        #expect(workstream.title == "Fix login")
        #expect(workstream.events.count == 2)
        #expect(workstream.nextOwner == .ci)
    }

    @Test("Existing links are never re-pointed")
    func linksAreStable() {
        var resolver = WorkstreamResolver()
        let a = ExternalReference.planeItem("A-1")
        let b = ExternalReference.planeItem("B-1")
        resolver.link([a], to: WorkstreamID("a"))
        resolver.link([b], to: WorkstreamID("b"))

        #expect(resolver.resolve([b, a]) == WorkstreamID("b"))
        resolver.link([b, a], to: WorkstreamID("b"))
        #expect(resolver.resolve([a]) == WorkstreamID("a"))
    }

    @Test("Events without references are reported as unlinked")
    func unlinkedEvents() async throws {
        let service = try await makeService()
        let orphan = ObservedEvent(
            id: EventID(.github, "orphan"), source: .github, kind: .ciStarted, timestamp: EventFixture.origin, references: []
        )
        let report = try await service.ingest([orphan])
        #expect(report.unlinked == [orphan.id])
        #expect(report.accepted.isEmpty)
    }

    @Test("Ingesting before start is rejected")
    func requiresStart() async {
        let service = IngestionService(store: InMemoryTernStore())
        await #expect(throws: IngestionError.self) {
            try await service.ingest(history)
        }
    }

    @Test("Persisted state round-trips through the JSON file store")
    func jsonRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "tern-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = JSONFileTernStore(url: url)

        let service = IngestionService(store: store, now: { EventFixture.origin })
        try await service.start()
        try await service.register(EventFixture.workstreamID, title: "Test", references: [EventFixture.reference])
        try await service.ingest(history)

        let saved = try store.load()
        #expect(saved.workstreams.first?.events.map(\.id) == history.map(\.id))
        #expect(saved.links.contains(WorkstreamLink(reference: EventFixture.reference, workstreamID: EventFixture.workstreamID)))
        #expect(saved.shownTransitions.count == 1)
        #expect(saved.notifications.count == 1)
    }
}
