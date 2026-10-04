import Foundation

/// Describes where an already-resolved attention item's next move happens. Pure and
/// deterministic; it never decides whether something needs attention, who owns it or how it
/// ranks — only which known destination, if any, matches the next action.
///
/// | Item | Primary | Secondary |
/// |------|---------|-----------|
/// | Workstream, your move, status about GitHub | Open PR | Open in Plane, when linked |
/// | Workstream, your move, status about Plane | Open in Plane | Open PR, when linked |
/// | Workstream, your move, status about an agent | none: the answer happens in the agent's own session | none |
/// | Workstream someone else owns (reviewer, CI, the merging lead, an agent at work) | none | none |
/// | Meeting with a call link the event carries | Join meeting | none |
/// | Meeting without one | none ("Prepare for meeting" stays text) | none |
enum ActionResolver {
    static func actions(for item: AttentionItem, context: SubjectContext) -> ItemActions {
        switch item {
        case .workstream(let workstream): actions(for: workstream, context: context)
        case .meeting(let meeting): actions(for: meeting)
        }
    }

    static func actions(for workstream: Workstream, context: SubjectContext) -> ItemActions {
        guard workstream.nextOwner == .me, workstream.state != .complete else { return .none }
        let subject = workstream.subjectID
        let pullRequest = workstream.pullRequest?.url.map {
            ActionTarget(kind: .openPullRequest, url: $0, subjectID: subject, context: context)
        }
        let plane = workstream.planeItem?.url.map {
            ActionTarget(kind: .openPlaneItem, url: $0, subjectID: subject, context: context)
        }
        switch workstream.status.focus {
        case .agent:
            // Answering an agent happens in its terminal or editor, which Tern can't open reliably.
            return .none
        case .plane:
            return ItemActions(primary: plane ?? pullRequest, secondary: plane == nil ? nil : pullRequest)
        case .github, .calendar, nil:
            return ItemActions(primary: pullRequest ?? plane, secondary: pullRequest == nil ? nil : plane)
        }
    }

    static func actions(for status: MeetingStatus) -> ItemActions {
        guard let url = status.meeting.joinURL, status.phase != .ended,
              MeetingEvaluator.canClaimAttention(status.meeting) else { return .none }
        return ItemActions(primary: ActionTarget(kind: .joinMeeting, url: url, subjectID: status.meeting.subjectID, context: status.context))
    }
}
