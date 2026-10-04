import Foundation

/// "Not now" for one attention subject in one context. Suppresses the subject's claim on
/// attention — Needs you, More, the badge and notifications — until `until`, without touching
/// its state, ownership or attention. Nothing about the subject itself is stored.
struct Snooze: Hashable, Sendable, Codable {
    let subjectID: SubjectID
    /// Snoozes are per context: the same subject in the other context is unaffected.
    let context: TernContext
    let until: Date

    func isActive(at date: Date) -> Bool { date < until }

    func applies(to subject: SubjectID, in context: SubjectContext) -> Bool {
        subjectID == subject && context.isIn(self.context)
    }
}

/// The few lengths a snooze can have.
enum SnoozeOption: CaseIterable, Hashable, Sendable {
    case thirtyMinutes
    case oneHour
    case threeHours
    case tomorrowMorning

    /// Tern has no scheduling preference yet; tomorrow morning is 9:00 local time.
    static let morningHour = 9

    var title: String {
        switch self {
        case .thirtyMinutes: "30 minutes"
        case .oneHour: "1 hour"
        case .threeHours: "3 hours"
        case .tomorrowMorning: "Tomorrow morning"
        }
    }

    func until(from now: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .threeHours: now.addingTimeInterval(3 * 60 * 60)
        case .tomorrowMorning:
            calendar.nextDate(after: calendar.startOfDay(for: now).addingTimeInterval(12 * 60 * 60),
                              matching: DateComponents(hour: Self.morningHour, minute: 0), matchingPolicy: .nextTime)
                ?? now.addingTimeInterval(24 * 60 * 60)
        }
    }
}

extension [Snooze] {
    /// The snooze suppressing `subject` in `context` at `date`, if any.
    func active(for subject: SubjectID, in context: SubjectContext, at date: Date) -> Snooze? {
        first { $0.applies(to: subject, in: context) && $0.isActive(at: date) }
    }
}
