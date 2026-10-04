import Foundation
import Testing
@testable import Tern

@Suite("Mock scenario")
struct MockScenarioTests {
    let scenario = MockScenario(now: Date(timeIntervalSince1970: 1_800_000_000))

    private func seededService(liveTail: Int = 0) async throws -> IngestionService {
        let service = IngestionService(store: InMemoryTernStore(), now: { scenario.now })
        try await service.start()
        try await scenario.seed(into: service, liveTail: liveTail)
        return service
    }

    @Test("Avatar migration ends with the reviewer's response back with me")
    func avatarMigration() async throws {
        let service = try await seededService()
        let workstream = try #require(await service.workstream(MockScenario.avatarMigrationID))

        #expect(workstream.events.count == scenario.avatarMigrationScript.count)
        #expect(workstream.nextOwner == .me)
        #expect(workstream.attention == .high)
        #expect(workstream.status.headline == "Reviewer responded")
        #expect(workstream.primaryLabel == "PLANE-1842")
        #expect(workstream.calendarContext?.title == "Avatar rollout sync")
        #expect(workstream.agentSessions.first?.agentName == "Claude Code")
    }

    @Test("Every scripted event is linked through references; none create stray workstreams")
    func linksThroughReferences() async throws {
        let service = try await seededService()
        let ids = await service.snapshot.workstreams.map(\.id)
        #expect(ids == scenario.registrations.map(\.id))
    }

    @Test("Supporting workstreams land in the expected hands")
    func supportingWorkstreams() async throws {
        let service = try await seededService()
        let owners = Dictionary(uniqueKeysWithValues: await service.snapshot.workstreams.map { ($0.id.rawValue, $0.nextOwner) })
        #expect(owners == [
            "avatar-migration": .me,
            "settings-cleanup": .me,
            "rate-limiter": .reviewer,
            "search-indexing": .agent,
            "webhook-retries": .ci,
            "billing-export": .none,
        ])
    }

    @Test("Seeding is silent; playing the last event live notifies once")
    func liveTail() async throws {
        let service = try await seededService(liveTail: 1)
        #expect(await service.snapshot.notifications.isEmpty)

        let last = try #require(scenario.avatarMigrationScript.last)
        #expect(try await service.ingest([last]).notifications.count == 1)
        #expect(try await service.ingest([last]).notifications.isEmpty)
    }

    @Test("Seeding twice is idempotent")
    func reseeding() async throws {
        let service = try await seededService()
        let before = await service.snapshot
        try await scenario.seed(into: service)
        #expect(await service.snapshot == before)
    }
}
