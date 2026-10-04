/// Decides whether a newly evaluated transition deserves the user's attention,
/// given the transition they were last shown for that workstream.
///
/// Quiet by default. Notify only when the turn is mine at medium attention or above and
/// it is genuinely new: the turn came back to me, it got louder, or a newer event caused it.
/// A transition with the same fingerprint as the last one shown is never repeated, and ingestion
/// also suppresses any transition shown earlier for the workstream (see `ShownTransition.seen`).
enum NotificationPolicy {
    static func shouldNotify(_ transition: AttentionTransition, lastShown: AttentionTransition?) -> Bool {
        guard transition.owner == .me, transition.attention >= .medium else { return false }
        guard let lastShown else { return true }
        guard transition.fingerprint != lastShown.fingerprint else { return false }
        if lastShown.owner != .me { return true }
        if transition.attention > lastShown.attention { return true }
        if let causeAt = transition.causeAt, let shownAt = lastShown.causeAt, causeAt > shownAt { return true }
        return false
    }
}
