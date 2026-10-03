import Foundation

/// Stable identity of "where a workstream's attention stands", including which event caused it.
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

/// A transition that was surfaced as a notification.
struct NotificationRecord: Hashable, Sendable, Codable {
    let workstreamID: WorkstreamID
    let fingerprint: String
    let headline: String
    let attention: AttentionLevel
    let createdAt: Date
}
