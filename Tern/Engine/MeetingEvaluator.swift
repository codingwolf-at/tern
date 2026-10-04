import Foundation

/// When a meeting starts to matter. The numbers live here, not in the evaluator.
struct MeetingPolicy: Hashable, Sendable {
    /// How long before the start a meeting may claim attention.
    var preparationWindow: TimeInterval = 15 * 60
    /// Inside this, the wording changes to "starting now". Attention stays the same.
    var startingSoonWindow: TimeInterval = 2 * 60
    /// How far ahead Calendar is read for "Up next".
    var lookahead: TimeInterval = 12 * 60 * 60

    static let standard = MeetingPolicy()
}

/// Pure, deterministic evaluation of one meeting at one moment:
///
///     Meeting + now → phase → AttentionDecision + AttentionTransition
///
/// It produces the same decision and transition types workstreams do, so the existing
/// `NotificationPolicy` and shown-transition bookkeeping decide whether it is news. It never
/// notifies on its own.
enum MeetingEvaluator {
    static func phase(of meeting: Meeting, at now: Date, policy: MeetingPolicy = .standard) -> MeetingPhase {
        if now >= meeting.endsAt { return .ended }
        if now >= meeting.startsAt { return .inProgress }
        let remaining = meeting.startsAt.timeIntervalSince(now)
        if remaining <= policy.startingSoonWindow { return .startingSoon }
        if remaining <= policy.preparationWindow { return .preparing }
        return .upcoming
    }

    /// Whether a meeting can claim attention at all, whatever the time. All-day events and
    /// meetings the user declined never do.
    static func canClaimAttention(_ meeting: Meeting) -> Bool {
        !meeting.isAllDay && meeting.participation != .declined
    }

    static func evaluate(_ meeting: Meeting, context: SubjectContext, at now: Date, policy: MeetingPolicy = .standard) -> MeetingStatus {
        let phase = phase(of: meeting, at: now, policy: policy)
        let claims = canClaimAttention(meeting) && (phase == .preparing || phase == .startingSoon)

        let decision: AttentionDecision
        let transition: AttentionTransition
        if claims {
            // One transition per occurrence: entering the window. "Starting soon" is the same
            // transition, so it never notifies twice.
            let action = meeting.joinURL != nil
                ? NextAction(title: "Join meeting", reason: "Meeting starts soon")
                : NextAction(title: "Prepare for meeting", reason: "Meeting starts soon")
            decision = AttentionDecision(shouldNotify: false, state: .needsAttention, nextOwner: .me, attention: .medium,
                                         nextAction: action, reason: .meetingSoon)
            transition = AttentionTransition(state: .needsAttention, owner: .me, attention: .medium,
                                             causeID: EventID(.calendar, "meeting", meeting.id, "prepare"),
                                             causeAt: meeting.startsAt.addingTimeInterval(-policy.preparationWindow))
        } else {
            let state: WorkstreamState = switch phase {
            case .upcoming, .preparing, .startingSoon: .waiting
            case .inProgress: .active
            case .ended: .complete
            }
            decision = AttentionDecision(shouldNotify: false, state: state, nextOwner: .none, attention: .silent, nextAction: nil)
            transition = AttentionTransition(state: state, owner: .none, attention: .silent, causeID: nil, causeAt: nil)
        }
        return MeetingStatus(meeting: meeting, context: context, phase: phase,
                             attentionStartsAt: meeting.startsAt.addingTimeInterval(-policy.preparationWindow),
                             decision: decision, transition: transition)
    }
}
