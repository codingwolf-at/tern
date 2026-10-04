import Testing
@testable import Tern

@Suite("Brand theme")
struct ThemeTests {
    @Test("Only the user's own move is drawn as their turn")
    func toneFollowsOwnership() {
        for level in AttentionLevel.allCases {
            #expect(AttentionTone.of(level: level, reason: .changesRequested, mine: false) == .quiet)
        }
        #expect(AttentionTone.of(level: .silent, reason: nil, mine: true) == .quiet)
        #expect(AttentionTone.of(level: .low, reason: .draft, mine: true) == .yourTurn)
        #expect(AttentionTone.of(level: .medium, reason: .approvedReadyToMerge, mine: true) == .yourTurn)
        #expect(AttentionTone.of(level: .high, reason: .changesRequested, mine: true) == .yourTurn)
        #expect(AttentionTone.of(level: .medium, reason: .meetingSoon, mine: true) == .yourTurn)
    }

    @Test("Failures are critical, never coral")
    func problemsAreCritical() {
        #expect(AttentionTone.of(level: .high, reason: .ciFailed, mine: true) == .critical)
        #expect(AttentionTone.of(level: .high, reason: .agentFailed, mine: true) == .critical)
        #expect(AttentionTone.of(level: .urgent, reason: nil, mine: true) == .critical)
        #expect(AttentionReason.ciFailed.isProblem)
        #expect(AttentionReason.agentFailed.isProblem)
        #expect(!AttentionReason.changesRequested.isProblem)
        #expect(!AttentionReason.agentNeedsInput.isProblem)
        #expect(!AttentionReason.meetingSoon.isProblem)
    }

    @Test("The ball is the user's; every other owner gets a ring; nobody gets nothing")
    func ownershipMark() {
        #expect(OwnershipMark(.me) == .ball)
        for owner in [Owner.agent, .reviewer, .ci, .external] {
            #expect(OwnershipMark(owner) == .ring)
        }
        #expect(OwnershipMark(.none) == .none)
    }
}
