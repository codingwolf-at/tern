import AppKit
import Foundation
import Observation
import os
import UserNotifications

/// UI-facing state. Mirrors snapshots published by `IngestionService` and groups
/// workstreams by whose turn it is. It does not ingest or evaluate anything itself.
@MainActor
@Observable
final class AppModel {
    private(set) var workstreams: [Workstream] = []
    /// Associations Tern declined to make (diagnostics only).
    private(set) var unresolvedAssociations: [AssociationIssue] = []
    private(set) var errorMessage: String?
    /// Entry point for Claude Code hook events. Owned here so diagnostics can observe it.
    let claudeHooks: ClaudeHookReceiver
    /// GitHub connection and sync status; `nil` when GitHub isn't part of this model (tests).
    let github: GitHubAccount?
    /// Plane connection and sync status; `nil` when Plane isn't part of this model (tests).
    let plane: PlaneAccount?
    /// Calendar access and classification; `nil` when Calendar isn't part of this model (tests).
    let calendar: CalendarAccount?
    /// macOS notification permission and delivery; `nil` when not part of this model (tests).
    let notifications: NotificationDelivery?
    /// The subject a clicked notification was about; the panel expands it when shown.
    var focusedSubject: SubjectID?
    /// Kept alive here: the notification center holds its delegate weakly.
    private var notificationResponder: NotificationResponder?

    #if DEBUG
    /// Present only when running the mock scenario.
    let scenarioPlayer: ScenarioPlayer?
    #endif

    private let service: IngestionService
    private let logger = Logger(subsystem: "so.plane.tern", category: "app")

    typealias Change = @Sendable (IngestionService) async throws -> Void
    /// The user's changes (context, classification, importance), saved one at a time in the
    /// order they were made. Separate tasks could run out of order and save an older choice last.
    private let changes: AsyncStream<Change>.Continuation
    /// Changes made here but not yet saved. Until they are, snapshots (which may predate them)
    /// don't overwrite what the user just chose.
    private var pendingChanges = 0

    #if DEBUG
    init(service: IngestionService, github: GitHubAccount? = nil, plane: PlaneAccount? = nil, calendar: CalendarAccount? = nil,
         notifications: NotificationDelivery? = nil, scenarioPlayer: ScenarioPlayer? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        self.calendar = calendar
        self.notifications = notifications
        self.scenarioPlayer = scenarioPlayer
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        changes = continuation
        applyChanges(from: stream)
        observe()
    }
    #else
    init(service: IngestionService, github: GitHubAccount? = nil, plane: PlaneAccount? = nil, calendar: CalendarAccount? = nil,
         notifications: NotificationDelivery? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        self.calendar = calendar
        self.notifications = notifications
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        changes = continuation
        applyChanges(from: stream)
        observe()
    }
    #endif

    /// DEBUG builds run in memory with the mock scenario (set `TERN_MOCK=0` to start empty and
    /// see only real Claude Code sessions, or `TERN_PERSIST=1` to start without the mock and keep
    /// state across launches in `state-debug.json`); release builds load persisted state.
    static func makeDefault() -> AppModel {
        // Import progress now lives in the persisted state; drop the old build-shared marker.
        UserDefaults.standard.removeObject(forKey: "github.importedLogins")
        let rules = WorkflowRules.load(from: .standard)
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        let persists = environment["TERN_PERSIST"] == "1"
        let store: any TernStore = if persists, let url = try? JSONFileTernStore.defaultURL(fileName: "state-debug.json") {
            JSONFileTernStore(url: url)
        } else {
            InMemoryTernStore()
        }
        let service = IngestionService(store: store, rules: rules)
        let useMock = environment["TERN_MOCK"] != "0" && !persists
        return AppModel(
            service: service,
            github: GitHubAccount(ingestion: service),
            plane: PlaneAccount(ingestion: service),
            calendar: CalendarAccount(ingestion: service),
            notifications: NotificationDelivery(center: SystemNotificationCenter()),
            scenarioPlayer: useMock ? ScenarioPlayer(service: service) : nil
        ).receivingNotificationClicks()
        #else
        do {
            let service = IngestionService(store: JSONFileTernStore(url: try JSONFileTernStore.defaultURL()), rules: rules)
            return AppModel(service: service, github: GitHubAccount(ingestion: service), plane: PlaneAccount(ingestion: service),
                            calendar: CalendarAccount(ingestion: service),
                            notifications: NotificationDelivery(center: SystemNotificationCenter()))
                .receivingNotificationClicks()
        } catch {
            let model = AppModel(service: IngestionService(store: InMemoryTernStore()))
            model.report(error)
            return model
        }
        #endif
    }

    // MARK: - Context

    private(set) var activeContext: TernContext = .professional
    private(set) var contextRules = ContextRules()
    /// Whether work is limited to the active context: always in the app, off only for
    /// Debug-built tests that ignore contexts.
    private(set) var isContextScoped = true

    func context(of workstream: Workstream) -> SubjectContext {
        contextRules.context(of: workstream)
    }

    /// The workstreams that take part in the active context. Every section, the ranking and the
    /// badge are computed from these, so switching context recalculates everything.
    var scoped: [Workstream] {
        guard isContextScoped else { return workstreams }
        return workstreams.filter { context(of: $0).isIn(activeContext) }
    }

    /// Open work that belongs to neither context yet, waiting for the user to classify it.
    var unclassified: [Workstream] {
        guard isContextScoped else { return [] }
        return workstreams.filter { $0.state != .complete && context(of: $0) == .unclassified }
    }

    /// Switches context. The panel and badge update at once; the choice is saved.
    func setActiveContext(_ context: TernContext) {
        activeContext = context
        save { try await $0.setActiveContext(context) }
    }

    /// Classifies a GitHub owner's repositories, or with `repository`, just that one; `nil`
    /// clears the rule. Affected work moves at once; the rule is saved.
    func setContext(_ context: TernContext?, forOwner owner: String? = nil, repository: String? = nil) {
        if let owner { contextRules.set(context, forOwner: owner) }
        if let repository { contextRules.set(context, forRepository: repository) }
        save { try await $0.setContext(context, forOwner: owner, repository: repository) }
    }

    /// Files a macOS calendar under Personal or Professional; `nil` makes it unclassified. Its
    /// meetings move at once, and Calendar is read again so a newly classified one appears.
    func setContext(_ context: TernContext?, forCalendar calendarID: String) {
        contextRules.set(context, forCalendar: calendarID)
        let sync = calendar?.service
        save { service in
            try await service.setContext(context, calendar: calendarID)
            await sync?.refresh()
        }
    }

    // MARK: - Meetings

    /// Meetings from classified calendars, both contexts, as of the last Calendar refresh.
    private(set) var meetings: [MeetingStatus] = []

    /// The active context's meetings. Unclassified calendars never get this far.
    var scopedMeetings: [MeetingStatus] {
        guard isContextScoped else { return meetings }
        return meetings.filter { contextRules.context(forCalendar: $0.meeting.calendarID).isIn(activeContext) }
    }

    /// Up next: useful upcoming context that doesn't need action yet. Never a meeting that is
    /// already a Needs you candidate. The next meeting that will claim attention once it is
    /// close — one, not an agenda.
    var upNext: MeetingStatus? {
        scopedMeetings.first { $0.phase == .upcoming && MeetingEvaluator.canClaimAttention($0.meeting) }
    }

    /// A meeting under way, kept quietly so it can still be joined. Gone once it ends.
    var meetingInProgress: MeetingStatus? {
        scopedMeetings.first { $0.phase == .inProgress && MeetingEvaluator.canClaimAttention($0.meeting) }
    }

    // MARK: - Queue

    /// At most this many items interrupt at the top of the panel.
    static let needsYouLimit = 3
    /// Waiting items shown before the rest collapse.
    static let waitingLimit = 4

    private(set) var importance: [String: RepositoryImportance] = [:]
    /// The clock used for recency and "today"; injectable for tests.
    var now: @Sendable () -> Date = { .now }

    func importance(of workstream: Workstream) -> RepositoryImportance {
        workstream.repositoryKey.flatMap { importance[$0] } ?? .normal
    }

    func priority(of workstream: Workstream) -> Priority {
        PriorityModel.priority(of: workstream, importance: importance(of: workstream), now: now())
    }

    func priority(of item: AttentionItem) -> Priority {
        PriorityModel.priority(of: item, importance: importance(of:), now: now())
    }

    private func ranked(_ workstreams: [Workstream]) -> [Workstream] {
        PriorityModel.ranked(workstreams, importance: importance(of:), now: now())
    }

    private func ranked(_ items: [AttentionItem]) -> [AttentionItem] {
        PriorityModel.ranked(items, importance: importance(of:), now: now())
    }

    /// Everything in the active context that warrants an interruption, best first: workstreams
    /// whose turn is the user's, and meetings inside their preparation window, on one ranking.
    /// Muted repositories never interrupt. Its size is the badge.
    var attentionQueue: [AttentionItem] {
        ranked(unsnoozedCandidates.filter { !isSnoozed($0) })
    }

    /// Everything that would claim attention right now, before snoozes are applied.
    private var unsnoozedCandidates: [AttentionItem] {
        scoped.filter { $0.needsAttentionNow && importance(of: $0) != .muted }.map(AttentionItem.workstream)
            + scopedMeetings.filter(\.needsAttentionNow).map(AttentionItem.meeting)
    }

    // MARK: - Snooze

    /// Active and not-yet-cleaned-up snoozes, mirrored from the service.
    private(set) var snoozes: [Snooze] = []
    private var snoozeExpiry: Task<Void, Never>?

    private func subjectContext(of item: AttentionItem) -> SubjectContext {
        switch item {
        case .workstream(let workstream): context(of: workstream)
        case .meeting(let meeting): meeting.context
        }
    }

    /// The snooze keeping `item` out of attention right now, if any. Applied after attention is
    /// decided: the item's state, owner, attention and ranking are untouched.
    func snooze(of item: AttentionItem) -> Snooze? {
        snoozes.active(for: item.id, in: subjectContext(of: item), at: now())
    }

    func isSnoozed(_ item: AttentionItem) -> Bool { snooze(of: item) != nil }

    /// Items that need the user but are snoozed, soonest back first. Out of Needs you, More and
    /// the badge until then.
    var snoozed: [AttentionItem] {
        unsnoozedCandidates
            .compactMap { item in snooze(of: item).map { (item, $0.until) } }
            .sorted { ($0.1, $0.0.id) < ($1.1, $1.0.id) }
            .map(\.0)
    }

    /// Only an item that currently claims attention, in a classified context, can be snoozed.
    func canSnooze(_ item: AttentionItem) -> Bool {
        unsnoozedCandidates.contains { $0.id == item.id } && subjectContext(of: item) != .unclassified
    }

    /// "Not now": hides the item from Needs you, More, the badge and notifications until the
    /// snooze ends. Saved in order with the user's other changes.
    func snooze(_ item: AttentionItem, for option: SnoozeOption, calendar: Calendar = .current) {
        guard canSnooze(item), let context = TernContext(subjectContext(of: item)) else { return }
        setSnooze(item.id, context: context, until: option.until(from: now(), calendar: calendar))
    }

    /// Ends the snooze now; the item's current attention applies again at once.
    func unsnooze(_ item: AttentionItem) {
        guard let snooze = snoozes.first(where: { $0.subjectID == item.id && subjectContext(of: item).isIn($0.context) }) else { return }
        setSnooze(item.id, context: snooze.context, until: nil)
    }

    private func setSnooze(_ subject: SubjectID, context: TernContext, until: Date?) {
        snoozes.removeAll { $0.subjectID == subject && $0.context == context }
        if let until { snoozes.append(Snooze(subjectID: subject, context: context, until: until)) }
        scheduleSnoozeExpiry()
        save { try await $0.setSnooze(subject, context: context, until: until) }
    }

    /// One timer for the earliest snooze end; the service expires everything due at once.
    private func scheduleSnoozeExpiry() {
        snoozeExpiry?.cancel()
        guard let next = snoozes.map(\.until).min() else { return }
        let delay = max(0, next.timeIntervalSince(now()))
        snoozeExpiry = Task { [service] in
            try? await Task.sleep(for: .seconds(delay + 0.5))
            guard !Task.isCancelled else { return }
            try? await service.expireSnoozes()
        }
    }

    /// The few things worth dealing with now.
    var needsYou: [AttentionItem] {
        Array(attentionQueue.prefix(Self.needsYouLimit))
    }

    /// Lower-priority items that would also warrant attention, kept out of the way.
    var more: [AttentionItem] {
        Array(attentionQueue.dropFirst(Self.needsYouLimit))
            + ranked(scoped.filter { $0.needsAttentionNow && importance(of: $0) == .muted }).map(AttentionItem.workstream)
    }

    /// Someone else (a reviewer, CI, an author) owes the next step.
    var waiting: [Workstream] {
        ranked(scoped.filter { [.reviewer, .ci, .external].contains($0.nextOwner) && $0.state != .complete })
    }

    /// An agent is working on it right now.
    var active: [Workstream] {
        ranked(scoped.filter { $0.nextOwner == .agent && $0.state != .complete })
    }

    /// Yours, but nothing to interrupt for: drafts, PRs without reviewers, re-request nudges.
    var yourWork: [Workstream] {
        ranked(scoped.filter { $0.nextOwner == .me && !$0.needsAttentionNow && $0.state != .complete })
    }

    /// Open work nobody is moving: e.g. a Plane item with no pull request or session yet.
    var idle: [Workstream] {
        ranked(scoped.filter { $0.nextOwner == .none && $0.state != .complete })
    }

    /// Finished today. Older completed work stays in history but out of the panel.
    var doneToday: [Workstream] {
        let calendar = Calendar.current
        let today = now()
        return scoped.filter { workstream in
            guard workstream.state == .complete, let changed = workstream.lastMeaningfulChange else { return false }
            return calendar.isDate(changed, inSameDayAs: today)
        }
    }

    /// Marks how much a repository matters. Saved with Tern's state.
    func setImportance(_ value: RepositoryImportance, for workstream: Workstream) {
        guard let repository = workstream.pullRequest?.repository else { return }
        importance[RepositoryImportance.key(forRepository: repository)] = value == .normal ? nil : value
        save { try await $0.setImportance(value, forRepository: repository) }
    }

    // MARK: - Saving changes

    private func save(_ change: @escaping Change) {
        pendingChanges += 1
        changes.yield(change)
    }

    /// Saves changes strictly in order, on one task.
    private func applyChanges(from stream: AsyncStream<Change>) {
        Task { [weak self, service] in
            for await change in stream {
                do {
                    try await change(service)
                } catch {
                    self?.logger.error("Couldn't save a change: \(error)")
                }
                self?.pendingChanges -= 1
            }
        }
    }

    /// Waits until every change made so far is saved.
    func changesSaved() async {
        while pendingChanges > 0 { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: - Notifications

    /// Hands every notification ingestion surfaces to macOS delivery, in order. Starts once
    /// ingestion has loaded; anything surfaced earlier waits in the stream.
    private func deliverNotifications() {
        guard let notifications else { return }
        Task { [service, notifications] in
            await notifications.refresh()
            for await payload in service.deliveries {
                await notifications.deliver(payload)
            }
        }
    }

    /// Makes Tern the notification center's delegate, so clicks come back here. Only for the
    /// app's own model; must happen before launch finishes to catch a click that launched Tern.
    func receivingNotificationClicks() -> AppModel {
        let responder = NotificationResponder { [weak self] response in self?.handle(response) }
        notificationResponder = responder
        UNUserNotificationCenter.current().delegate = responder
        return self
    }

    /// A click brings Tern forward and points at the subject. Join opens the meeting's own link,
    /// and only when the user chose Join. Neither changes the subject's state.
    func handle(_ response: NotificationResponder.Response) {
        switch response {
        case .join(let subject):
            if let meeting = meetings.first(where: { $0.meeting.subjectID == subject }),
               let join = actions(for: .meeting(meeting)).primary {
                perform(join)
            } else {
                focus(subject)
            }
        case .open(let subject):
            focus(subject)
        }
    }

    private func focus(_ subject: SubjectID) {
        focusedSubject = subject
        MenuBarPanel.shared.show()
    }

    // MARK: - Actions

    /// Opens destinations; replaceable in tests so no browser is launched.
    var router: any ActionRouter = SystemActionRouter()

    /// Where an item's next move happens, if Tern knows a real destination for it.
    func actions(for item: AttentionItem) -> ItemActions {
        let subjectContext = switch item {
        case .workstream(let workstream): context(of: workstream)
        case .meeting(let meeting): meeting.context
        }
        return ActionResolver.actions(for: item, context: subjectContext)
    }

    /// Takes the user to an action's destination. Changes nothing in Tern: the work stays as it
    /// is until the source system reports what the user did there. A target from outside the
    /// active context is refused, so a stale row can't open the other context's work.
    @discardableResult
    func perform(_ target: ActionTarget) -> Bool {
        guard !isContextScoped || target.context.isIn(activeContext) else { return false }
        router.open(target.url)
        return true
    }

    // MARK: - Service

    private func observe() {
        Task { [weak self, service] in
            do {
                try await service.start()
            } catch {
                self?.report(error)
                return
            }
            #if DEBUG
            await self?.scenarioPlayer?.seed()
            #endif
            // Calendar reports into ingestion, so it starts only once ingestion is ready.
            await self?.calendar?.service.start()
            // Snoozes that ran out while Tern wasn't running end now.
            try? await service.expireSnoozes()
            self?.deliverNotifications()
            for await snapshot in service.updates {
                guard let self else { return }
                self.workstreams = snapshot.workstreams
                self.unresolvedAssociations = snapshot.unresolvedAssociations
                self.meetings = snapshot.meetings
                self.isContextScoped = snapshot.isContextScoped
                // A snapshot taken before the user's latest changes were saved would undo them.
                if self.pendingChanges == 0 {
                    self.importance = snapshot.repositoryImportance
                    self.activeContext = snapshot.activeContext
                    self.contextRules = snapshot.contextRules
                    if self.snoozes != snapshot.snoozes {
                        self.snoozes = snapshot.snoozes
                        self.scheduleSnoozeExpiry()
                    }
                }
            }
        }
    }

    private func report(_ error: any Error) {
        logger.error("Tern failed to load state: \(error)")
        errorMessage = "Couldn't load saved state"
    }
}
