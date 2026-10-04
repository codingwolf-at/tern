import Foundation

/// Identity of anything that can claim the user's attention: a workstream or a meeting.
/// Shown-transition bookkeeping and notification records are keyed by it, so that machinery
/// never assumes its subject is a workstream.
///
/// A workstream's subject ID is its workstream ID unchanged (so records saved before meetings
/// existed still match); a meeting's is `calendar:<meeting id>`. Workstream IDs are
/// `<reference kind>:<value>` and no reference kind is `calendar`, so the two never collide.
struct SubjectID: RawRepresentable, Hashable, Sendable, Codable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(workstream id: WorkstreamID) {
        rawValue = id.rawValue
    }

    init(meeting id: String) {
        rawValue = "\(Self.meetingPrefix)\(id)"
    }

    var isMeeting: Bool { rawValue.hasPrefix(Self.meetingPrefix) }

    private static let meetingPrefix = "calendar:"

    static func < (lhs: SubjectID, rhs: SubjectID) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension Workstream {
    var subjectID: SubjectID { SubjectID(workstream: id) }
}

extension Meeting {
    var subjectID: SubjectID { SubjectID(meeting: id) }
}

/// A candidate for Needs you. Workstreams and meetings keep their own models and their own
/// priority inputs; this is only what lets one selection rank them together.
enum AttentionItem: Identifiable, Hashable, Sendable {
    case workstream(Workstream)
    case meeting(MeetingStatus)

    var id: SubjectID {
        switch self {
        case .workstream(let workstream): workstream.subjectID
        case .meeting(let status): status.meeting.subjectID
        }
    }

    var workstream: Workstream? {
        if case .workstream(let workstream) = self { workstream } else { nil }
    }

    var meeting: MeetingStatus? {
        if case .meeting(let status) = self { status } else { nil }
    }

    /// When its current claim on attention began, for recency and tie-breaks.
    var lastMeaningfulChange: Date? {
        switch self {
        case .workstream(let workstream): workstream.lastMeaningfulChange
        case .meeting(let status): status.transition.causeAt
        }
    }
}
