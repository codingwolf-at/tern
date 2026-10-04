import Foundation
import os

/// Reads upcoming meetings from the user's classified calendars and hands them to ingestion,
/// which decides what they mean. Runs off the main actor.
///
///     CalendarSyncService → CalendarSource (EventKit) → Meeting → IngestionService.observeMeetings
///
/// Refreshes when Calendar reports a change, and otherwise sleeps until the next moment a
/// meeting's phase can change (entering the preparation window, starting, ending), at most
/// `maximumInterval`. No polling loop beyond that.
actor CalendarSyncService {
    struct Status: Sendable, Equatable {
        var authorization: CalendarAuthorization = .notDetermined
        var calendars: [CalendarInfo] = []
        var lastRefresh: Date?
        /// A short, content-free description of the last failure.
        var lastError: String?
        var meetingCount = 0
    }

    /// Longest sleep between refreshes, to recover from clock changes or a missed notification.
    static let maximumInterval: TimeInterval = 15 * 60
    /// Meetings that started up to this long ago are read, so one in progress is still known.
    static let lookbehind: TimeInterval = 60 * 60

    nonisolated let statusUpdates: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation

    private let source: any CalendarSource
    private let ingestion: IngestionService
    private let policy: MeetingPolicy
    private let now: @Sendable () -> Date
    /// Off in tests, which drive `refresh()` with an injected clock instead of sleeping.
    private let schedulesRefreshes: Bool
    private let logger = Logger(subsystem: "so.plane.tern", category: "calendar")

    private(set) var status = Status()
    private var meetings: [Meeting] = []
    private var timer: Task<Void, Never>?
    private var watcher: Task<Void, Never>?

    init(source: any CalendarSource, ingestion: IngestionService, policy: MeetingPolicy = .standard,
         now: @escaping @Sendable () -> Date = { .now }, schedulesRefreshes: Bool = true) {
        self.source = source
        self.ingestion = ingestion
        self.policy = policy
        self.now = now
        self.schedulesRefreshes = schedulesRefreshes
        (statusUpdates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        timer?.cancel()
        watcher?.cancel()
        continuation.finish()
    }

    /// Starts watching Calendar. Never asks for access by itself.
    func start() async {
        if watcher == nil {
            let changes = source.changes()
            watcher = Task { [weak self] in
                for await _ in changes {
                    await self?.refresh()
                }
            }
        }
        await refresh()
    }

    func stop() {
        timer?.cancel()
        timer = nil
        watcher?.cancel()
        watcher = nil
    }

    /// Asks macOS for read access, on the user's request only.
    func requestAccess() async {
        do {
            _ = try await source.requestAccess()
        } catch {
            logger.error("Calendar access request failed")
        }
        await refresh()
    }

    /// Reads the classified calendars' meetings and passes them on. Without access, or when
    /// something fails, Tern carries on without meetings.
    func refresh() async {
        status.authorization = source.authorization()
        guard status.authorization == .granted else {
            status.calendars = []
            await apply([], error: nil)
            return
        }
        do {
            let calendars = try source.calendars().sorted { ($0.account ?? "", $0.title) < ($1.account ?? "", $1.title) }
            status.calendars = calendars
            // Only calendars the user classified are read; unclassified ones are never fetched.
            let rules = await ingestion.snapshot.contextRules.calendars
            let ids = Set(calendars.map(\.id)).filter { rules[$0] != nil }
            let at = now()
            let found = try source.meetings(in: ids, from: at.addingTimeInterval(-Self.lookbehind), to: at.addingTimeInterval(policy.lookahead))
            await apply(found, error: nil)
        } catch {
            // Never log calendar contents; the error type is enough.
            logger.error("Calendar refresh failed: \(String(describing: type(of: error)), privacy: .public)")
            await apply(meetings, error: "Couldn't read Calendar")
        }
    }

    private func apply(_ found: [Meeting], error: String?) async {
        meetings = found
        do {
            try await ingestion.observeMeetings(found)
        } catch {
            logger.error("Couldn't record meetings")
        }
        status.lastRefresh = now()
        status.lastError = error
        status.meetingCount = found.count
        continuation.yield(status)
        schedule()
    }

    /// The next moment any known meeting changes phase, so a refresh lands exactly on it.
    nonisolated static func nextBoundary(after now: Date, meetings: [Meeting], policy: MeetingPolicy) -> Date {
        let boundaries = meetings.flatMap { meeting in
            [meeting.startsAt.addingTimeInterval(-policy.preparationWindow),
             meeting.startsAt.addingTimeInterval(-policy.startingSoonWindow),
             meeting.startsAt,
             meeting.endsAt]
        }
        let latest = now.addingTimeInterval(maximumInterval)
        return min(boundaries.filter { $0 > now }.min() ?? latest, latest)
    }

    private func schedule() {
        timer?.cancel()
        guard schedulesRefreshes, status.authorization == .granted else { timer = nil; return }
        let delay = Self.nextBoundary(after: now(), meetings: meetings, policy: policy).timeIntervalSince(now())
        timer = Task { [weak self] in
            // A second's slack so the boundary has definitely passed.
            try? await Task.sleep(for: .seconds(max(1, delay + 1)))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }
}
