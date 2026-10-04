/// How strongly a subject deserves the user's attention. Ordered from quietest to loudest.
enum AttentionLevel: Int, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case silent
    case low
    case medium
    case high
    case urgent

    static func < (lhs: AttentionLevel, rhs: AttentionLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
