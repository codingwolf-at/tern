import Foundation
import Testing
@testable import Tern

@Suite("Attention engine")
struct AttentionEngineTests {
    let engine = AttentionEngine()

    private func decide(_ fixture: EventFixture) -> AttentionDecision {
        engine.evaluate(fixture.events).decision
    }

    @Test("Agent working stays silent and with the agent")
    func agentWorking() {
        var fixture = EventFixture()
        fixture.add(.planeItemCreated, from: .plane)
        fixture.add(.agentStarted, from: .agent, EventFixture.claude)

        let decision = decide(fixture)
        #expect(decision.nextOwner == .agent)
        #expect(decision.attention == .silent)
        #expect(decision.state == .active)
        #expect(decision.shouldNotify == false)
        #expect(decision.nextAction == nil)
    }

    @Test("Agent completing hands the turn back to me")
    func agentCompleted() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude)
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude)

        let decision = decide(fixture)
        #expect(decision.nextOwner == .me)
        #expect(decision.attention == .medium)
        #expect(decision.state == .needsAttention)
        #expect(decision.shouldNotify)
        #expect(decision.nextAction?.title == "Review Claude's changes")
    }

    @Test("Reviewer requesting changes is high attention for me")
    func changesRequested() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya", .commentCount: "3"])

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.decision.attention == .high)
        #expect(evaluation.decision.shouldNotify)
        #expect(evaluation.decision.nextAction?.reason == "Priya requested changes")
        #expect(evaluation.status.detail == "3 new comments")
    }

    @Test("Waiting for a reviewer is silent")
    func waitingForReviewer() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Sarah"])

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .reviewer)
        #expect(evaluation.decision.attention == .silent)
        #expect(evaluation.decision.state == .waiting)
        #expect(evaluation.decision.shouldNotify == false)
        #expect(evaluation.status.headline == "Waiting for Sarah")
    }

    @Test("CI running is silent and owned by CI")
    func ciRunning() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.ciStarted, from: .github)

        let decision = decide(fixture)
        #expect(decision.nextOwner == .ci)
        #expect(decision.attention == .silent)
        #expect(decision.state == .waiting)
    }

    @Test("CI failure is high attention for me")
    func ciFailed() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.ciStarted, from: .github)
        fixture.add(.ciFailed, from: .github, [.checkName: "lint"])

        let decision = decide(fixture)
        #expect(decision.nextOwner == .me)
        #expect(decision.attention == .high)
        #expect(decision.state == .needsAttention)
        #expect(decision.shouldNotify)
        #expect(decision.nextAction?.reason == "lint failed")
    }

    @Test("Completed work is silent and owned by nobody, even with stale feedback")
    func completedWork() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.ciFailed, from: .github)
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.pullRequestMerged, from: .github)

        let decision = decide(fixture)
        #expect(decision.state == .complete)
        #expect(decision.nextOwner == .none)
        #expect(decision.attention == .silent)
        #expect(decision.shouldNotify == false)
        #expect(decision.nextAction == nil)
    }

    @Test("An agent picking up review feedback takes the turn and goes quiet")
    func agentHandlesFeedback() {
        var fixture = EventFixture()
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.agentStarted, from: .agent, EventFixture.claude)

        #expect(decide(fixture).nextOwner == .agent)
        #expect(decide(fixture).attention == .silent)

        // When the agent finishes, the turn is mine at medium — not the older, handled feedback.
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude)
        #expect(decide(fixture).nextOwner == .me)
        #expect(decide(fixture).attention == .medium)
    }

    @Test("Unrelated updates while it's already my turn do not re-notify")
    func quietWhileAlreadyMine() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude)
        let finished = fixture.add(.agentCompleted, from: .agent, EventFixture.claude)
        fixture.add(.ciPassed, from: .github)

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.decision.shouldNotify == false)
        #expect(evaluation.lastMeaningfulChange == finished.timestamp)
    }

    @Test("Feedback arriving after the agent finished escalates to high")
    func feedbackEscalates() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude)
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude)
        fixture.add(.reviewerResponded, from: .github, [.reviewer: "Priya", .commentCount: "2"])

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.attention == .high)
        #expect(evaluation.decision.shouldNotify)
        #expect(evaluation.status.headline == "Reviewer responded")
        #expect(evaluation.status.detail == "2 new comments")
    }

    @Test("Unknown event kinds are ignored")
    func unknownKindsIgnored() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Sarah"])
        let before = engine.evaluate(fixture.events).decision

        fixture.add(WorkEventKind(rawValue: "github.label.added"), from: .github)
        #expect(engine.evaluate(fixture.events).decision.nextOwner == before.nextOwner)
        #expect(engine.evaluate(fixture.events).decision.attention == before.attention)
    }

    @Test("Blocked work is owned externally and stays quiet")
    func blocked() {
        var fixture = EventFixture()
        fixture.add(.planeItemCreated, from: .plane)
        fixture.add(.planeItemBlocked, from: .plane, [.reason: "Waiting on design"])

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.state == .blocked)
        #expect(evaluation.decision.nextOwner == .external)
        #expect(evaluation.decision.attention == .silent)
        #expect(evaluation.status.detail == "Waiting on design")
    }
}
