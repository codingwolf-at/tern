import Foundation

/// What a macOS notification shows, built from a transition the notification policy has already
/// decided to surface. Carries only what the notification itself needs: never status details
/// (which can quote an agent's prompt), descriptions, notes, attendees or links. Not persisted.
struct NotificationPayload: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable {
        case workstream
        /// A meeting whose event carries a call link: the notification offers Join.
        case joinableMeeting
        case meeting
    }

    /// Deterministic: the subject plus its transition fingerprint. The same logical notification
    /// always has the same identifier; different subjects never share one.
    let id: String
    let subjectID: SubjectID
    let context: SubjectContext
    let kind: Kind
    /// What happened: "Changes requested", "Design review starts in 15 min".
    let title: String
    /// Which piece of work: "PR #421 · Avatar migration". Empty for meetings.
    let subtitle: String
    /// What to do: "Address requested changes", "Join meeting".
    let body: String

    static func identifier(subject: SubjectID, fingerprint: String) -> String {
        "tern|\(subject.rawValue)|\(fingerprint)"
    }
}

/// Wording only. Whether to notify is decided before this is called (see `PersistedState.surface`).
enum NotificationContent {
    static let titleLimit = 60

    static func payload(for workstream: Workstream, record: NotificationRecord, context: SubjectContext) -> NotificationPayload {
        let label = workstream.primaryLabel
        let subtitle = label == workstream.title ? truncated(label) : "\(label) · \(truncated(workstream.title))"
        return NotificationPayload(
            id: NotificationPayload.identifier(subject: record.subjectID, fingerprint: record.fingerprint),
            subjectID: record.subjectID,
            context: context,
            kind: .workstream,
            title: workstream.status.headline,
            subtitle: subtitle,
            body: workstream.nextAction?.title ?? "Your turn"
        )
    }

    static func payload(for status: MeetingStatus, record: NotificationRecord, at now: Date) -> NotificationPayload {
        let minutes = Int((status.meeting.startsAt.timeIntervalSince(now) / 60).rounded(.up))
        let when = minutes <= 1 ? "starts now" : "starts in \(minutes) min"
        return NotificationPayload(
            id: NotificationPayload.identifier(subject: record.subjectID, fingerprint: record.fingerprint),
            subjectID: record.subjectID,
            context: status.context,
            kind: status.meeting.joinURL == nil ? .meeting : .joinableMeeting,
            title: "\(truncated(status.meeting.title)) \(when)",
            subtitle: "",
            body: status.decision.nextAction?.title ?? "Meeting starts soon"
        )
    }

    static func truncated(_ text: String) -> String {
        text.count <= titleLimit ? text : String(text.prefix(titleLimit - 1)) + "…"
    }
}
