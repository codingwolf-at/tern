/// Coarse lifecycle state of a workstream, derived from its events.
enum WorkstreamState: String, Hashable, Sendable, Codable, CaseIterable {
    /// Someone (me or an agent) is actively moving it forward.
    case active
    /// Handed off; waiting on a reviewer, CI, or similar.
    case waiting
    /// Cannot progress until something external changes.
    case blocked
    /// The next action is mine.
    case needsAttention
    /// Merged, closed, or otherwise done.
    case complete
}
