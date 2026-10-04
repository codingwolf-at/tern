import Foundation
import Testing
@testable import Tern

@Suite("App model")
@MainActor
struct AppModelTests {
    @Test("The UI model reflects events ingested by the service, without ingesting itself")
    func mirrorsService() async throws {
        let service = try await makeService()
        let model = AppModel(service: service)

        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude())
        try await service.ingest(fixture.observed)

        try await waitUntil { model.needsYou.count == 1 }
        #expect(model.needsYou.first?.workstream?.status.headline == "Claude finished")
        #expect(model.waiting.isEmpty)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition())
    }
}
