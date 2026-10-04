import Foundation
import Testing
@testable import Tern

/// Calendar behaviour the manual smoke test relies on: section invariants, lifecycle edge cases,
/// context isolation through the app model, permissions and links.
@Suite("Calendar lifecycle")
@MainActor
struct CalendarLifecycleTests {
    static let t0 = CalendarTests.t0
    static let work = CalendarTests.work
    static let work2 = "cal-team"
    static let home = CalendarTests.home

    private func meeting(_ id: String, in calendar: String = CalendarTests.work, startsIn minutes: Double, occurrence: String? = nil,
                         url: URL? = nil, participation: Meeting.Participation? = nil) -> Meeting {
        let start = Self.t0.addingTimeInterval(minutes * 60)
        return Meeting(id: id, occurrenceKey: occurrence, calendarID: calendar, calendarTitle: "Calendar \(calendar)", title: "Meeting \(id)",
                       startsAt: start, endsAt: start.addingTimeInterval(30 * 60), joinURL: url, participation: participation)
    }

    private func service(_ store: InMemoryTernStore = InMemoryTernStore(), clock: TestClock, active: TernContext = .professional) async throws -> IngestionService {
        let service = IngestionService(store: store, now: clock.now)
        try await service.start()
        try await service.setActiveContext(active)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.setContext(.professional, calendar: Self.work)
        try await service.setContext(.professional, calendar: Self.work2)
        try await service.setContext(.personal, calendar: Self.home)
        return service
    }

    private func model(_ service: IngestionService, clock: TestClock) async throws -> AppModel {
        let model = AppModel(service: service)
        model.now = clock.now
        let expected = await service.snapshot
        try await settle { model.meetings == expected.meetings && model.workstreams.count == expected.workstreams.count && model.contextRules == expected.contextRules }
        return model
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }

    private func failingPR(_ number: Int, at minutes: Double = 1) -> [ObservedEvent] {
        let repository = "makeplane/plane"
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number)
        func event(_ kind: WorkEventKind, _ suffix: String, _ time: Double, _ metadata: [MetadataKey: String]) -> ObservedEvent {
            ObservedEvent(id: EventID(.github, "life", "\(number)", suffix), source: .github, kind: kind, timestamp: Self.t0.addingTimeInterval(time * 60),
                          metadata: metadata, references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr)
        }
        return [
            event(.pullRequestOpened, "opened", 0, [.role: "author", .actor: GH.me, .actorIsMe: "true"]),
            event(.ciFailed, "ci", minutes, [.checkName: "build"]),
        ]
    }

    // MARK: Sections

    @Test("Needs you ≤ 3 from one ranking; More is the rest; Up next is one upcoming and one in progress, never a queued meeting")
    func sectionInvariants() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        try await service.ingest(failingPR(1) + failingPR(2), mode: .historyImport)
        try await service.observeMeetings([
            meeting("started", startsIn: -10, url: CalendarTests.zoom),
            meeting("started-too", startsIn: -5),
            meeting("soon", startsIn: 4),
            meeting("soon-pending", startsIn: 6, participation: .pending),
            meeting("next", startsIn: 40),
            meeting("after", startsIn: 90),
        ])
        let model = try await model(service, clock: clock)

        let queue = model.attentionQueue.map(\.id)
        #expect(queue.count == 4)
        #expect(model.needsYou.count == 3)
        #expect(model.needsYou.map(\.id) + model.more.map(\.id) == queue)
        #expect(Set(model.needsYou.map(\.id)).isDisjoint(with: model.more.map(\.id)))
        #expect(Set(queue).count == queue.count)
        // Ranking, not type, decides: the unaccepted meeting (71) is the one pushed to More.
        #expect(model.more.map { $0.meeting?.meeting.id } == ["soon-pending"])

        #expect(model.upNext?.meeting.id == "next")
        #expect(model.meetingInProgress?.meeting.id == "started")
        let upNext = [model.upNext, model.meetingInProgress].compactMap { $0?.meeting.subjectID }
        #expect(Set(upNext).isDisjoint(with: queue))

        // The same input always yields the same sections.
        for _ in 0..<5 {
            try await service.observeMeetings(await service.snapshot.meetings.map(\.meeting).shuffled())
            #expect(model.attentionQueue.map(\.id) == queue)
        }
    }

    // MARK: Lifecycle

    @Test("Each phase lands in the right place: Up next → Needs you → in progress → gone")
    func phases() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let model = try await model(service, clock: clock)
        let meetings = [meeting("m", startsIn: 20)]

        try await service.observeMeetings(meetings)
        try await settle { model.upNext?.meeting.id == "m" }
        #expect(model.attentionQueue.isEmpty)
        #expect(model.upNext.map(MeetingRow.relevance(of:)) == "Needs you from \(Self.t0.addingTimeInterval(5 * 60).formatted(date: .omitted, time: .shortened))")

        clock.advance(minutes: 5)
        try await service.observeMeetings(meetings)
        try await settle { model.attentionQueue.count == 1 }
        #expect(model.upNext == nil)
        let preparing = try #require(model.needsYou.first?.meeting)
        #expect(MeetingRow.relevance(of: preparing) == "Inside the 15-minute preparation window")
        #expect(preparing.decision.nextAction?.title == "Prepare for meeting")

        clock.advance(minutes: 16)
        try await service.observeMeetings(meetings)
        try await settle { model.meetingInProgress != nil }
        #expect(model.attentionQueue.isEmpty)
        #expect(model.upNext == nil)

        clock.advance(minutes: 30)
        try await service.observeMeetings(meetings)
        try await settle { model.meetings.isEmpty }
        #expect(model.meetingInProgress == nil && model.upNext == nil && model.attentionQueue.isEmpty)
    }

    @Test("A moved meeting is a new occurrence: the old one disappears, the new one surfaces once")
    func moved() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        #expect(try await service.observeMeetings([meeting("m@10", startsIn: 10)]).notifications.count == 1)

        // EventKit reports the moved event with its new start, which is part of its identity.
        let moved = [meeting("m@12", startsIn: 12)]
        #expect(try await service.observeMeetings(moved).notifications.count == 1)
        #expect(await service.snapshot.meetings.map(\.meeting.id) == ["m@12"])
        for _ in 0..<3 { #expect(try await service.observeMeetings(moved).notifications.isEmpty) }

        // Moved out of the window: back to Up next, quietly.
        #expect(try await service.observeMeetings([meeting("m@60", startsIn: 60)]).notifications.isEmpty)
        #expect(await service.snapshot.meetings.map(\.phase) == [.upcoming])
    }

    @Test("A cancelled or deleted meeting disappears at the next refresh, and its records expire")
    func cancelled() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock)
        try await service.observeMeetings([meeting("m", startsIn: 10), meeting("n", startsIn: 40)])
        #expect(store.load().notifications.count == 1)

        // Cancelled events aren't reported by the normalizer; deleted ones aren't returned at all.
        try await service.observeMeetings([meeting("n", startsIn: 40)])
        #expect(await service.snapshot.meetings.map(\.meeting.id) == ["n"])

        clock.advance(minutes: 25 * 60)
        try await service.observeMeetings([])
        #expect(!store.load().shownTransitions.contains { $0.subjectID.isMeeting })
        #expect(!store.load().notifications.contains { $0.subjectID.isMeeting })
    }

    @Test("Repeated refreshes never duplicate notifications or rows")
    func repeatedRefresh() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let meetings = [meeting("a", startsIn: 5), meeting("b", startsIn: 30)]
        var notifications = 0
        for _ in 0..<10 {
            notifications += try await service.observeMeetings(meetings).notifications.count
            clock.advance(minutes: 0.5)
        }
        #expect(notifications == 1)
        let ids = await service.snapshot.meetings.map(\.meeting.id)
        #expect(ids == ["a", "b"])
    }

    @Test("One invitation in two calendars: one meeting per context, each context with its own bookkeeping")
    func sameInvitationTwice() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock)
        let copies = [
            meeting("\(Self.work)/x", in: Self.work, startsIn: 10, occurrence: "x"),
            meeting("\(Self.work2)/x", in: Self.work2, startsIn: 10, occurrence: "x"),
            meeting("\(Self.home)/x", in: Self.home, startsIn: 10, occurrence: "x"),
        ]
        let report = try await service.observeMeetings(copies)
        #expect(report.notifications.count == 1)
        let model = try await model(service, clock: clock)
        #expect(model.attentionQueue.count == 1)

        // The personal copy isn't silenced by the professional one having been shown.
        model.setActiveContext(.personal)
        await model.changesSaved()
        #expect(model.attentionQueue.compactMap { $0.meeting?.meeting.calendarID } == [Self.home])
        // Within a context the copy kept is deterministic: the first by calendar ID.
        #expect(store.load().notifications.map(\.subjectID) == [SubjectID(meeting: "\(Self.work2)/x"), SubjectID(meeting: "\(Self.home)/x")])
    }

    // MARK: Contexts

    @Test("An inactive context's meeting: no Needs you, no badge, no alert; switching surfaces it only while it's still relevant")
    func contextSwitching() async throws {
        for (meetingCalendar, meetingContext, other) in [(Self.work, TernContext.professional, TernContext.personal),
                                                         (Self.home, .personal, .professional)] {
            let clock = TestClock(Self.t0)
            let store = InMemoryTernStore()
            let service = try await service(store, clock: clock, active: other)
            let model = try await model(service, clock: clock)
            let meetings = [meeting("m", in: meetingCalendar, startsIn: 10), meeting("gone", in: meetingCalendar, startsIn: 1)]

            #expect(try await service.observeMeetings(meetings).notifications.isEmpty)
            try await settle { model.meetings.count == 2 }
            #expect(model.attentionQueue.isEmpty && model.upNext == nil && model.scopedMeetings.isEmpty)

            // By the time the user switches, one meeting has started: only the other surfaces.
            clock.advance(minutes: 2)
            model.setActiveContext(meetingContext)
            await model.changesSaved()
            #expect(store.load().notifications.map(\.subjectID) == [SubjectID(meeting: "m")])
            try await settle { model.attentionQueue.count == 1 }
            #expect(model.meetingInProgress?.meeting.id == "gone")

            // Switching away and back again isn't news.
            model.setActiveContext(other)
            model.setActiveContext(meetingContext)
            await model.changesSaved()
            #expect(store.load().notifications.count == 1)
        }
    }

    // MARK: Permissions and links

    @Test("Access granted in System Settings while Tern runs is picked up by the next refresh, without prompting")
    func grantedLater() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        let source = FakeCalendarSource(.init(authorization: .denied, calendars: CalendarTests.calendars, meetings: [meeting("m", startsIn: 10)]))
        let account = CalendarAccount(ingestion: service, source: source, schedulesRefreshes: false, now: clock.now)
        let model = AppModel(service: service, calendar: account)
        try await settle { account.authorization == .denied }
        #expect(await service.snapshot.meetings.isEmpty)

        source.state.withLock { $0.authorization = .granted }
        account.refresh() // what opening the panel does
        try await settle { model.meetings.count == 1 }
        #expect(account.authorization == .granted)
        #expect(source.state.withLock { $0.accessRequests } == 0)
    }

    @Test("Join only for a real call link on a known service; anything ambiguous or malformed means Prepare")
    func links() {
        #expect(MeetingLinks.joinURL(url: URL(string: "https://meet.google.com/abc-defg-hij"), location: nil, notes: nil) != nil)
        #expect(MeetingLinks.joinURL(url: nil, location: "https://us02web.zoom.us/j/123?pwd=x", notes: nil) != nil)
        // Bare homepages aren't meetings.
        #expect(MeetingLinks.joinURL(url: URL(string: "https://zoom.us"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: nil, notes: "Download Zoom: https://zoom.us/ first") == nil)
        #expect(MeetingLinks.joinURL(url: URL(string: "https://meet.google.com/"), location: nil, notes: nil) == nil)
        // Malformed, unsupported or non-web links fail safely.
        #expect(MeetingLinks.joinURL(url: URL(string: "https://"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: URL(string: "zoommtg://zoom.us/join?confno=1"), location: nil, notes: nil) == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: "mailto:someone@zoom.us", notes: "ht tp://zoom .us/j/1 :// ") == nil)
        #expect(MeetingLinks.joinURL(url: nil, location: nil, notes: "") == nil)

        let at = Self.t0.addingTimeInterval(20 * 60)
        let linked = MeetingEvaluator.evaluate(meeting("l", startsIn: 30, url: URL(string: "https://acme.webex.com/meet/x")), context: .professional, at: at)
        #expect(linked.decision.nextAction?.title == "Join meeting")
        let plain = MeetingEvaluator.evaluate(meeting("p", startsIn: 30), context: .professional, at: at)
        #expect(plain.decision.nextAction?.title == "Prepare for meeting")
    }

    // MARK: Privacy

    @Test("Saved state holds calendar rules and generic bookkeeping only: no titles, calendar names, places or links")
    func savedStateIsMinimal() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock)
        let secret = Meeting(id: "m", calendarID: Self.work, calendarTitle: "Board calendar", title: "Acquisition talks",
                             startsAt: Self.t0.addingTimeInterval(600), endsAt: Self.t0.addingTimeInterval(2400), location: "CEO office",
                             joinURL: URL(string: "https://zoom.us/j/999?pwd=secret"), participation: .organizer)
        #expect(try await service.observeMeetings([secret]).notifications.count == 1)
        let saved = String(decoding: try JSONEncoder().encode(store.load()), as: UTF8.self)
        for leak in ["Acquisition", "Board calendar", "CEO office", "zoom.us", "secret", "organizer"] {
            #expect(!saved.contains(leak), "\(leak) was persisted")
        }
        #expect(saved.contains(Self.work)) // the classification rule
    }
}
