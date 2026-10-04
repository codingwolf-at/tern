import Foundation

/// Stable identity of "where a subject's attention stands", including what caused it.
/// Rebuilding the same history always yields the same transition, so it can be compared
/// against what the user was last shown to tell new transitions from replays.
struct AttentionTransition: Hashable, Sendable, Codable {
    let state: WorkstreamState
    let owner: Owner
    let attention: AttentionLevel
    /// Event that produced the current decision, if any.
    let causeID: EventID?
    let causeAt: Date?

    var fingerprint: String {
        "\(state.rawValue)|\(owner.rawValue)|\(attention.rawValue)|\(causeID?.rawValue ?? "-")"
    }

    static let initial = AttentionTransition(state: .active, owner: .none, attention: .silent, causeID: nil, causeAt: nil)
}

/// A transition that was surfaced as a notification, for any attention subject.
struct NotificationRecord: Hashable, Sendable, Codable {
    let subjectID: SubjectID
    let fingerprint: String
    let headline: String
    let attention: AttentionLevel
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case subjectID, fingerprint, headline, attention, createdAt
    }

    init(subjectID: SubjectID, fingerprint: String, headline: String, attention: AttentionLevel, createdAt: Date) {
        self.subjectID = subjectID
        self.fingerprint = fingerprint
        self.headline = headline
        self.attention = attention
        self.createdAt = createdAt
    }

    /// Reads records saved before subjects existed, keyed `workstreamID`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        subjectID = try SubjectID.decode(from: decoder, container, key: .subjectID)
        fingerprint = try container.decode(String.self, forKey: .fingerprint)
        headline = try container.decode(String.self, forKey: .headline)
        attention = try container.decode(AttentionLevel.self, forKey: .attention)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }
}
