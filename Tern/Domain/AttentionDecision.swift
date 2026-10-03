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
struct AttentionDecision: Hashable, Sendable, Codable {
    let shouldNotify: Bool
    let state: WorkstreamState
    let nextOwner: Owner
    let attention: AttentionLevel
    let nextAction: NextAction?

    /// Decision for a workstream with no history yet.
    static let initial = AttentionDecision(
        shouldNotify: false,
        state: .active,
        nextOwner: .none,
        attention: .silent,
        nextAction: nil
    )

    /// Whether two decisions differ in a way the user would care about (ignores `shouldNotify`).
    func isMeaningfullyDifferent(from other: AttentionDecision) -> Bool {
        state != other.state
            || nextOwner != other.nextOwner
            || attention != other.attention
            || nextAction?.title != other.nextAction?.title
    }
}
