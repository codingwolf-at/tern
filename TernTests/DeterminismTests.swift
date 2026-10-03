import Foundation
import Testing
@testable import Tern

@Suite("Determinism")
struct DeterminismTests {
    let engine = AttentionEngine()

    private var history: [WorkEvent] {
        observedHistory.map { $0.linked(to: EventFixture.workstreamID) }
    }

    private var observedHistory: [ObservedEvent] {
        var fixture = EventFixture()
        fixture.add(.planeItemCreated, from: .plane)
        fixture.add(.pullRequestOpened, from: .github)
        fixture.add(.reviewRequested, from: .github, [.reviewer: "Priya"])
        fixture.add(.changesRequested, from: .github, [.reviewer: "Priya", .commentCount: "3"])
        fixture.add(.agentStarted, from: .agent, EventFixture.claude())
        fixture.add(.agentCompleted, from: .agent, EventFixture.claude())
        fixture.add(.ciStarted, from: .github)
        fixture.add(.ciPassed, from: .github)
        fixture.add(.reviewerResponded, from: .github, [.reviewer: "Priya", .commentCount: "2"])
        return fixture.observed
    }

    @Test("Ownership follows the expected sequence of transitions")
    func ownershipTransitions() {
        let events = history
        let owners = (1...events.count).map { engine.evaluate(Array(events.prefix($0))).decision.nextOwner }
        #expect(owners == [.me, .me, .reviewer, .me, .agent, .me, .me, .me, .me])

        let attention = (1...events.count).map { engine.evaluate(Array(events.prefix($0))).decision.attention }
        #expect(attention == [.low, .low, .silent, .high, .silent, .medium, .medium, .medium, .high])
    }

    @Test("Evaluating the same history twice gives the same result")
    func repeatable() {
        let events = history
        #expect(engine.evaluate(events) == engine.evaluate(events))
    }

    @Test("Result does not depend on the order events are supplied in", arguments: 0..<10)
    func orderIndependent(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let events = history
        #expect(engine.evaluate(events.shuffled(using: &generator)) == engine.evaluate(events))
    }

    @Test("Ingesting events one by one matches ingesting them as one batch")
    func incrementalMatchesBatch() async throws {
        let observed = observedHistory
        let oneByOne = try await makeService()
        for event in observed {
            try await oneByOne.ingest([event])
        }
        let batched = try await makeService()
        try await batched.ingest(observed)

        let lhs = try #require(await oneByOne.workstream())
        let rhs = try #require(await batched.workstream())
        #expect(lhs.evaluation.transition == rhs.evaluation.transition)
        #expect(lhs.evaluation.decision.with(shouldNotify: false) == rhs.evaluation.decision.with(shouldNotify: false))
        #expect(lhs.evaluation.with(shouldNotify: false) == engine.evaluate(history))
        #expect(lhs.agentSessions.map(\.status) == [.completed])
    }

    @Test("The same history always produces the same transition fingerprint")
    func stableFingerprint() {
        #expect(engine.evaluate(history).transition.fingerprint == engine.evaluate(history.reversed()).transition.fingerprint)
    }
}

private extension WorkstreamEvaluation {
    func with(shouldNotify: Bool) -> WorkstreamEvaluation {
        var copy = self
        copy.decision = decision.with(shouldNotify: shouldNotify)
        return copy
    }
}

/// Small deterministic PRNG (SplitMix64) so shuffles are reproducible.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
