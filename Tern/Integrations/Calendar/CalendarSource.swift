import EventKit
import Foundation

/// Whether Tern may read the user's calendars.
enum CalendarAuthorization: Sendable, Equatable {
    /// Never asked. Tern asks only when the user chooses to.
    case notDetermined
    case denied
    /// Blocked by a profile or parental controls; the user can't change it in Tern.
    case restricted
    case granted
}

enum CalendarSourceError: Error, Equatable {
    case notAuthorized
}

/// Read-only access to the user's calendars. EventKit in the app; a fake in tests.
protocol CalendarSource: Sendable {
    func authorization() -> CalendarAuthorization
    /// Shows the system prompt (once; later calls return the stored answer).
    func requestAccess() async throws -> Bool
    func calendars() throws -> [CalendarInfo]
    /// Occurrences overlapping `start..<end` in the given calendars only.
    func meetings(in calendarIDs: Set<String>, from start: Date, to end: Date) throws -> [Meeting]
    /// Fires when Calendar data changes outside Tern.
    func changes() -> AsyncStream<Void>
}

/// The local macOS calendar database through EventKit. Never writes.
///
/// `@unchecked Sendable`: the event store is only used from `CalendarSyncService`, one call at a time.
final class EventKitCalendarSource: CalendarSource, @unchecked Sendable {
    private let store = EKEventStore()
    private var lastAuthorization: CalendarAuthorization?

    func authorization() -> CalendarAuthorization {
        let authorization: CalendarAuthorization = switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .restricted: .restricted
        case .fullAccess: .granted
        // Write-only access can't read events, which is all Tern needs.
        case .denied, .writeOnly: .denied
        @unknown default: .denied
        }
        // Access granted in System Settings while Tern runs: a store created without access
        // needs a reset before it returns anything.
        if authorization == .granted, let last = lastAuthorization, last != .granted { store.reset() }
        lastAuthorization = authorization
        return authorization
    }

    func requestAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        if granted { store.reset() }
        return granted
    }

    func calendars() throws -> [CalendarInfo] {
        guard authorization() == .granted else { throw CalendarSourceError.notAuthorized }
        return store.calendars(for: .event).map {
            CalendarInfo(id: $0.calendarIdentifier, title: $0.title, account: $0.source?.title)
        }
    }

    func meetings(in calendarIDs: Set<String>, from start: Date, to end: Date) throws -> [Meeting] {
        guard authorization() == .granted else { throw CalendarSourceError.notAuthorized }
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        // An empty list would mean "every calendar" to EventKit.
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap(CalendarNormalizer.meeting(from:))
    }

    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            // Tern has one event store, so any store's change notification is ours.
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged) {
                    continuation.yield()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// EKEvent → `Meeting`. Reads only the fields Tern keeps; notes are scanned for a call link and
/// dropped, attendees are reduced to the user's own participation.
enum CalendarNormalizer {
    static func meeting(from event: EKEvent) -> Meeting? {
        guard event.status != .canceled,
              let calendar = event.calendar,
              let startsAt = event.startDate, let endsAt = event.endDate
        else { return nil }
        let identifier = event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrence = "\(identifier)@\(Int(startsAt.timeIntervalSince1970))"
        return Meeting(
            id: "\(calendar.calendarIdentifier)/\(occurrence)",
            occurrenceKey: occurrence,
            calendarID: calendar.calendarIdentifier,
            calendarTitle: calendar.title,
            title: event.title?.isEmpty == false ? event.title : "Untitled event",
            startsAt: startsAt,
            endsAt: endsAt,
            location: event.location?.isEmpty == false ? event.location : nil,
            isAllDay: event.isAllDay,
            joinURL: MeetingLinks.joinURL(url: event.url, location: event.location, notes: event.notes),
            participation: participation(in: event)
        )
    }

    private static func participation(in event: EKEvent) -> Meeting.Participation? {
        if event.organizer?.isCurrentUser == true { return .organizer }
        guard let me = event.attendees?.first(where: \.isCurrentUser) else { return nil }
        return switch me.participantStatus {
        case .accepted, .delegated, .completed, .inProcess: .accepted
        case .tentative: .tentative
        case .declined: .declined
        case .pending, .unknown: .pending
        @unknown default: .pending
        }
    }
}

/// Finds a video call link the event explicitly carries. Only well-known meeting services are
/// accepted from free text, so an arbitrary link in the notes is never mistaken for one.
enum MeetingLinks {
    /// Hosts (and their subdomains) of services whose links join a call.
    static let meetingHosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com",
                               "whereby.com", "around.co", "meet.jit.si", "chime.aws", "gotomeeting.com", "facetime.apple.com"]

    /// The event's own URL when it is a call link, otherwise the first call link in its
    /// location, then its notes. `nil` when there is none — never guessed.
    static func joinURL(url: URL?, location: String?, notes: String?) -> URL? {
        if let url, isMeetingLink(url) { return url }
        for text in [location, notes].compactMap(\.self) {
            if let link = links(in: text).first(where: isMeetingLink) { return link }
        }
        return nil
    }

    /// An https link on a known service's host with a path: a service's bare homepage (as in
    /// "download Zoom at https://zoom.us") is not a meeting.
    static func isMeetingLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(),
              !url.path().trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        else { return false }
        return meetingHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func links(in text: String) -> [URL] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
        return detector.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url)
    }
}
