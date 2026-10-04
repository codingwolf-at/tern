import Foundation
import Testing
@testable import Tern

@Suite("Notifications")
struct NotificationTests {
    @Test("Importing history is silent, even when it ends on my turn")
    func historyImportIsSilent() async throws {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.ciFailed, from: .github)
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])

        let service = try await makeService()
        let report = try await service.ingest(fixture.observed, mode: .historyImport)
        let workstream = try #require(await service.workstream())

        #expect(report.notifications.isEmpty)
        #expect(workstream.nextOwner == .me)
        #expect(workstream.attention == .high)
        #expect(workstream.evaluation.decision.shouldNotify == false)
    }

    @Test("A new attention transition arriving live notifies")
    func newTransitionNotifies() async throws {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Priya"])
        let service = try await makeService()
        try await service.ingest(fixture.observed, mode: .historyImport)

        let feedback = fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        let report = try await service.ingest([feedback])

        #expect(report.notifications.count == 1)
        #expect(report.notifications.first?.attention == .high)
        #expect(await service.workstream()?.evaluation.decision.shouldNotify == true)
        #expect(await service.snapshot.notifications.count == 1)
    }

    @Test("A duplicate of an event that already notified does not notify again")
    func duplicateDoesNotNotify() async throws {
        var fixture = EventFixture()
        let finished = [
            fixture.add(.agentStarted, from: .agent, EventFixture.claude()),
            fixture.add(.agentCompleted, from: .agent, EventFixture.claude()),
        ]
        let service = try await makeService()
        #expect(try await service.ingest(finished).notifications.count == 1)

        let report = try await service.ingest([finished[1]])
        #expect(report.notifications.isEmpty)
        #expect(await service.snapshot.notifications.count == 1)
    }

    @Test("A relaunch rebuilds state without repeating transitions already shown")
    func relaunchDoesNotRenotify() async throws {
        let store = InMemoryTernStore()
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])

        let firstLaunch = try await makeService(store: store)
        #expect(try await firstLaunch.ingest(fixture.observed).notifications.count == 1)

        // Same store, fresh process.
        let relaunch = IngestionService(store: store, now: { EventFixture.origin }, scoping: .ignoringContexts)
        try await relaunch.start()
        let rebuilt = try #require(await relaunch.workstream())
        #expect(rebuilt.attention == .high)
        #expect(rebuilt.evaluation.decision.shouldNotify == false)

        // A poll re-delivers old events plus one that doesn't change the decision.
        let unrelated = fixture.add(.ciPassed, from: .github)
        let report = try await relaunch.ingest(fixture.observed)
        #expect(report.accepted == [unrelated.id])
        #expect(report.notifications.isEmpty)
        #expect(await relaunch.snapshot.notifications.count == 1)
    }

    @Test("A late event notifies for the transition it causes, not for the chronologically last event")
    func lateEventDrivesTransition() async throws {
        let t = EventFixture.origin
        func at(_ minute: Double) -> Date { t.addingTimeInterval(minute * 60) }
        let started = EventFixture.event(.agentStarted, from: .agent, id: "start", at: at(1), EventFixture.claude())
        let finished = EventFixture.event(.agentCompleted, from: .agent, id: "stop", at: at(5), EventFixture.claude())
        let lateFailure = EventFixture.event(.ciFailed, from: .github, id: "ci", at: at(3), [.checkName: "lint"])

        let service = try await makeService()
        #expect(try await service.ingest([started, finished]).notifications.count == 1)

        // Arrives after, but happened before the agent finished. The latest event in the
        // history is still `finished`; the new transition is the CI failure.
        let report = try await service.ingest([lateFailure])
        let notification = try #require(report.notifications.first)
        #expect(notification.attention == .high)
        #expect(notification.headline == "CI failed")
        #expect(await service.workstream()?.evaluation.transition.causeID == lateFailure.id)
    }

    @Test("A late event that is already superseded stays quiet")
    func supersededLateEventIsQuiet() async throws {
        let t = EventFixture.origin
        func at(_ minute: Double) -> Date { t.addingTimeInterval(minute * 60) }
        let feedback = EventFixture.event(.changesRequested, from: .github, id: "review", at: at(2), [.reviewer: "Priya"])
        let agent = EventFixture.event(.agentStarted, from: .agent, id: "start", at: at(4), EventFixture.claude())
        let lateCI = EventFixture.event(.ciFailed, from: .github, id: "ci", at: at(3))

        let service = try await makeService()
        try await service.ingest([feedback, agent])
        let report = try await service.ingest([lateCI])

        #expect(report.notifications.isEmpty)
        #expect(await service.workstream()?.nextOwner == .agent)
    }

    @Test("New feedback while it's already my turn notifies; getting quieter does not")
    func sameTurnRules() async throws {
        var fixture = EventFixture()
        let service = try await makeService()
        try await service.ingest([
            fixture.add(.agentStarted, from: .agent, EventFixture.claude()),
            fixture.add(.agentCompleted, from: .agent, EventFixture.claude()),
            fixture.add(.ciFailed, from: .github),
        ])

        // CI recovers: the older "agent finished" claim resurfaces at lower attention.
        let quieter = try await service.ingest([fixture.add(.ciPassed, from: .github)])
        #expect(quieter.notifications.isEmpty)
        #expect(await service.workstream()?.attention == .medium)

        // A reviewer responds: newer cause, louder.
        let responded = try await service.ingest([fixture.add(.reviewerResponded, from: .github, [.reviewer: "Priya"])])
        #expect(responded.notifications.count == 1)

        // They respond again: same loudness, but newer cause.
        let again = try await service.ingest([fixture.add(.reviewerResponded, from: .github, [.reviewer: "Priya"])])
        #expect(again.notifications.count == 1)
    }

    @Test("Silent waiting never notifies")
    func waitingIsSilent() async throws {
        var fixture = EventFixture()
        let service = try await makeService()
        let report = try await service.ingest([
            fixture.add(.pullRequestOpened, from: .github),
            fixture.add(.reviewRequested, from: .github, [.reviewer: "Sarah"]),
            fixture.add(.ciStarted, from: .github),
        ])
        #expect(report.notifications.isEmpty)
    }
}
