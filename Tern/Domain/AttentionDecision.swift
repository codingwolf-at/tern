/// The concrete next step the current owner should take.
struct NextAction: Hashable, Sendable, Codable {
    let title: String
    let reason: String
    let estimatedMinutes: Int?

    init(title: String, reason: String, estimatedMinutes: Int? = nil) {
        self.title = title
        self.reason = reason
        self.estimatedMinutes = estimatedMinutes
    }
}

/// Deterministic result of evaluating a workstream.
///
/// `shouldNotify` is not derived from the event history: it is set by ingestion when newly
/// observed data produces a transition the user has not been shown yet.
struct AttentionDecision: Hashable, Sendable, Codable {
    let shouldNotify: Bool
    let state: WorkstreamState
    let nextOwner: Owner
    let attention: AttentionLevel
    let nextAction: NextAction?
    /// Why it's the user's move, when it is.
    let reason: AttentionReason?

    init(shouldNotify: Bool, state: WorkstreamState, nextOwner: Owner, attention: AttentionLevel, nextAction: NextAction?, reason: AttentionReason? = nil) {
        self.shouldNotify = shouldNotify
        self.state = state
        self.nextOwner = nextOwner
        self.attention = attention
        self.nextAction = nextAction
        self.reason = reason
    }

    /// Decision for a workstream with no history yet.
    static let initial = AttentionDecision(
        shouldNotify: false,
        state: .active,
        nextOwner: .none,
        attention: .silent,
        nextAction: nil
    )

    func with(shouldNotify: Bool) -> AttentionDecision {
        AttentionDecision(shouldNotify: shouldNotify, state: state, nextOwner: nextOwner, attention: attention, nextAction: nextAction, reason: reason)
    }

    /// Whether two decisions differ in a way the user would care about (ignores `shouldNotify`).
    func isMeaningfullyDifferent(from other: AttentionDecision) -> Bool {
        state != other.state
            || nextOwner != other.nextOwner
            || attention != other.attention
            || nextAction?.title != other.nextAction?.title
    }
}
