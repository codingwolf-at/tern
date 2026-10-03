import Foundation
import Testing
@testable import Tern

@Suite("Mock scenario")
struct MockScenarioTests {
    let scenario = MockScenario(now: Date(timeIntervalSince1970: 1_800_000_000))
    let engine = AttentionEngine()

    @Test("Avatar migration ends with the reviewer's response back with me")
    func avatarMigration() {
        var workstream = scenario.avatarMigrationShell
        workstream.events = scenario.avatarMigrationScript
        workstream = engine.rebuild(workstream)

        #expect(workstream.nextOwner == .me)
        #expect(workstream.attention == .high)
        #expect(workstream.status.headline == "Reviewer responded")
        #expect(workstream.primaryLabel == "PR #421")
        #expect(workstream.calendarContext?.title == "Avatar rollout sync")
        #expect(workstream.agentSessions.first?.agentName == "Claude Code")
    }

    @Test("Supporting workstreams land in the expected hands")
    func supportingWorkstreams() {
        let owners = Dictionary(uniqueKeysWithValues: scenario.otherWorkstreams.map {
            ($0.id.rawValue, engine.rebuild($0).nextOwner)
        })
        #expect(owners == [
            "settings-cleanup": .me,
            "rate-limiter": .reviewer,
            "search-indexing": .agent,
            "webhook-retries": .ci,
            "billing-export": .none,
        ])
    }
}
