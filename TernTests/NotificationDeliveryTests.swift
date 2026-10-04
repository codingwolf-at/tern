import Foundation
import Synchronization
import Testing
@testable import Tern

/// Stands in for `UNUserNotificationCenter`: records requests, prompts at most once.
final class FakeNotificationCenter: UserNotificationCenter {
    struct State {
        var authorization: NotificationAuthorization = .authorized
        var grants = true
        var prompts = 0
        var requests: [NotificationRequest] = []
        var failsAdding = false
    }

    let state: Mutex<State>

    init(_ authorization: NotificationAuthorization = .authorized, grants: Bool = true) {
        state = Mutex(State(authorization: authorization, grants: grants))
    }

    var requests: [NotificationRequest] { state.withLock { $0.requests } }

    func authorization() async -> NotificationAuthorization { state.withLock { $0.authorization } }

    func requestAuthorization() async throws -> Bool {
        state.withLock {
            // Like macOS: only an undetermined permission shows the prompt.
            if $0.authorization == .notDetermined {
                $0.prompts += 1
                $0.authorization = $0.grants ? .authorized : .denied
            }
            return $0.authorization == .authorized
        }
    }

    func add(_ request: NotificationRequest) async throws {
        struct Failed: Error {}
        try state.withLock {
            if $0.failsAdding { throw Failed() }
            $0.requests.append(request)
        }
    }
}

@Suite("Notification delivery", .serialized)
@MainActor
struct NotificationDeliveryTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let work = "makeplane/plane"
    static let side = "atul/blog"
    static let stranger = "someone/else"

    private func at(_ minutes: Double) -> Date { Self.t0.addingTimeInterval(minutes * 60) }

    private struct Rig {
        let store: InMemoryTernStore
        let clock: TestClock
        let service: IngestionService
        let center: FakeNotificationCenter
        let model: AppModel
    }

    private func rig(active: TernContext = .professional, center: FakeNotificationCenter = FakeNotificationCenter(),
                     store: InMemoryTernStore = InMemoryTernStore(), clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))) async throws -> Rig {
        let service = IngestionService(store: store, now: clock.now)
        try await service.start()
        try await service.setActiveContext(active)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.setContext(.personal, forOwner: "atul")
        try await service.setContext(.professional, calendar: CalendarTests.work)
        try await service.setContext(.personal, calendar: CalendarTests.home)
        let model = AppModel(service: service, notifications: NotificationDelivery(center: center))
        try await settle { model.isContextScoped && !model.contextRules.calendars.isEmpty }
        return Rig(store: store, clock: clock, service: service, center: center, model: model)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    /// Lets queued deliveries drain, then returns what reached the notification center.
    private func delivered(_ rig: Rig, expecting count: Int) async throws -> [NotificationRequest] {
        try await settle { rig.center.requests.count >= count }
        try await Task.sleep(for: .milliseconds(50)) // anything extra would show up by now
        return rig.center.requests
    }

    private func pr(_ repository: String, _ number: Int, _ steps: [(WorkEventKind, Double, [MetadataKey: String])], role: String = "author") -> [ObservedEvent] {
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number, title: "Avatar migration")
        let opened = (WorkEventKind.pullRequestOpened, 0.0, role == "author" ? [MetadataKey.role: "author", .actor: GH.me, .actorIsMe: "true"] : [.role: "reviewer", .actor: "priya"])
        return ([opened] + steps).map { kind, minutes, metadata in
            ObservedEvent(id: EventID(.github, "notify", "\(repository)#\(number)", kind.rawValue, "\(minutes)"), source: .github, kind: kind,
                          timestamp: at(minutes), metadata: metadata, references: [reference], suggestedTitle: "Avatar migration", pullRequest: pr)
        }
    }

    private func claude(_ kind: WorkEventKind, at minutes: Double, repository: String = "github.com/atul/blog", _ extra: [MetadataKey: String] = [:]) -> ObservedEvent {
        ObservedEvent(id: EventID(.agent, "notify", "s1", kind.rawValue, "\(minutes)"), source: .agent, kind: kind, timestamp: at(minutes),
                      metadata: [.agentName: "Claude Code", .agentSessionID: "s1", .repository: repository].merging(extra) { $1 },
                      references: [.agentSession(provider: "claude", id: "s1")], suggestedTitle: "blog · main")
    }

    // MARK: Permission

    @Test("Permission: never asked at launch; Enable prompts once; denied, authorized and unavailable are reported")
    func permission() async throws {
        let undetermined = FakeNotificationCenter(.notDetermined)
        let first = try await rig(center: undetermined)
        try await settle { first.model.notifications?.authorization == .notDetermined }
        try await Task.sleep(for: .milliseconds(50))
        #expect(undetermined.state.withLock { $0.prompts } == 0)
        await first.model.notifications?.enable()
        #expect(first.model.notifications?.authorization == .authorized)
        await first.model.notifications?.enable()
        #expect(undetermined.state.withLock { $0.prompts } == 1)

        let refusing = FakeNotificationCenter(.notDetermined, grants: false)
        let delivery = NotificationDelivery(center: refusing)
        await delivery.enable()
        #expect(delivery.authorization == .denied)
        await delivery.enable()
        #expect(refusing.state.withLock { $0.prompts } == 1) // no repeated prompts

        let broken = NotificationDelivery(center: FakeNotificationCenter(.unavailable))
        await broken.refresh()
        #expect(broken.authorization == .unavailable)
    }

    @Test("Without permission nothing reaches macOS, but the New marker and the record still happen")
    func deniedKeepsInAppSurfaces() async throws {
        for authorization in [NotificationAuthorization.notDetermined, .denied, .unavailable] {
            let rig = try await rig(center: FakeNotificationCenter(authorization))
            let report = try await rig.service.ingest(pr(Self.work, 1, [(.ciFailed, 1, [.checkName: "build"])]))
            #expect(report.notifications.count == 1)
            #expect(await rig.service.snapshot.workstreams.first?.evaluation.decision.shouldNotify == true)
            #expect(try await delivered(rig, expecting: 0).isEmpty)
        }
    }

    @Test("Permission granted later in System Settings applies to the next notification, without a relaunch")
    func grantedLater() async throws {
        let center = FakeNotificationCenter(.denied)
        let rig = try await rig(center: center)
        try await rig.service.ingest(pr(Self.work, 1, [(.ciFailed, 1, [.checkName: "build"])]))
        #expect(try await delivered(rig, expecting: 0).isEmpty)
        center.state.withLock { $0.authorization = .authorized }
        try await rig.service.ingest(pr(Self.work, 2, [(.ciFailed, 1, [.checkName: "build"])]))
        #expect(try await delivered(rig, expecting: 1).count == 1)
    }

    // MARK: Duplicates

    @Test("One transition, one macOS notification: repeats, replays, context switches and restarts add none")
    func noDuplicates() async throws {
        let store = InMemoryTernStore()
        let clock = TestClock(Self.t0)
        let rig = try await rig(store: store, clock: clock)
        let events = pr(Self.work, 1, [(.ciFailed, 1, [.checkName: "build"])])
        try await rig.service.ingest(events)
        try await rig.service.ingest(events) // replay: already-seen events
        try await rig.service.ingest(events)
        try await rig.service.setActiveContext(.personal)
        try await rig.service.setActiveContext(.professional)
        let requests = try await delivered(rig, expecting: 1)
        #expect(requests.count == 1)
        #expect(requests.first?.id == NotificationPayload.identifier(subject: SubjectID(rawValue: "github.pr:makeplane/plane#1"),
                                                                     fingerprint: store.load().notifications[0].fingerprint))

        // Relaunch over the same state: the surfaced transition isn't news again.
        let center = FakeNotificationCenter()
        let relaunched = try await self.rig(center: center, store: store, clock: clock)
        try await relaunched.service.ingest(events)
        #expect(try await delivered(relaunched, expecting: 0).isEmpty)

        // A genuinely new transition on the same PR is one more notification, with a new identifier.
        try await relaunched.service.ingest([pr(Self.work, 1, [(.ciFailed, 5, [.checkName: "lint"])])[1]])
        let next = try await delivered(relaunched, expecting: 1)
        #expect(next.count == 1 && next[0].id != requests[0].id)
    }

    // MARK: Contexts

    @Test("Only the active context notifies; unclassified never does; work from the other context waits for its own")
    func contexts() async throws {
        let rig = try await rig(active: .personal)
        try await rig.service.ingest(pr(Self.side, 1, [(.ciFailed, 1, [.checkName: "build"])]))
        try await rig.service.ingest(pr(Self.work, 2, [(.ciFailed, 1, [.checkName: "build"])]))
        try await rig.service.ingest(pr(Self.stranger, 3, [(.ciFailed, 1, [.checkName: "build"])]))
        let personal = try await delivered(rig, expecting: 1)
        #expect(personal.map(\.subjectID) == ["github.pr:atul/blog#1"])

        try await rig.service.setActiveContext(.professional)
        try await rig.service.ingest(pr(Self.side, 4, [(.ciFailed, 1, [.checkName: "build"])]))
        #expect(try await delivered(rig, expecting: 1).count == 1)

        // The professional PR's next change is news in Professional.
        try await rig.service.ingest([pr(Self.work, 2, [(.ciFailed, 7, [.checkName: "lint"])])[1]])
        #expect(try await delivered(rig, expecting: 2).map(\.subjectID) == ["github.pr:atul/blog#1", "github.pr:makeplane/plane#2"])
    }

    // MARK: Meetings

    @Test("A meeting notifies once on entering its window; refreshes don't repeat it; a moved meeting follows its new time")
    func meetings() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        let linked = CalendarTests.meeting("design", in: CalendarTests.work, startsIn: 20, url: CalendarTests.zoom)
        try await rig.service.observeMeetings([linked])
        clock.advance(minutes: 5)
        for _ in 0..<4 {
            try await rig.service.observeMeetings([linked])
            clock.advance(minutes: 1)
        }
        let requests = try await delivered(rig, expecting: 1)
        #expect(requests.count == 1)
        #expect(requests[0].title == "Meeting design starts in 15 min")
        #expect(requests[0].body == "Join meeting")
        #expect(requests[0].category == NotificationDelivery.Category.joinableMeeting)

        let plain = CalendarTests.meeting("sync", in: CalendarTests.work, startsIn: 18)
        try await rig.service.observeMeetings([linked, plain])
        let both = try await delivered(rig, expecting: 2)
        #expect(both.last?.category == NotificationDelivery.Category.meeting)
        #expect(both.last?.body == "Prepare for meeting")

        // Moved: a new occurrence, surfaced once at its new time.
        let moved = CalendarTests.meeting("sync@moved", in: CalendarTests.work, startsIn: 19)
        try await rig.service.observeMeetings([linked, moved])
        try await rig.service.observeMeetings([linked, moved])
        #expect(try await delivered(rig, expecting: 3).count == 3)
    }

    @Test("Personal meetings don't notify in Professional, and vice versa")
    func meetingContexts() async throws {
        let rig = try await rig(active: .professional)
        try await rig.service.observeMeetings([CalendarTests.meeting("home", in: CalendarTests.home, startsIn: 10),
                                               CalendarTests.meeting("other", in: "cal-unknown", startsIn: 10)])
        #expect(try await delivered(rig, expecting: 0).isEmpty)
        try await rig.service.setActiveContext(.personal)
        #expect(try await delivered(rig, expecting: 1).map(\.title) == ["Meeting home starts in 10 min"])
    }

    @Test("Join opens nothing by itself: the notification carries no link, and Join looks the meeting up")
    func joinIsExplicit() async throws {
        let rig = try await rig()
        try await rig.service.observeMeetings([CalendarTests.meeting("design", in: CalendarTests.work, startsIn: 10, url: CalendarTests.zoom)])
        let request = try #require(try await delivered(rig, expecting: 1).first)
        #expect(!String(describing: request).contains("zoom"))
        // A plain click only points Tern at the meeting; it never changes its state.
        rig.model.handle(.open(SubjectID(rawValue: request.subjectID)))
        #expect(rig.model.focusedSubject?.rawValue == request.subjectID)
        #expect(rig.model.attentionQueue.count == 1)
    }

    // MARK: Workstream content

    @Test("Workstream notifications say what happened, which work, and what to do")
    func workstreamContent() async throws {
        let rig = try await rig(active: .personal)
        try await rig.service.ingest(pr(Self.side, 1, [(.reviewRequested, 1, [.reviewer: GH.me, .reviewerIsMe: "true"])], role: "reviewer"))
        try await rig.service.ingest(pr(Self.side, 2, [(.reviewRequested, 1, [.reviewer: "priya"]),
                                                      (.changesRequested, 2, [.reviewer: "priya", .commentCount: "3"])]))
        try await rig.service.ingest(pr(Self.side, 3, [(.ciFailed, 1, [.checkName: "build"])]))
        try await rig.service.ingest([claude(.agentStarted, at: 1), claude(.agentNeedsInput, at: 2, [.prompt: "Delete the prod database? SECRET-PROMPT"])])
        try await rig.service.ingest([claude(.agentResumed, at: 3), claude(.agentCompleted, at: 4)])

        let requests = try await delivered(rig, expecting: 5)
        #expect(requests.map(\.title) == ["Review requested", "Changes requested", "CI failed", "Claude needs your input", "Claude finished"])
        #expect(requests[0].subtitle == "PR #1 · Avatar migration")
        #expect(requests.allSatisfy { !$0.body.isEmpty })
        #expect(requests.map(\.category).allSatisfy { $0 == NotificationDelivery.Category.workstream })
        #expect(Set(requests.map(\.id)).count == requests.count)
    }

    // MARK: Privacy

    @Test("Payloads carry no prompts, status details, descriptions, places or links, and nothing new is saved")
    func privacy() async throws {
        let rig = try await rig(active: .personal)
        try await rig.service.ingest([claude(.agentStarted, at: 1), claude(.agentNeedsInput, at: 2, [.prompt: "SECRET-PROMPT"])])
        try await rig.service.ingest(pr(Self.side, 2, [(.reviewRequested, 1, [.reviewer: "priya"]),
                                                      (.changesRequested, 2, [.reviewer: "priya", .commentCount: "3"])]))
        let secret = Meeting(id: "m", calendarID: CalendarTests.home, calendarTitle: "Board", title: "Offsite", startsAt: at(10), endsAt: at(40),
                             location: "CEO office", joinURL: URL(string: "https://zoom.us/j/9?pwd=SECRET"), participation: .organizer)
        try await rig.service.observeMeetings([secret])
        let requests = try await delivered(rig, expecting: 3)
        let text = requests.map { "\($0)" }.joined()
        for leak in ["SECRET", "CEO office", "zoom.us", "Board", "3 comments", "priya"] {
            #expect(!text.contains(leak), "\(leak) reached a notification")
        }
        let saved = String(decoding: try JSONEncoder().encode(rig.store.load()), as: UTF8.self)
        #expect(!saved.contains("Offsite starts"))
    }
}
