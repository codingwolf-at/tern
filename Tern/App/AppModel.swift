import Foundation
import Observation
import os

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
         scenarioPlayer: ScenarioPlayer? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        self.calendar = calendar
        self.scenarioPlayer = scenarioPlayer
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        changes = continuation
        applyChanges(from: stream)
        observe()
    }
    #else
    init(service: IngestionService, github: GitHubAccount? = nil, plane: PlaneAccount? = nil, calendar: CalendarAccount? = nil) {
        self.service = service
        self.claudeHooks = ClaudeHookReceiver(service: service)
        self.github = github
        self.plane = plane
        self.calendar = calendar
        let (stream, continuation) = AsyncStream<Change>.makeStream()
        changes = continuation
        applyChanges(from: stream)
        observe()
    }
    #endif

    /// DEBUG builds run in memory with the mock scenario (set `TERN_MOCK=0` to start empty and
    /// see only real Claude Code sessions); release builds load persisted state.
    static func makeDefault() -> AppModel {
        // Import progress now lives in the persisted state; drop the old build-shared marker.
        UserDefaults.standard.removeObject(forKey: "github.importedLogins")
        let rules = WorkflowRules.load(from: .standard)
        #if DEBUG
        let service = IngestionService(store: InMemoryTernStore(), rules: rules)
        let useMock = ProcessInfo.processInfo.environment["TERN_MOCK"] != "0"
        return AppModel(
            service: service,
            github: GitHubAccount(ingestion: service),
            plane: PlaneAccount(ingestion: service),
            calendar: CalendarAccount(ingestion: service),
            scenarioPlayer: useMock ? ScenarioPlayer(service: service) : nil
        )
        #else
        do {
            let service = IngestionService(store: JSONFileTernStore(url: try JSONFileTernStore.defaultURL()), rules: rules)
            return AppModel(service: service, github: GitHubAccount(ingestion: service), plane: PlaneAccount(ingestion: service),
                            calendar: CalendarAccount(ingestion: service))
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

    func context(of workstream: Workstream) -> WorkstreamContext {
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

    /// Meetings inside their preparation window: they need the user now.
    var meetingsNeedingYou: [MeetingStatus] {
        scopedMeetings.filter(\.needsAttentionNow)
    }

    /// The next meeting that will claim attention, once it is close. One, not an agenda.
    var upNext: MeetingStatus? {
        scopedMeetings.first { $0.phase == .upcoming && MeetingEvaluator.canClaimAttention($0.meeting) }
    }

    /// A meeting under way, kept quietly so it can still be joined. Gone once it ends.
    var meetingInProgress: MeetingStatus? {
        scopedMeetings.first { $0.phase == .inProgress && MeetingEvaluator.canClaimAttention($0.meeting) }
    }

    /// The badge: workstreams that need the user plus meetings about to start.
    var needsYouCount: Int {
        attentionQueue.count + meetingsNeedingYou.count
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

    private func ranked(_ workstreams: [Workstream]) -> [Workstream] {
        PriorityModel.ranked(workstreams, importance: importance(of:), now: now())
    }

    /// Everything that warrants an interruption, best first. Muted repositories never interrupt.
    var attentionQueue: [Workstream] {
        ranked(scoped.filter { $0.needsAttentionNow && importance(of: $0) != .muted })
    }

    /// The few things worth dealing with now.
    var needsYou: [Workstream] {
        Array(attentionQueue.prefix(Self.needsYouLimit))
    }

    /// Lower-priority items that would also warrant attention, kept out of the way.
    var more: [Workstream] {
        Array(attentionQueue.dropFirst(Self.needsYouLimit))
            + ranked(scoped.filter { $0.needsAttentionNow && importance(of: $0) == .muted })
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
            // Calendar may have been read before ingestion was ready; read it again now.
            await self?.calendar?.service.refresh()
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
                }
            }
        }
    }

    private func report(_ error: any Error) {
        logger.error("Tern failed to load state: \(error)")
        errorMessage = "Couldn't load saved state"
    }
}
