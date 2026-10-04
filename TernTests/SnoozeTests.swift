import Foundation
import Testing
@testable import Tern

@Suite("Snooze", .serialized)
@MainActor
struct SnoozeTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Rig {
        let store: InMemoryTernStore
        let clock: TestClock
        let service: IngestionService
        let center: FakeNotificationCenter
        let model: AppModel
    }

    private func rig(store: InMemoryTernStore = InMemoryTernStore(), clock: TestClock = TestClock(Date(timeIntervalSince1970: 1_800_000_000)),
                     active: TernContext = .professional) async throws -> Rig {
        let service = IngestionService(store: store, now: clock.now)
        try await service.start()
        try await service.setActiveContext(active)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.setContext(.personal, forOwner: "atul")
        try await service.setContext(.professional, calendar: CalendarTests.work)
        let center = FakeNotificationCenter()
        let model = AppModel(service: service, notifications: NotificationDelivery(center: center))
        model.now = clock.now
        let expected = await service.snapshot
        try await settle { model.workstreams.count == expected.workstreams.count && model.contextRules == expected.contextRules && model.snoozes == expected.snoozes }
        return Rig(store: store, clock: clock, service: service, center: center, model: model)
    }

    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func delivered(_ rig: Rig, expecting count: Int) async throws -> [NotificationRequest] {
        try await settle { rig.center.requests.count >= count }
        try await Task.sleep(for: .milliseconds(50))
        return rig.center.requests
    }

    /// My PR with a failing check at `minutes` (mine, high).
    private func failing(_ repository: String, _ number: Int, at minutes: Double = 1, check: String = "build") -> [ObservedEvent] {
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number, url: URL(string: "https://github.com/\(repository)/pull/\(number)"))
        return [
            ObservedEvent(id: EventID(.github, "snz", repository, "\(number)", "opened"), source: .github, kind: .pullRequestOpened, timestamp: GH.at(0),
                          metadata: [.role: "author", .actor: GH.me, .actorIsMe: "true"], references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr),
            ObservedEvent(id: EventID(.github, "snz", repository, "\(number)", check, "\(minutes)"), source: .github, kind: .ciFailed, timestamp: GH.at(minutes),
                          metadata: [.checkName: check], references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr),
        ]
    }

    private func item(_ rig: Rig, number: Int) throws -> AttentionItem {
        let workstream = try #require(rig.model.workstreams.first(where: { $0.pullRequest?.number == number }))
        return .workstream(workstream)
    }

    // MARK: Basics

    @Test("Snoozing takes an item out of Needs you and the badge without touching its state; unsnooze brings it back")
    func basics() async throws {
        let rig = try await rig()
        try await rig.service.ingest(failing("makeplane/plane", 1) + failing("makeplane/plane", 2) + failing("makeplane/plane", 3), mode: .historyImport)
        try await settle { rig.model.workstreams.count == 3 }
        #expect(rig.model.attentionQueue.count == 3)

        let first = try item(rig, number: 1)
        let evaluation = first.workstream?.evaluation
        #expect(rig.model.canSnooze(first))
        rig.model.snooze(first, for: .thirtyMinutes)
        #expect(rig.model.attentionQueue.count == 2) // the badge
        #expect(!rig.model.needsYou.contains { $0.id == first.id } && !rig.model.more.contains { $0.id == first.id })
        #expect(rig.model.snoozed.map(\.id) == [first.id])
        #expect(rig.model.snooze(of: first)?.until == Self.t0.addingTimeInterval(30 * 60))
        // The work itself is exactly as it was.
        #expect(rig.model.workstreams.first { $0.subjectID == first.id }?.evaluation == evaluation)
        #expect(rig.model.workstreams.first { $0.subjectID == first.id }?.needsAttentionNow == true)

        for n in [2, 3] { rig.model.snooze(try item(rig, number: n), for: .oneHour) }
        #expect(rig.model.attentionQueue.isEmpty)

        rig.model.unsnooze(first)
        #expect(rig.model.attentionQueue.map(\.id) == [first.id])
        await rig.model.changesSaved()
        #expect(rig.store.load().snoozes.count == 2)
    }

    @Test("Only items that claim attention, in a classified context, can be snoozed")
    func eligibility() async throws {
        let rig = try await rig()
        let waiting = [ObservedEvent(id: EventID(.github, "snz", "w", "opened"), source: .github, kind: .pullRequestOpened, timestamp: GH.at(0),
                                     metadata: [.role: "author", .actor: GH.me, .actorIsMe: "true"], references: [.pullRequest(repository: "makeplane/plane", number: 9)],
                                     pullRequest: PullRequestReference(repository: "makeplane/plane", number: 9)),
                       ObservedEvent(id: EventID(.github, "snz", "w", "review"), source: .github, kind: .reviewRequested, timestamp: GH.at(1),
                                     metadata: [.reviewer: "priya"], references: [.pullRequest(repository: "makeplane/plane", number: 9)])]
        try await rig.service.ingest(waiting + failing("someone/else", 4) + failing("makeplane/muted", 5), mode: .historyImport)
        try await rig.service.setImportance(.muted, forRepository: "makeplane/muted")
        try await settle { rig.model.workstreams.count == 3 && !rig.model.importance.isEmpty }
        for n in [9, 4, 5] {
            #expect(!rig.model.canSnooze(try item(rig, number: n)))
        }
    }

    // MARK: Durations

    @Test("30 minutes, 1 hour, 3 hours, and tomorrow at 9:00 local time")
    func durations() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let afternoon = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: 14, minute: 20)))
        #expect(SnoozeOption.thirtyMinutes.until(from: afternoon) == afternoon.addingTimeInterval(1800))
        #expect(SnoozeOption.oneHour.until(from: afternoon) == afternoon.addingTimeInterval(3600))
        #expect(SnoozeOption.threeHours.until(from: afternoon) == afternoon.addingTimeInterval(3 * 3600))
        let tomorrowNine = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 16, hour: 9)))
        for hour in [1, 8, 9, 14, 23] {
            let from = try #require(calendar.date(from: DateComponents(year: 2027, month: 1, day: 15, hour: hour, minute: 30)))
            #expect(SnoozeOption.tomorrowMorning.until(from: from, calendar: calendar) == tomorrowNine)
        }
    }

    // MARK: Expiry and notifications

    @Test("Suppressed before expiry, eligible exactly at it; changes during the snooze notify once at the end, never again")
    func expiryAndNotifications() async throws {
        let store = InMemoryTernStore()
        let clock = TestClock(Self.t0)
        let rig = try await rig(store: store, clock: clock)
        try await rig.service.ingest(failing("makeplane/plane", 1))
        #expect(try await delivered(rig, expecting: 1).count == 1)
        let snoozedItem = try item(rig, number: 1)
        rig.model.snooze(snoozedItem, for: .thirtyMinutes)
        await rig.model.changesSaved()
        let shownBefore = store.load().shownTransitions

        // Source events during the snooze: no notifications, nothing recorded as seen.
        for minute in [5.0, 6, 7] {
            clock.set(GH.at(minute))
            #expect(try await rig.service.ingest([failing("makeplane/plane", 1, at: minute, check: "lint")[1]]).notifications.isEmpty)
        }
        #expect(store.load().shownTransitions == shownBefore)
        #expect(try await delivered(rig, expecting: 1).count == 1)

        clock.set(Self.t0.addingTimeInterval(30 * 60 - 1))
        #expect(rig.model.isSnoozed(snoozedItem))
        try await rig.service.expireSnoozes()
        #expect(store.load().snoozes.count == 1) // not yet

        clock.set(Self.t0.addingTimeInterval(30 * 60)) // exactly at expiry
        #expect(!rig.model.isSnoozed(snoozedItem))
        try await rig.service.expireSnoozes()
        #expect(store.load().snoozes.isEmpty)
        let afterExpiry = try await delivered(rig, expecting: 2)
        #expect(afterExpiry.count == 2) // the change that happened during the snooze, once
        try await settle { rig.model.attentionQueue.count == 1 }

        try await rig.service.expireSnoozes()
        #expect(try await delivered(rig, expecting: 2).count == 2)

        // Relaunch: nothing to repeat.
        let relaunched = try await self.rig(store: store, clock: clock)
        try await relaunched.service.expireSnoozes()
        #expect(try await delivered(relaunched, expecting: 0).isEmpty)
    }

    @Test("A snooze that ends with nothing new is quiet; the item simply returns")
    func quietExpiry() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        try await rig.service.ingest(failing("makeplane/plane", 1))
        try await settle { rig.model.attentionQueue.count == 1 }
        rig.model.snooze(try item(rig, number: 1), for: .oneHour)
        await rig.model.changesSaved()
        clock.advance(minutes: 61)
        try await rig.service.expireSnoozes()
        try await settle { rig.model.attentionQueue.count == 1 }
        #expect(try await delivered(rig, expecting: 1).count == 1) // only the original one
    }

    @Test("Unsnoozing early gives back normal evaluation at once, notifying only what changed meanwhile")
    func unsnoozeEarly() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        try await rig.service.ingest(failing("makeplane/plane", 1))
        try await settle { rig.model.attentionQueue.count == 1 }
        let snoozed = try item(rig, number: 1)
        rig.model.snooze(snoozed, for: .threeHours)
        await rig.model.changesSaved()
        clock.set(GH.at(10))
        try await rig.service.ingest([failing("makeplane/plane", 1, at: 10, check: "lint")[1]])
        #expect(try await delivered(rig, expecting: 1).count == 1)
        rig.model.unsnooze(snoozed)
        #expect(try await delivered(rig, expecting: 2).count == 2)
    }

    // MARK: Contexts

    @Test("Snoozes belong to a context: a Personal snooze never hides the same subject in Professional")
    func contexts() async throws {
        let rig = try await rig(active: .personal)
        try await rig.service.ingest(failing("atul/blog", 1), mode: .historyImport)
        try await settle { rig.model.attentionQueue.count == 1 }
        let personal = try item(rig, number: 1)
        rig.model.snooze(personal, for: .oneHour)
        await rig.model.changesSaved()
        #expect(rig.store.load().snoozes.map(\.context) == [.personal])
        #expect(rig.model.attentionQueue.isEmpty)

        // The same repository filed under Professional is a different context: not snoozed there.
        rig.model.setContext(.professional, forOwner: "atul")
        rig.model.setActiveContext(.professional)
        #expect(rig.model.attentionQueue.map(\.id) == [personal.id])
        #expect(!rig.model.isSnoozed(personal))
    }

    // MARK: Calendar

    @Test("A snoozed meeting that starts before the snooze ends doesn't come back as starting soon")
    func meetingStarts() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        let meeting = CalendarTests.meeting("m", in: CalendarTests.work, startsIn: 10)
        try await rig.service.observeMeetings([meeting])
        try await settle { rig.model.attentionQueue.count == 1 }
        rig.model.snooze(try #require(rig.model.attentionQueue.first), for: .thirtyMinutes)
        await rig.model.changesSaved()
        #expect(rig.model.attentionQueue.isEmpty)

        clock.advance(minutes: 31)
        try await rig.service.observeMeetings([meeting])
        try await rig.service.expireSnoozes()
        try await settle { rig.model.meetingInProgress != nil }
        #expect(rig.model.attentionQueue.isEmpty)
        #expect(try await delivered(rig, expecting: 1).count == 1) // only the original
    }

    @Test("A meeting still in its window comes back at expiry without a repeat alert; a cancelled one doesn't come back")
    func meetingReturnsOrNot() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        let soon = CalendarTests.meeting("soon", in: CalendarTests.work, startsIn: 14)
        let cancelled = CalendarTests.meeting("cancelled", in: CalendarTests.work, startsIn: 12)
        try await rig.service.observeMeetings([soon, cancelled])
        try await settle { rig.model.attentionQueue.count == 2 }
        for item in rig.model.attentionQueue { rig.model.snooze(item, for: .thirtyMinutes) }
        await rig.model.changesSaved()

        // Snoozes end early by hand (the 30-minute clock would outlast both meetings).
        try await rig.service.observeMeetings([soon]) // "cancelled" was cancelled
        clock.advance(minutes: 2)
        for item in rig.model.snoozed { rig.model.unsnooze(item) }
        await rig.model.changesSaved()
        try await settle { rig.model.attentionQueue.count == 1 }
        #expect(rig.model.attentionQueue.first?.meeting?.meeting.id == "soon")
        #expect(try await delivered(rig, expecting: 2).count == 2) // the two originals only
    }

    @Test("A moved meeting is a new occurrence, so the old one's snooze doesn't follow it")
    func movedMeeting() async throws {
        let clock = TestClock(Self.t0)
        let rig = try await rig(clock: clock)
        try await rig.service.observeMeetings([CalendarTests.meeting("m@10", in: CalendarTests.work, startsIn: 10)])
        try await settle { rig.model.attentionQueue.count == 1 }
        rig.model.snooze(try #require(rig.model.attentionQueue.first), for: .oneHour)
        await rig.model.changesSaved()
        try await rig.service.observeMeetings([CalendarTests.meeting("m@12", in: CalendarTests.work, startsIn: 12)])
        try await settle { rig.model.attentionQueue.count == 1 }
        #expect(rig.model.attentionQueue.first?.meeting?.meeting.id == "m@12")
    }

    // MARK: Persistence

    @Test("Snoozes survive a restart, expired ones are cleaned up, and rapid changes save in order")
    func persistence() async throws {
        let store = InMemoryTernStore()
        let clock = TestClock(Self.t0)
        let rig = try await rig(store: store, clock: clock)
        try await rig.service.ingest(failing("makeplane/plane", 1) + failing("makeplane/plane", 2), mode: .historyImport)
        try await settle { rig.model.workstreams.count == 2 }
        let one = try item(rig, number: 1), two = try item(rig, number: 2)

        // Rapid changes, saved strictly in the order made.
        rig.model.snooze(one, for: .oneHour)
        rig.model.unsnooze(one)
        rig.model.snooze(two, for: .oneHour)
        rig.model.unsnooze(two)
        rig.model.snooze(two, for: .threeHours)
        await rig.model.changesSaved()
        #expect(store.load().snoozes.map(\.subjectID) == [two.id])
        #expect(store.load().snoozes.first?.until == Self.t0.addingTimeInterval(3 * 3600))

        let relaunched = IngestionService(store: store, now: clock.now)
        #expect(try await relaunched.start().snoozes.map(\.subjectID) == [two.id])
        clock.advance(minutes: 181)
        try await relaunched.expireSnoozes()
        #expect(store.load().snoozes.isEmpty)
    }

    @Test("State saved before snoozes existed still loads")
    func legacyState() throws {
        let json = #"{"version": 1, "workstreams": [], "links": [], "shownTransitions": [], "notifications": []}"#
        #expect(try JSONDecoder().decode(PersistedState.self, from: Data(json.utf8)).snoozes.isEmpty)
    }
}
