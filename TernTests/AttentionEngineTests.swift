import Foundation
import Testing
@testable import Tern

@Suite("Attention engine")
struct AttentionEngineTests {
    let engine = AttentionEngine()

    private func decide(_ fixture: EventFixture) -> AttentionDecision {
        engine.evaluate(fixture.events).decision
    }

    /// Whether the last event, arriving live after everything before it was shown, notifies.
    private func notifiesOnLastEvent(_ fixture: EventFixture) -> Bool {
        let events = fixture.events
        let before = engine.evaluate(Array(events.dropLast())).transition
        let after = engine.evaluate(events).transition
        return NotificationPolicy.shouldNotify(after, lastShown: before)
    }

    @Test("Agent working stays silent and with the agent")
    func agentWorking() {
        var fixture = EventFixture()
        fixture.add(.planeItemCreated, from: .plane)
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())

        let decision = decide(fixture)
        #expect(decision.nextOwner == .agent)
        #expect(decision.attention == .silent)
        #expect(decision.state == .active)
        #expect(notifiesOnLastEvent(fixture) == false)
        #expect(decision.nextAction == nil)
    }

    @Test("Agent completing hands the turn back to me")
    func agentCompleted() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude())

        let decision = decide(fixture)
        #expect(decision.nextOwner == .me)
        #expect(decision.attention == .medium)
        #expect(decision.state == .needsAttention)
        #expect(notifiesOnLastEvent(fixture))
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
        #expect(notifiesOnLastEvent(fixture))
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
        #expect(notifiesOnLastEvent(fixture) == false)
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
        #expect(notifiesOnLastEvent(fixture))
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
        #expect(notifiesOnLastEvent(fixture) == false)
        #expect(decision.nextAction == nil)
    }

    @Test("An agent picking up review feedback takes the turn and goes quiet")
    func agentHandlesFeedback() {
        var fixture = EventFixture()
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())

        #expect(decide(fixture).nextOwner == .agent)
        #expect(decide(fixture).attention == .silent)

        // When the agent finishes, the turn is mine at medium — not the older, handled feedback.
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude())
        #expect(decide(fixture).nextOwner == .me)
        #expect(decide(fixture).attention == .medium)
    }

    @Test("Unrelated updates while it's already my turn do not re-notify")
    func quietWhileAlreadyMine() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        let finished = fixture.add(.agentCompleted, from: .agent, EventFixture.claude())
        fixture.add(.ciPassed, from: .github)

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(notifiesOnLastEvent(fixture) == false)
        #expect(evaluation.lastMeaningfulChange == finished.timestamp)
        #expect(evaluation.transition.causeID == finished.id)
    }

    @Test("Feedback arriving after the agent finished escalates to high")
    func feedbackEscalates() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude())
        fixture.add(.reviewerResponded, from: .github, [.reviewer: "Priya", .commentCount: "2"])

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.attention == .high)
        #expect(notifiesOnLastEvent(fixture))
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

    @Test("A failed agent run does not consume review feedback")
    func failedAgentKeepsFeedback() {
        var fixture = EventFixture()
        fixture.add(.pullRequestOpened, from: .github)
        let feedback = fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        #expect(decide(fixture).nextOwner == .agent)

        fixture.add(.agentFailed, from: .agent, EventFixture.claude())
        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.decision.attention == .high)
        #expect(evaluation.decision.nextAction?.title == "Address requested changes")
        #expect(evaluation.transition.causeID == feedback.id)
    }

    @Test("Agent needing input is high attention for me")
    func agentNeedsInput() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentNeedsInput, from: .agent, EventFixture.claude().merging([.prompt: "Allow running migrations?"]) { $1 })

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.decision.attention == .high)
        #expect(evaluation.decision.state == .needsAttention)
        #expect(evaluation.status.headline == "Claude needs input")
        #expect(evaluation.status.detail == "Allow running migrations?")
        #expect(notifiesOnLastEvent(fixture))

        // Answering resumes the same run; the turn goes back to the agent.
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        #expect(decide(fixture).nextOwner == .agent)
        #expect(decide(fixture).attention == .silent)
    }

    @Test("Resuming a run after input keeps it from counting as a new run")
    func resumeKeepsRunStart() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentNeedsInput, from: .agent, EventFixture.claude())
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())

        // The run began before the feedback, so it has not addressed it.
        #expect(decide(fixture).nextOwner == .me)
        #expect(decide(fixture).attention == .high)
    }

    @Test("Agent sessions are tracked independently")
    func multipleSessions() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude("a"))
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude("a"))
        fixture.add(.agentStarted, from: .agent, EventFixture.claude("b"))

        // A's finished work is still mine even though B has started.
        var evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.decision.attention == .medium)

        // B failing doesn't erase A, and A finishing doesn't hide B's failure.
        fixture.add(.agentFailed, from: .agent, EventFixture.claude("b"))
        evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .me)
        #expect(evaluation.status.headline == "Claude stopped")

        var workstream = Workstream(id: EventFixture.workstreamID, title: "Test", events: fixture.events)
        workstream = engine.rebuild(workstream)
        #expect(workstream.agentSessions.map(\.id) == ["a", "b"])
        #expect(workstream.agentSessions.map(\.status) == [.completed, .failed])
    }

    @Test("Two sessions working at once are both owned by the agent")
    func concurrentSessions() {
        var fixture = EventFixture()
        fixture.add(.agentStarted, from: .agent, EventFixture.claude("a"))
        fixture.add(.agentStarted, from: .agent, EventFixture.claude("b"))

        let evaluation = engine.evaluate(fixture.events)
        #expect(evaluation.decision.nextOwner == .agent)
        #expect(evaluation.status.headline == "2 agents working")
    }
}
