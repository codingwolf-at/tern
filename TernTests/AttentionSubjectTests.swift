import Foundation
import Testing
@testable import Tern

/// Workstreams and meetings as attention subjects: one surfacing path, one Needs you selection,
/// and saved state from earlier versions still loading.
@Suite("Attention subjects")
@MainActor
struct AttentionSubjectTests {
    static let t0 = CalendarTests.t0
    static let work = CalendarTests.work
    static let home = CalendarTests.home

    private func at(_ minutes: Double) -> Date { Self.t0.addingTimeInterval(minutes * 60) }

    private func service(_ store: InMemoryTernStore = InMemoryTernStore(), clock: TestClock, active: TernContext = .professional) async throws -> IngestionService {
        let service = IngestionService(store: store, now: clock.now)
        try await service.start()
        try await service.setActiveContext(active)
        try await service.setContext(.professional, forOwner: "makeplane")
        try await service.setContext(.personal, forOwner: "atul")
        try await service.setContext(.professional, calendar: Self.work)
        try await service.setContext(.personal, calendar: Self.home)
        return service
    }

    /// My pull request with a failing check `minutes` after t0 (mine, high).
    private func failingPR(_ repository: String, _ number: Int, at minutes: Double = 1) -> [ObservedEvent] {
        let reference = ExternalReference.pullRequest(repository: repository, number: number)
        let pr = PullRequestReference(repository: repository, number: number)
        func event(_ kind: WorkEventKind, _ suffix: String, _ time: Double, _ metadata: [MetadataKey: String]) -> ObservedEvent {
            ObservedEvent(id: EventID(.github, "subject", "\(repository)#\(number)", suffix), source: .github, kind: kind,
                          timestamp: at(time), metadata: metadata, references: [reference], suggestedTitle: "PR \(number)", pullRequest: pr)
        }
        return [
            event(.pullRequestOpened, "opened", 0, [.role: "author", .actor: GH.me, .actorIsMe: "true"]),
            event(.ciFailed, "ci-\(minutes)", minutes, [.checkName: "build"]),
        ]
    }

    // MARK: One surfacing path

    @Test("Workstreams and meetings are recorded and notified by the same machinery, keyed by subject")
    func sharedMachinery() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock)
        let pr = try await service.ingest(failingPR("makeplane/plane", 1))
        let meeting = try await service.observeMeetings([CalendarTests.meeting("m", in: Self.work, startsIn: 10)])

        let workstreamID = try #require(await service.snapshot.workstreams.first?.id)
        #expect(pr.notifications.map(\.subjectID) == [SubjectID(workstream: workstreamID)])
        #expect(meeting.notifications.map(\.subjectID) == [SubjectID(meeting: "m")])
        // A workstream's subject ID is its workstream ID, unchanged.
        #expect(SubjectID(workstream: workstreamID).rawValue == workstreamID.rawValue)
        #expect(!SubjectID(workstream: workstreamID).isMeeting)
        #expect(Set(store.load().shownTransitions.map(\.subjectID)) == [SubjectID(workstream: workstreamID), SubjectID(meeting: "m")])

        // Duplicate prevention is the same for both: repeating the input is never news.
        for _ in 0..<3 {
            #expect(try await service.ingest(failingPR("makeplane/plane", 1)).notifications.isEmpty)
            #expect(try await service.observeMeetings([CalendarTests.meeting("m", in: Self.work, startsIn: 10)]).notifications.isEmpty)
        }
        #expect(store.load().notifications.count == 2)
    }

    @Test("surface: out-of-context live subjects are untouched, history imports are recorded silently, repeats aren't news")
    func surfaceRules() {
        var state = PersistedState()
        state.activeContext = .professional
        let transition = AttentionTransition(state: .needsAttention, owner: .me, attention: .high, causeID: EventID(.github, "x"), causeAt: at(1))
        let subject = SubjectID(rawValue: "github.pr:acme/web#1")
        let meeting = SubjectID(meeting: "m")

        for id in [subject, meeting] {
            #expect(state.surface(transition, of: id, in: .personal, headline: "h", mode: .live, isContextScoped: true, at: at(2)) == nil)
            #expect(state.surface(transition, of: id, in: .unclassified, headline: "h", mode: .live, isContextScoped: true, at: at(2)) == nil)
        }
        #expect(state.shownTransitions.isEmpty)

        #expect(state.surface(transition, of: subject, in: .professional, headline: "h", mode: .historyImport, isContextScoped: true, at: at(2)) == nil)
        #expect(state.shownTransitions.map(\.subjectID) == [subject])
        #expect(state.surface(transition, of: subject, in: .professional, headline: "h", mode: .live, isContextScoped: true, at: at(3)) == nil)

        let record = state.surface(transition, of: meeting, in: .professional, headline: "h", mode: .live, isContextScoped: true, at: at(3))
        #expect(record?.subjectID == meeting)
        #expect(state.wasNotified(transition, of: meeting))
        #expect(!state.wasNotified(transition, of: subject))
        #expect(state.surface(transition, of: meeting, in: .professional, headline: "h", mode: .live, isContextScoped: true, at: at(4)) == nil)
    }

    @Test("Context isolation holds for both subjects: inactive-context work and meetings neither notify nor leave records")
    func isolationForBoth() async throws {
        let clock = TestClock(Self.t0)
        let store = InMemoryTernStore()
        let service = try await service(store, clock: clock, active: .personal)
        #expect(try await service.ingest(failingPR("makeplane/plane", 1)).notifications.isEmpty)
        #expect(try await service.observeMeetings([CalendarTests.meeting("m", in: Self.work, startsIn: 10)]).notifications.isEmpty)
        #expect(store.load().shownTransitions.isEmpty)

        // Each surfaces in its own context once it is the active one.
        try await service.setActiveContext(.professional)
        #expect(store.load().notifications.map(\.subjectID) == [SubjectID(meeting: "m")])
        let next = try await service.ingest([failingPR("makeplane/plane", 1, at: 5)[1]])
        #expect(next.notifications.map(\.headline) == ["CI failed"])
    }

    // MARK: One Needs you selection

    /// A workstream whose evaluation says it's the user's turn for `reason`.
    private func workstream(_ id: String, _ reason: AttentionReason, changed minutesAgo: Double, now: Date) -> AttentionItem {
        var ws = Workstream(id: WorkstreamID(id), title: id)
        ws.evaluation = WorkstreamEvaluation(
            decision: AttentionDecision(shouldNotify: false, state: .needsAttention, nextOwner: .me, attention: .high, nextAction: nil, reason: reason),
            status: StatusLine(headline: id),
            lastMeaningfulChange: now.addingTimeInterval(-minutesAgo * 60),
            transition: .initial
        )
        return .workstream(ws)
    }

    private func meeting(_ id: String, startsIn minutes: Double, now: Date, participation: Meeting.Participation? = nil) -> AttentionItem {
        let meeting = Meeting(id: id, calendarID: Self.work, title: id, startsAt: now.addingTimeInterval(minutes * 60),
                              endsAt: now.addingTimeInterval((minutes + 30) * 60), participation: participation)
        return .meeting(MeetingEvaluator.evaluate(meeting, context: .professional, at: now))
    }

    private func ranked(_ items: [AttentionItem], primary: Set<String> = [], now: Date) -> [String] {
        PriorityModel.ranked(items, importance: { primary.contains($0.id.rawValue) ? .primary : .normal }, now: now)
            .map { $0.workstream?.id.rawValue ?? $0.meeting!.meeting.id }
    }

    @Test("Meetings rank with workstreams on one scale, neither dominating")
    func mixedRanking() {
        let now = at(0)
        // A meeting about to start beats stale work and a fresh review request…
        #expect(ranked([workstream("stale", .changesRequested, changed: 3 * 24 * 60, now: now), meeting("m", startsIn: 10, now: now)], now: now) == ["m", "stale"])
        #expect(ranked([workstream("review", .reviewRequested, changed: 5, now: now), meeting("m", startsIn: 10, now: now)], now: now) == ["m", "review"])
        // …but not a fresh change request, an agent waiting on input, or primary work.
        #expect(ranked([workstream("changes", .changesRequested, changed: 5, now: now), meeting("m", startsIn: 10, now: now)], now: now) == ["changes", "m"])
        #expect(ranked([workstream("agent", .agentNeedsInput, changed: 30, now: now), meeting("m", startsIn: 10, now: now)], now: now) == ["agent", "m"])
        #expect(ranked([workstream("review", .reviewRequested, changed: 5, now: now), meeting("m", startsIn: 10, now: now)], primary: ["review"], now: now) == ["review", "m"])
        // A meeting the user hasn't accepted ranks lower.
        #expect(ranked([workstream("review", .reviewRequested, changed: 5, now: now), meeting("t", startsIn: 10, now: now, participation: .tentative)], now: now) == ["review", "t"])
    }

    @Test("A meeting outside its window is no candidate; simultaneous meetings go soonest first")
    func meetingCandidates() {
        let now = at(0)
        let upcoming = meeting("later", startsIn: 40, now: now)
        #expect(upcoming.meeting?.needsAttentionNow == false)
        #expect(PriorityModel.priority(of: upcoming, importance: { _ in .normal }, now: now).score == 0)
        #expect(ranked([meeting("b", startsIn: 12, now: now), meeting("a", startsIn: 4, now: now), meeting("c", startsIn: 14, now: now)], now: now) == ["a", "b", "c"])
    }

    @Test("Workstream scores are unchanged by the shared selection")
    func workstreamScoresUnchanged() throws {
        let now = at(0)
        let item = workstream("w", .ciFailed, changed: 30, now: now)
        let ws = try #require(item.workstream)
        #expect(PriorityModel.priority(of: item, importance: { _ in .primary }, now: now) == PriorityModel.priority(of: ws, importance: .primary, now: now))
        #expect(PriorityModel.priority(of: ws, importance: .normal, now: now).score == 40 + 26 + 15)
    }

    @Test("Mixed selection is deterministic, whatever the input order")
    func deterministic() {
        let now = at(0)
        let items = [
            workstream("changes", .changesRequested, changed: 5, now: now),
            workstream("review", .reviewRequested, changed: 5, now: now),
            workstream("ci", .ciFailed, changed: 120, now: now),
            meeting("m1", startsIn: 3, now: now),
            meeting("m2", startsIn: 9, now: now, participation: .pending),
        ]
        let expected = ranked(items, now: now)
        #expect(expected == ["changes", "m1", "review", "ci", "m2"])
        for _ in 0..<20 {
            #expect(ranked(items.shuffled(), now: now) == expected)
        }
    }

    @Test("Needs you holds at most three across workstreams and meetings; the rest go to More; Up next never repeats them")
    func needsYouLimitAndUpNext() async throws {
        let clock = TestClock(Self.t0)
        let service = try await service(clock: clock)
        try await service.ingest(failingPR("makeplane/a", 1) + failingPR("makeplane/b", 2) + failingPR("makeplane/c", 3), mode: .historyImport)
        try await service.observeMeetings([
            CalendarTests.meeting("soon", in: Self.work, startsIn: 5),
            CalendarTests.meeting("tentative", in: Self.work, startsIn: 8, participation: .tentative),
            CalendarTests.meeting("later", in: Self.work, startsIn: 60),
        ])
        let model = AppModel(service: service)
        model.now = clock.now
        for _ in 0..<300 where !(model.workstreams.count == 3 && model.meetings.count == 3 && !model.contextRules.calendars.isEmpty) {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(model.attentionQueue.count == 5)
        #expect(model.needsYou.count == AppModel.needsYouLimit)
        #expect(model.more.count == 2)
        // Fresh CI failures (81, newer) tie the confirmed meeting (81); the tentative one (71) is last.
        #expect(model.needsYou.map(\.id) + model.more.map(\.id) == model.attentionQueue.map(\.id))
        #expect(model.attentionQueue.last?.meeting?.meeting.id == "tentative")

        // Up next is only what doesn't need action yet: never an item from Needs you or More.
        #expect(model.upNext?.meeting.id == "later")
        let queued = Set(model.attentionQueue.compactMap { $0.meeting?.meeting.id })
        #expect(!queued.contains("later"))
        #expect(model.meetingInProgress == nil)

        // Once a meeting starts it leaves the queue for Up next's "in progress".
        clock.advance(minutes: 6)
        try await service.observeMeetings([CalendarTests.meeting("soon", in: Self.work, startsIn: 5)])
        for _ in 0..<300 where model.meetingInProgress == nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.meetingInProgress?.meeting.id == "soon")
        #expect(!model.attentionQueue.contains { $0.meeting?.meeting.id == "soon" })
    }

    // MARK: Saved state from earlier versions

    private func temporaryStore(_ json: String) throws -> (JSONFileTernStore, URL) {
        let url = FileManager.default.temporaryDirectory.appending(path: "tern-\(UUID().uuidString)/state.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return (JSONFileTernStore(url: url), url)
    }

    /// State written before contexts, calendars and subjects existed: no active context, no
    /// context rules, importance `personal`, records keyed `workstreamID`, no `seen`, and an event
    /// of the removed `calendar.event.scheduled` kind.
    static let legacyState = #"""
    {
      "version": 1,
      "workstreams": [{
        "id": "github.pr:acme/web#1", "title": "PR 1",
        "pullRequest": {"repository": "acme/web", "number": 1},
        "events": [
          {"id": "github:pr:1:opened", "workstreamID": "github.pr:acme/web#1", "source": "github", "kind": "github.pr.opened",
           "timestamp": 0, "metadata": {"role": "author", "actor": "atul", "actorIsMe": "true"}},
          {"id": "github:pr:1:ci", "workstreamID": "github.pr:acme/web#1", "source": "github", "kind": "github.ci.failed",
           "timestamp": 60, "metadata": {"checkName": "build"}},
          {"id": "calendar:event:sync", "workstreamID": "github.pr:acme/web#1", "source": "calendar", "kind": "calendar.event.scheduled",
           "timestamp": 30, "metadata": {"title": "Sync", "startsAt": "2026-01-01T10:00:00Z"}}
        ]
      }],
      "links": [{"reference": {"kind": "github.pr", "value": "acme/web#1"}, "workstreamID": "github.pr:acme/web#1"}],
      "repositoryImportance": {"github.com/acme/web": "personal"},
      "shownTransitions": [{"workstreamID": "github.pr:acme/web#1",
        "transition": {"state": "needsAttention", "owner": "me", "attention": 3, "causeID": "github:pr:1:ci", "causeAt": 60}}],
      "notifications": [{"workstreamID": "github.pr:acme/web#1", "fingerprint": "needsAttention|me|3|github:pr:1:ci",
        "headline": "CI failed", "attention": 3, "createdAt": 61}]
    }
    """#

    @Test("State from before contexts, calendars and subjects loads, keeps its records, and doesn't re-notify")
    func legacyStateLoads() async throws {
        let (store, url) = try temporaryStore(Self.legacyState)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let state = try store.load()
        let subject = SubjectID(rawValue: "github.pr:acme/web#1")
        #expect(state.activeContext == .professional)
        #expect(state.contextRules == ContextRules())
        #expect(state.contextRules.calendars.isEmpty)
        #expect(state.repositoryImportance == ["github.com/acme/web": .lowPriority])
        #expect(state.shownTransitions.map(\.subjectID) == [subject])
        #expect(state.shownTransitions.first?.seen == ["needsAttention|me|3|github:pr:1:ci"])
        #expect(state.notifications.map(\.subjectID) == [subject])

        // The removed calendar event kind is simply ignored, and the old record still matches its
        // workstream: the same transition is not news again.
        let service = IngestionService(store: store, now: { GH.t0 }, scoping: .ignoringContexts)
        let workstream = try #require(try await service.start().workstreams.first)
        #expect(workstream.nextOwner == .me && workstream.status.headline == "CI failed")
        var reloaded = try store.load()
        #expect(reloaded.surface(workstream.evaluation.transition, of: workstream.subjectID, in: .professional, headline: "CI failed",
                                 mode: .live, isContextScoped: false, at: Self.t0) == nil)

        // Saving writes the new key; reading it back is lossless.
        try await service.setImportance(.normal, forRepository: "acme/web")
        let saved = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(saved.contains(#""subjectID":"github.pr:acme\/web#1""#))
        #expect(try store.load().notifications.map(\.subjectID) == [subject])
    }

    @Test("Partial state loads with defaults; corrupt state fails to load without being touched")
    func partialAndCorrupt() throws {
        let (partial, partialURL) = try temporaryStore(#"{"version": 1, "workstreams": [], "links": []}"#)
        defer { try? FileManager.default.removeItem(at: partialURL.deletingLastPathComponent()) }
        let state = try partial.load()
        #expect(state.shownTransitions.isEmpty && state.notifications.isEmpty && state.activeContext == .professional)

        let corrupt = #"{"version": 1, "workstreams": [{"id": 3"#
        let (store, url) = try temporaryStore(corrupt)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(throws: (any Error).self) { try store.load() }
        #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == corrupt)
    }

    @Test("The load-failure fallback is still context-scoped")
    func fallbackIsScoped() async throws {
        // What `AppModel.makeDefault` uses when the saved state can't be loaded.
        let fallback = IngestionService(store: InMemoryTernStore())
        #expect(try await fallback.start().isContextScoped)
    }

    @Test("The old calendar placeholder is gone: a workstream carries no meeting")
    func placeholderRemoved() {
        let labels = Mirror(reflecting: Workstream(id: WorkstreamID("w"), title: "w")).children.compactMap(\.label)
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("calendar") })
        #expect(WorkEventKind(rawValue: "calendar.event.scheduled").displayName == "calendar.event.scheduled")
    }
}
