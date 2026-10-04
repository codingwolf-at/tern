import Foundation

/// A macOS calendar, as much of it as Tern needs to let the user classify it.
struct CalendarInfo: Identifiable, Hashable, Sendable {
    /// EventKit's `calendarIdentifier`; stable for the calendar on this Mac.
    let id: String
    let title: String
    /// The account it belongs to, e.g. "iCloud" or a work Exchange account.
    let account: String?
}

/// One occurrence of a calendar event, read from the user's calendars.
///
/// Held in memory only and re-read from Calendar on every refresh: nothing here is persisted.
/// Deliberately small — no notes, attendee list or description, only what deciding "do I need
/// to prepare for something soon?" requires.
struct Meeting: Identifiable, Hashable, Sendable {
    /// How the user takes part, when the calendar says.
    enum Participation: String, Hashable, Sendable {
        case organizer
        case accepted
        case tentative
        case pending
        case declined
    }

    /// Stable per occurrence and calendar. Opaque; safe to persist and log.
    let id: String
    /// The same for every copy of one occurrence: the event's identifier plus its start, since all
    /// occurrences of a recurring event share an identifier. The same invitation can show up in
    /// two calendars (your own and a shared one); this is how they are recognised as one meeting.
    let occurrenceKey: String
    let calendarID: String
    let calendarTitle: String
    let title: String
    let startsAt: Date
    let endsAt: Date
    let location: String?
    let isAllDay: Bool
    /// A video call link that the event itself carries. Never inferred from the title.
    let joinURL: URL?
    /// `nil` when the calendar doesn't say (e.g. an event without attendees).
    let participation: Participation?

    init(
        id: String,
        occurrenceKey: String? = nil,
        calendarID: String,
        calendarTitle: String = "",
        title: String,
        startsAt: Date,
        endsAt: Date,
        location: String? = nil,
        isAllDay: Bool = false,
        joinURL: URL? = nil,
        participation: Participation? = nil
    ) {
        self.id = id
        self.occurrenceKey = occurrenceKey ?? id
        self.calendarID = calendarID
        self.calendarTitle = calendarTitle
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.location = location
        self.isAllDay = isAllDay
        self.joinURL = joinURL
        self.participation = participation
    }
}

/// Where a meeting is in its lifecycle, relative to now.
enum MeetingPhase: String, Hashable, Sendable {
    /// More than the preparation window away.
    case upcoming
    /// Inside the preparation window: the meeting can claim the user's attention.
    case preparing
    /// About to start. Same attention as `preparing`; only the wording changes.
    case startingSoon
    /// Started and not yet over. No longer upcoming attention.
    case inProgress
    case ended
}

/// A meeting together with what Tern makes of it right now.
struct MeetingStatus: Identifiable, Hashable, Sendable {
    let meeting: Meeting
    let context: SubjectContext
    let phase: MeetingPhase
    /// When it enters its preparation window and can need the user.
    let attentionStartsAt: Date
    /// The same decision shape workstreams have: state, owner, attention, reason, next action.
    var decision: AttentionDecision
    let transition: AttentionTransition
    /// Surfaced as a new transition (the "New" marker), like a workstream's `shouldNotify`.
    var isNew: Bool { decision.shouldNotify }

    var id: String { meeting.id }
    var needsAttentionNow: Bool { decision.nextOwner == .me && decision.attention >= .medium }
}
