import Foundation
import Synchronization
import Testing
@testable import Tern

/// A clock tests move by hand. Never wall-clock time.
final class TestClock: Sendable {
    private let date: Mutex<Date>

    init(_ start: Date) { date = Mutex(start) }

    var now: @Sendable () -> Date { { self.date.withLock { $0 } } }

    func set(_ new: Date) { date.withLock { $0 = new } }
    func advance(minutes: Double) { date.withLock { $0 = $0.addingTimeInterval(minutes * 60) } }
}

/// Stands in for EventKit: fixed calendars and meetings, and a record of what was asked for.
final class FakeCalendarSource: CalendarSource {
    struct State {
        var authorization: CalendarAuthorization = .granted
        var calendars: [CalendarInfo] = []
        var meetings: [Meeting] = []
        var failsReading = false
        var grantsAccess = true
        var accessRequests = 0
        var fetchedCalendarIDs: [Set<String>] = []
    }

    let state: Mutex<State>

    init(_ state: State = State()) { self.state = Mutex(state) }

    func authorization() -> CalendarAuthorization { state.withLock { $0.authorization } }

    func requestAccess() async throws -> Bool {
        state.withLock {
            $0.accessRequests += 1
            if $0.grantsAccess { $0.authorization = .granted } else { $0.authorization = .denied }
            return $0.grantsAccess
        }
    }

    func calendars() throws -> [CalendarInfo] {
        try state.withLock {
            guard $0.authorization == .granted else { throw CalendarSourceError.notAuthorized }
            return $0.calendars
        }
    }

    func meetings(in calendarIDs: Set<String>, from start: Date, to end: Date) throws -> [Meeting] {
        try state.withLock {
            guard $0.authorization == .granted else { throw CalendarSourceError.notAuthorized }
            struct ReadFailed: Error {}
            if $0.failsReading { throw ReadFailed() }
            $0.fetchedCalendarIDs.append(calendarIDs)
            return $0.meetings.filter { calendarIDs.contains($0.calendarID) && $0.endsAt > start && $0.startsAt < end }
        }
    }

    func changes() -> AsyncStream<Void> { AsyncStream { $0.finish() } }
}

@Suite("Calendar")
@MainActor
struct CalendarTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let work = "cal-work"
    static let home = "cal-home"
    static let other = "cal-other"

    static let calendars = [
        CalendarInfo(id: work, title: "Work", account: "Exchange"),
        CalendarInfo(id: home, title: "Home", account: "iCloud"),
        CalendarInfo(id: other, title: "Holidays", account: "Subscribed"),
    ]

    /// A 30-minute meeting starting `minutes` after t0.
    static func meeting(_ id: String, in calendar: String, startsIn minutes: Double, url: URL? = nil,
                        allDay: Bool = false, participation: Meeting.Participation? = nil) -> Meeting {
        let start = t0.addingTimeInterval(minutes * 60)
        return Meeting(id: id, calendarID: calendar, calendarTitle: calendar, title: "Meeting \(id)", startsAt: start,
                       endsAt: start.addingTimeInterval(30 * 60), isAllDay: allDay, joinURL: url, participation: participation)
    }

    static let zoom = URL(string: "https://acme.zoom.us/j/123456789")!

    private func service(_ store: InMemoryTernStore = InMemoryTernStore(), clock: TestClock, active: TernContext = .professional) async throws -> IngestionService {
        let service = IngestionService(store: store, now: clock.now)
        try await service.start()
        try await service.setActiveContext(active)
        try await service.setContext(.professional, calendar: Self.work)
        try await service.setContext(.personal, calendar: Self.home)
        return service
    }

    private func model(_ service: IngestionService, calendar: CalendarAccount? = nil) async throws -> AppModel {
        let model = AppModel(service: service, calendar: calendar)
        let expected = await service.snapshot.meetings.count
        try await settle { model.isContextScoped && model.meetings.count == expected && !model.contextRules.calendars.isEmpty }
        return model
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    /// My failing pull request in `repository` (mine, high attention).
    private func failingPR(_ repository: String, _ number: Int) -> [ObservedEvent] {
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number)
        func event(_ kind: WorkEventKind, _ suffix: String, _ at: Double, _ metadata: [MetadataKey: String]) -> ObservedEvent {
            ObservedEvent(id: EventID(.github, "cal", "\(repository)#\(number)", suffix), source: .github, kind: kind, timestamp: GH.at(at),
                          metadata: metadata, references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr)
        }
        return [
            event(.pullRequestOpened, "opened", 0, [.role: "author", .actor: GH.me, .actorIsMe: "true"]),
            event(.ciFailed, "ci", 1, [.checkName: "build"]),
        ]
    }

    // MARK: Evaluation

    @Test("Lifecycle: upcoming → preparing at 15 min → starting soon → in progress → ended; deterministic for a given clock")
    func lifecycle() {
        let meeting = Self.meeting("m", in: Self.work, startsIn: 30)
        func phase(_ minutes: Double) -> MeetingPhase { MeetingEvaluator.phase(of: meeting, at: Self.t0.addingTimeInterval(minutes * 60)) }
        #expect(phase(0) == .upcoming)
        #expect(phase(14.9) == .upcoming)
        #expect(phase(15) == .preparing)
        #expect(phase(27.9) == .preparing)
        #expect(phase(28) == .startingSoon)
        #expect(phase(30) == .inProgress)
        #expect(phase(60) == .ended)

        // The window is configurable, not buried in the engine.
        let ten = MeetingPolicy(preparationWindow: 10 * 60)
        #expect(MeetingEvaluator.phase(of: meeting, at: Self.t0.addingTimeInterval(16 * 60), policy: ten) == .upcoming)
        #expect(MeetingEvaluator.phase(of: meeting, at: Self.t0.addingTimeInterval(20 * 60), policy: ten) == .preparing)
    }

    @Test("Preparing and starting soon are one transition, so a meeting can only notify once")
    func oneTransitionPerMeeting() {
        let meeting = Self.meeting("m", in: Self.work, startsIn: 30)
        let preparing = MeetingEvaluator.evaluate(meeting, context: .professional, at: Self.t0.addingTimeInterval(16 * 60))
        let soon = MeetingEvaluator.evaluate(meeting, context: .professional, at: Self.t0.addingTimeInterval(29 * 60))
        #expect(preparing.needsAttentionNow && soon.needsAttentionNow)
        #expect(preparing.transition == soon.transition)
        #expect(preparing.decision.reason == .meetingSoon)
        #expect(preparing.decision.attention == .medium)
    }

    @Test("All-day and declined meetings never claim attention")
    func quietMeetings() {
        let at = Self.t0.addingTimeInterval(20 * 60)
        #expect(!MeetingEvaluator.evaluate(Self.meeting("a", in: Self.work, startsIn: 30, allDay: true), context: .professional, at: at).needsAttentionNow)
        #expect(!MeetingEvaluator.evaluate(Self.meeting("d", in: Self.work, startsIn: 30, participation: .declined), context: .professional, at: at).needsAttentionNow)
        #expect(MeetingEvaluator.evaluate(Self.meeting("t", in: Self.work, startsIn: 30, participation: .tentative), context: .professional, at: at).needsAttentionNow)
    }

    @Test("A Join action only with a real meeting link; without one, no fake Join")
    func nextAction() {
        let at = Self.t0.addingTimeInterval(20 * 60)
        let linked = MeetingEvaluator.evaluate(Self.meeting("l", in: Self.work, startsIn: 30, url: Self.zoom), context: .professional, at: at)
        #expect(linked.decision.nextAction?.title == "Join meeting")
        let plain = MeetingEvaluator.evaluate(Self.meeting("p", in: Self.work, startsIn: 30), context: .professional, at: at)
        #expect(plain.decision.nextAction?.title == "Prepare for meeting")
        #expect(plain.meeting.joinURL == nil)
    }

    @Test("Meeting links come only from the event itself and only from known call services")
    func meetingLinks() {
        #expect(MeetingLinks.joinURL(url: Self.zoom, location: nil, notes: nil) == Self.zoom)
        #expect(MeetingLinks.joinURL(url: URL(string: "https://example.com/agenda"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: "Room 4", notes: "Agenda: https://docs.example.com/x") == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: "https://meet.google.com/abc-defg-hij", notes: nil)
            == URL(string: "https://meet.google.com/abc-defg-hij"))
        #expect(MeetingLinks.joinURL(url: nil, location: nil, notes: "Join: https://teams.microsoft.com/l/meetup-join/xyz")
            == URL(string: "https://teams.microsoft.com/l/meetup-join/xyz"))
        // Not https, or a look-alike host, isn't a call link.
        #expect(MeetingLinks.joinURL(url: URL(string: "http://zoom.us/j/1"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: URL(string: "https://zoom.us.evil.example/j/1"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: nil, notes: "Team sync (no link)") == nil)
    }

    // MARK: Contexts

    @Test("Personal calendars affect only Personal, Professional only Professional, unclassified neither")
    func contextIsolation() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock, active: .professional)
        let meetings = [Self.meeting("w", in: Self.work, startsIn: 10), Self.meeting("h", in: Self.home, startsIn: 10),
                        Self.meeting("o", in: Self.other, startsIn: 10)]
        let report = try await service.observeMeetings(meetings)
        // Only the professional meeting notifies; the unclassified one isn't even kept.
        #expect(report.notifications.map(\.subjectID) == [SubjectID(meeting: "w")])
        #expect(await service.snapshot.meetings.map(\.meeting.id) == ["h", "w"])

        let model = try await model(service)
        #expect(model.scopedMeetings.map(\.meeting.id) == ["w"])
        #expect(model.needsYou.compactMap(\.meeting?.meeting.id) == ["w"])
        #expect(model.attentionQueue.count == 1)

        // Switching changes the visible meetings at once, with no round trip.
        model.setActiveContext(.personal)
        #expect(model.scopedMeetings.map(\.meeting.id) == ["h"])
        #expect(model.needsYou.compactMap(\.meeting?.meeting.id) == ["h"])
        #expect(model.attentionQueue.count == 1)
        #expect(!model.meetings.contains { $0.meeting.id == "o" })
    }

    @Test("An inactive-context or unclassified meeting cannot notify, however often it is seen")
    func inactiveAndUnclassifiedAreQuiet() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock, active: .personal)
        let meetings = [Self.meeting("w", in: Self.work, startsIn: 10), Self.meeting("o", in: Self.other, startsIn: 10)]
        for _ in 0..<3 {
            #expect(try await service.observeMeetings(meetings).notifications.isEmpty)
            clock.advance(minutes: 1)
        }
        // Not recorded as seen either: Professional decides that for itself.
        #expect(!store.load().shownTransitions.contains { $0.subjectID.isMeeting })
        #expect(store.load().notifications.isEmpty)
    }

    @Test("A meeting that became relevant while away surfaces once on switching back; one already shown never repeats")
    func switchingBack() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock, active: .personal)
        try await service.observeMeetings([Self.meeting("w", in: Self.work, startsIn: 10), Self.meeting("h", in: Self.home, startsIn: 10)])
        #expect(store.load().notifications.map(\.subjectID) == [SubjectID(meeting: "h")])

        try await service.setActiveContext(.professional)
        #expect(store.load().notifications.map(\.subjectID) == [SubjectID(meeting: "h"), SubjectID(meeting: "w")])

        // Back and forth with nothing new: no duplicates.
        try await service.setActiveContext(.personal)
        try await service.setActiveContext(.professional)
        for _ in 0..<3 { try await service.observeMeetings([Self.meeting("w", in: Self.work, startsIn: 10), Self.meeting("h", in: Self.home, startsIn: 10)]) }
        #expect(store.load().notifications.count == 2)
    }

    // MARK: Attention window

    @Test("Outside the window nothing notifies; entering it notifies once; repeated syncs and 'starting soon' don't repeat")
    func window() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let meetings = [Self.meeting("m", in: Self.work, startsIn: 20)]

        let early = try await service.observeMeetings(meetings)
        #expect(early.notifications.isEmpty)
        #expect(await service.snapshot.meetings.first?.phase == .upcoming)
        #expect(await service.snapshot.meetings.first?.needsAttentionNow == false)

        clock.advance(minutes: 4.9)
        #expect(try await service.observeMeetings(meetings).notifications.isEmpty)

        clock.advance(minutes: 0.1) // exactly 15 minutes before
        let entered = try await service.observeMeetings(meetings)
        #expect(entered.notifications.map(\.headline) == [IngestionService.meetingHeadline])
        let status = try #require(await service.snapshot.meetings.first)
        #expect(status.phase == .preparing && status.needsAttentionNow && status.isNew)

        for _ in 0..<5 {
            clock.advance(minutes: 2)
            #expect(try await service.observeMeetings(meetings).notifications.isEmpty)
        }
        clock.set(Self.t0.addingTimeInterval(19 * 60))
        #expect(await service.snapshot.meetings.isEmpty == false)
        #expect(try await service.observeMeetings(meetings).notifications.isEmpty)
        #expect(await service.snapshot.meetings.first?.phase == .startingSoon)
    }

    @Test("Once started a meeting leaves attention, and once over it leaves Tern")
    func startedAndPassed() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let meetings = [Self.meeting("m", in: Self.work, startsIn: 10)]
        try await service.observeMeetings(meetings)
        #expect(await service.snapshot.meetings.first?.needsAttentionNow == true)

        clock.advance(minutes: 11)
        #expect(try await service.observeMeetings(meetings).notifications.isEmpty)
        let started = try #require(await service.snapshot.meetings.first)
        #expect(started.phase == .inProgress && !started.needsAttentionNow && !started.isNew)

        clock.advance(minutes: 30)
        try await service.observeMeetings(meetings)
        #expect(await service.snapshot.meetings.isEmpty)
    }

    @Test("Restart rebuilds meeting state from Calendar data; only bookkeeping is persisted, without meeting contents")
    func restart() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let meetings = [Self.meeting("m", in: Self.work, startsIn: 10, url: Self.zoom), Self.meeting("later", in: Self.work, startsIn: 120)]
        let first = try await service(store, clock: clock)
        #expect(try await first.observeMeetings(meetings).notifications.count == 1)

        clock.advance(minutes: 2)
        let relaunched = IngestionService(store: store, now: clock.now)
        let snapshot = try await relaunched.start()
        #expect(snapshot.meetings.isEmpty) // nothing about meetings is restored from disk
        #expect(snapshot.contextRules.context(forCalendar: Self.work) == .professional)

        #expect(try await relaunched.observeMeetings(meetings).notifications.isEmpty)
        let status = try #require(await relaunched.snapshot.meetings.first)
        #expect(status.meeting.id == "m" && status.phase == .preparing && status.isNew)
        #expect(await relaunched.snapshot.meetings.map(\.phase) == [.preparing, .upcoming])

        let saved = String(decoding: try JSONEncoder().encode(store.load()), as: UTF8.self)
        #expect(!saved.contains("Meeting m"))
        #expect(!saved.contains("zoom.us"))
        #expect(!saved.contains("later")) // a quiet upcoming meeting leaves no trace
    }

    @Test("Bookkeeping for old meetings is forgotten after a day")
    func bookkeepingPruned() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock)
        try await service.observeMeetings([Self.meeting("m", in: Self.work, startsIn: 10)])
        #expect(store.load().shownTransitions.contains { $0.subjectID == SubjectID(meeting: "m") })
        clock.advance(minutes: 25 * 60)
        try await service.observeMeetings([Self.meeting("n", in: Self.work, startsIn: 25 * 60 + 10)])
        #expect(!store.load().shownTransitions.contains { $0.subjectID == SubjectID(meeting: "m") })
    }

    @Test("A meeting never changes any workstream's score or their order relative to each other")
    func workstreamPriorityUnchanged() async throws {
        let clock = TestClock(GH.t0)
        let service = try await service(clock: clock)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.ingest(failingPR("makeplane/plane", 1) + failingPR("makeplane/plane", 2), mode: .historyImport)
        let model = try await model(service)
        model.now = clock.now
        try await settle { model.workstreams.count == 2 }
        let before = model.attentionQueue.compactMap(\.workstream).map { ($0.id, model.priority(of: $0)) }

        try await service.observeMeetings([Self.meeting("m", in: Self.work, startsIn: 10)])
        try await settle { model.meetings.count == 1 }
        let after = model.attentionQueue.compactMap(\.workstream).map { ($0.id, model.priority(of: $0)) }
        #expect(after.map(\.0) == before.map(\.0))
        #expect(after.map(\.1) == before.map(\.1))
        #expect(model.attentionQueue.count == 3)
    }

    // MARK: Sync and permissions

    @Test("Only classified calendars are read, and classification edits apply at once")
    func classification() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let source = FakeCalendarSource(.init(calendars: Self.calendars, meetings: [
            Self.meeting("w", in: Self.work, startsIn: 10), Self.meeting("o", in: Self.other, startsIn: 10),
        ]))
        let account = CalendarAccount(ingestion: service, source: source, startSyncing: false, now: clock.now)
        await account.service.refresh()
        #expect(source.state.withLock { $0.fetchedCalendarIDs.last } == [Self.work, Self.home])

        let model = try await model(service, calendar: account)
        try await settle { model.meetings.count == 1 }
        #expect(model.scopedMeetings.map(\.meeting.id) == ["w"])

        // Filing the unclassified calendar under Professional reads it and shows its meeting.
        model.setContext(.professional, forCalendar: Self.other)
        await model.changesSaved()
        try await settle { model.scopedMeetings.count == 2 }
        #expect(model.scopedMeetings.map(\.meeting.id).sorted() == ["o", "w"])

        // Clearing a classification removes its meetings from the panel immediately.
        model.setContext(nil, forCalendar: Self.work)
        #expect(model.scopedMeetings.map(\.meeting.id) == ["o"])
        await model.changesSaved()
        try await settle { model.meetings.map(\.meeting.id) == ["o"] }
        #expect(model.contextRules.context(forCalendar: Self.work) == .unclassified)
    }

    @Test("Without permission Tern never asks by itself, reads nothing, and everything else keeps working")
    func permissionDenied() async throws {
        for authorization in [CalendarAuthorization.notDetermined, .denied, .restricted] {
            let clock = TestClock(GH.t0)
            let service = try await service(clock: clock)
            try await service.setContext(.professional, forOwner: "makeplane")
            let source = FakeCalendarSource(.init(authorization: authorization, calendars: Self.calendars,
                                                  meetings: [Self.meeting("w", in: Self.work, startsIn: 10)]))
            let sync = CalendarSyncService(source: source, ingestion: service, now: clock.now, schedulesRefreshes: false)
            await sync.refresh()
            #expect(await sync.status.authorization == authorization)
            #expect(await sync.status.calendars.isEmpty)
            #expect(source.state.withLock { $0.accessRequests == 0 && $0.fetchedCalendarIDs.isEmpty })
            #expect(await service.snapshot.meetings.isEmpty)

            let report = try await service.ingest(failingPR("makeplane/plane", 1))
            #expect(report.notifications.map(\.headline) == ["CI failed"])
        }
    }

    @Test("Granting access on request starts reading; a read failure keeps Tern running")
    func grantAndFailure() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let source = FakeCalendarSource(.init(authorization: .notDetermined, calendars: Self.calendars,
                                              meetings: [Self.meeting("w", in: Self.work, startsIn: 10)]))
        let sync = CalendarSyncService(source: source, ingestion: service, now: clock.now, schedulesRefreshes: false)
        await sync.requestAccess()
        #expect(source.state.withLock { $0.accessRequests } == 1)
        #expect(await sync.status.authorization == .granted)
        #expect(await service.snapshot.meetings.map(\.meeting.id) == ["w"])

        source.state.withLock { $0.failsReading = true }
        await sync.refresh()
        #expect(await sync.status.lastError == "Couldn't read Calendar")
        #expect(await service.snapshot.meetings.map(\.meeting.id) == ["w"]) // last known meetings stay

        source.state.withLock { $0.failsReading = false; $0.calendars = []; $0.meetings = [] }
        await sync.refresh()
        #expect(await sync.status.lastError == nil)
        #expect(await service.snapshot.meetings.isEmpty)
    }

    @Test("Refreshes are scheduled for the next phase boundary, capped, never a tight loop")
    func nextBoundary() {
        let policy = MeetingPolicy.standard
        let meeting = Self.meeting("m", in: Self.work, startsIn: 30)
        func next(_ minutes: Double) -> Double {
            CalendarSyncService.nextBoundary(after: Self.t0.addingTimeInterval(minutes * 60), meetings: [meeting], policy: policy)
                .timeIntervalSince(Self.t0) / 60
        }
        #expect(next(0) == 15)
        #expect(next(15) == 28)
        #expect(next(28) == 30)
        #expect(next(30) == 45) // capped at 15 minutes, before the 60-minute end
        #expect(next(59) == 60)
        #expect(next(61) == 76) // nothing ahead: the cap
    }

    @Test("Context rules saved before calendars existed still load")
    func legacyRules() throws {
        let json = #"{"owners":{"makeplane":"professional"},"repositories":{}}"#
        let rules = try JSONDecoder().decode(ContextRules.self, from: Data(json.utf8))
        #expect(rules.calendars.isEmpty)
        #expect(rules.context(forRepository: "makeplane/plane") == .professional)
    }

    @Test("Timing text uses the injected clock")
    func timingText() {
        let meeting = Self.meeting("m", in: Self.work, startsIn: 30)
        func text(_ minutes: Double) -> String {
            let at = Self.t0.addingTimeInterval(minutes * 60)
            return MeetingRow.timing(of: meeting, phase: MeetingEvaluator.phase(of: meeting, at: at), now: at)
        }
        #expect(text(18) == "In 12 min")
        #expect(text(29.5) == "Starting now")
        #expect(text(33) == "Started 3 min ago")
    }
}
