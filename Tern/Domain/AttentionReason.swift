/// Why a workstream is surfaced. Every claim on the user names one, so an attention decision
/// can always be explained. Open to new cases as integrations add situations.
enum AttentionReason: String, Hashable, Sendable, Codable {
    // Interruptions: something happened that needs the user.
    case reviewRequested
    case changesRequested
    case reviewerResponded
    case agentNeedsInput
    case agentCompleted
    case agentFailed
    case ciFailed
    case approvedReadyToMerge
    case workReopened

    // Your move, but not worth an interruption.
    case changesPushed
    case approvalOutdated
    case draft
    case needsReviewer
    case readyToStart

    // Calendar: a meeting is about to start. Its own signal; never raises a workstream.
    case meetingSoon

    // Reserved for future signals.
    case stale
    case deadline
}
