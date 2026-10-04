import Foundation

/// How newly observed events should be treated for notification purposes.
enum IngestMode: Sendable {
    /// Events are happening now; new transitions may notify.
    case live
    /// Backfill of older history (e.g. first sync). Updates state silently and records
    /// the resulting transitions as already shown.
    case historyImport
}

struct IngestReport: Hashable, Sendable {
    var accepted: [EventID] = []
    /// Events whose ID was already seen, either earlier or within the same batch.
    var duplicates: [EventID] = []
    /// Events that could not be linked: no references, or no match for an event
    /// that is not allowed to start a workstream.
    var unlinked: [EventID] = []
    var createdWorkstreams: [WorkstreamID] = []
    var notifications: [NotificationRecord] = []
    var unresolvedAssociations: [AssociationIssue] = []
}

/// What the UI renders.
struct TernSnapshot: Hashable, Sendable {
    var workstreams: [Workstream] = []
    var notifications: [NotificationRecord] = []
    var unresolvedAssociations: [AssociationIssue] = []
    var repositoryImportance: [String: RepositoryImportance] = [:]
    var activeContext: TernContext = .professional
    var contextRules = ContextRules()
    /// Meetings from classified calendars, both contexts, evaluated at the last refresh. Never
    /// persisted. Unclassified calendars' meetings are never here.
    var meetings: [MeetingStatus] = []
    /// Whether work is limited to the active context. Always in the app; only Debug-built
    /// tests can turn it off (see `ContextScoping.ignoringContexts`).
    var isContextScoped = true
}

/// Which work may notify and is shown.
enum ContextScoping: Sendable, Equatable {
    /// Only the active Personal/Professional context's work. The app always uses this.
    case activeContext
    #if DEBUG
    /// Every workstream, contexts ignored. Lets engine and integration tests exercise
    /// ownership and notification rules without classifying repositories first. Not compiled
    /// into Release builds, so a shipping app can't bypass context isolation.
    case ignoringContexts
    #endif
}

enum IngestionError: Error {
    case notStarted
}

/// Single entry point for incoming events:
///
///     incoming event → deduplicate → link workstream → persist → evaluate state → evaluate attention → publish
///
/// An actor so integrations can feed it concurrently. Work inside each call is synchronous
/// (no suspension points), so calls never interleave and state is saved in one atomic write.
actor IngestionService {
    /// Latest snapshot after every change. Intended for a single subscriber (the app model).
    nonisolated let updates: AsyncStream<TernSnapshot>

    private let continuation: AsyncStream<TernSnapshot>.Continuation
    private let store: any TernStore
    private let engine: AttentionEngine
    private let scoping: ContextScoping
    private var isContextScoped: Bool { scoping == .activeContext }
    private let now: @Sendable () -> Date
    private let meetingPolicy: MeetingPolicy

    private var isStarted = false
    private var persisted = PersistedState()
    private var seen: Set<EventID> = []
    private var resolver = WorkstreamResolver()
    /// Evaluated workstreams, derived from `persisted`.
    private var workstreams: [WorkstreamID: Workstream] = [:]
    /// The meetings Calendar last reported, and what they mean right now. In memory only:
    /// after a restart they are read from Calendar again.
    private var meetings: [Meeting] = []
    private var meetingStatuses: [MeetingStatus] = []

    /// - Parameters:
    ///   - rules: the user's workflow rules. Changing them takes effect on the next launch,
    ///     when every workstream is rebuilt from its events.
    ///   - scoping: only the active context's work may notify. The default, and the only
    ///     option in Release builds.
    init(
        store: any TernStore,
        rules: WorkflowRules = .none,
        now: @escaping @Sendable () -> Date = { .now },
        scoping: ContextScoping = .activeContext,
        meetingPolicy: MeetingPolicy = .standard
    ) {
        self.store = store
        self.meetingPolicy = meetingPolicy
        self.engine = AttentionEngine(rules: rules)
        self.scoping = scoping
        self.now = now
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
    }

    var snapshot: TernSnapshot {
        TernSnapshot(
            workstreams: persisted.workstreams.compactMap { workstreams[$0.id] },
            notifications: persisted.notifications,
            unresolvedAssociations: persisted.unresolvedAssociations,
            repositoryImportance: persisted.repositoryImportance,
            activeContext: persisted.activeContext,
            contextRules: persisted.contextRules,
            meetings: meetingStatuses,
            isContextScoped: isContextScoped
        )
    }

    /// Loads persisted state and rebuilds every workstream. Never notifies. Safe to call more than once.
    @discardableResult
    func start() throws -> TernSnapshot {
        if !isStarted {
            persisted = try store.load()
            seen = Set(persisted.workstreams.flatMap { $0.events.map(\.id) })
            resolver = WorkstreamResolver(links: persisted.links, hints: persisted.hints)
            workstreams = Dictionary(uniqueKeysWithValues: persisted.workstreams.map { ($0.id, rebuild($0)) })
            isStarted = true
            publish()
        }
        return snapshot
    }

    /// Declares a workstream and links references to it. Idempotent.
    func register(
        _ id: WorkstreamID,
        title: String,
        planeItem: PlaneItemReference? = nil,
        pullRequest: PullRequestReference? = nil,
        references: [ExternalReference] = []
    ) throws {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
        var nextResolver = resolver
        if !next.workstreams.contains(where: { $0.id == id }) {
            next.workstreams.append(WorkstreamRecord(id: id, title: title, planeItem: planeItem, pullRequest: pullRequest, events: []))
        }
        var allReferences = references
        if let planeItem { allReferences.append(.planeItem(planeItem.identifier)) }
        if let pullRequest { allReferences.append(.pullRequest(repository: pullRequest.repository, number: pullRequest.number)) }
        nextResolver.link(allReferences, to: id)
        next.links = nextResolver.allLinks

        try store.save(next)
        persisted = next
        resolver = nextResolver
        if workstreams[id] == nil, let record = next.workstreams.first(where: { $0.id == id }) {
            workstreams[id] = rebuild(record)
        }
        publish()
    }

    /// Whether a source's initial history import has finished (see `ingest(_:importKey:completesImport:)`).
    func hasCompletedImport(_ key: String) -> Bool {
        persisted.completedImports.contains(key)
    }

    /// Ingests events from a source with an initial history import, such as an account.
    /// Until that import completes, everything is history and stays silent; afterwards events
    /// are live. Marking the import complete is saved together with the events, so a crash or
    /// a different build can never see one without the other.
    @discardableResult
    func ingest(_ events: [ObservedEvent], importKey: String, completesImport: Bool) throws -> IngestReport {
        let imported = persisted.completedImports.contains(importKey)
        return try ingest(events, mode: imported ? .live : .historyImport, completingImport: completesImport && !imported ? importKey : nil)
    }

    /// Forgets that a source was imported (e.g. on disconnect), so reconnecting imports silently again.
    func resetImport(_ key: String) throws {
        guard isStarted, persisted.completedImports.contains(key) else { return }
        var next = persisted
        next.completedImports.removeAll { $0 == key }
        try store.save(next)
        persisted = next
    }

    /// Sets how much a repository matters to the user. `normal` removes the override.
    func setImportance(_ importance: RepositoryImportance, forRepository repository: String) throws {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
        let key = RepositoryImportance.key(forRepository: repository)
        next.repositoryImportance[key] = importance == .normal ? nil : importance
        try store.save(next)
        persisted = next
        publish()
    }

    /// Switches the context the user is looking at. No workstream is re-notified: the queue
    /// simply shows the other context's work.
    func setActiveContext(_ context: TernContext) throws {
        guard isStarted else { throw IngestionError.notStarted }
        guard persisted.activeContext != context else { return }
        var next = persisted
        next.activeContext = context
        // A meeting that became relevant while the user was away is surfaced once now, by the
        // same rules as any other transition; one already shown is not repeated.
        var notifications: [NotificationRecord] = []
        let statuses = evaluateMeetings(in: &next, notifications: &notifications)
        try store.save(next)
        persisted = next
        meetingStatuses = statuses
        publish()
    }

    /// Says which context a GitHub owner's repositories (or with `repository`, one repository,
    /// or with `calendar`, one macOS calendar) belong to. `nil` makes them unclassified again.
    func setContext(_ context: TernContext?, forOwner owner: String? = nil, repository: String? = nil, calendar: String? = nil) throws {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
        if let owner { next.contextRules.set(context, forOwner: owner) }
        if let repository { next.contextRules.set(context, forRepository: repository) }
        if let calendar { next.contextRules.set(context, forCalendar: calendar) }
        guard next.contextRules != persisted.contextRules else { return }
        var notifications: [NotificationRecord] = []
        let statuses = evaluateMeetings(in: &next, notifications: &notifications)
        try store.save(next)
        persisted = next
        meetingStatuses = statuses
        publish()
    }

    /// Takes the meetings Calendar currently reports and decides, through the same notification
    /// policy and shown-transition bookkeeping as workstreams, whether any is news. Repeating
    /// the same meetings is a no-op; only meetings from classified calendars are kept.
    @discardableResult
    func observeMeetings(_ observed: [Meeting]) throws -> IngestReport {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
        var report = IngestReport()
        let previous = meetings
        meetings = observed.filter { persisted.contextRules.context(forCalendar: $0.calendarID) != .unclassified }
        let statuses = evaluateMeetings(in: &next, notifications: &report.notifications)
        if next != persisted {
            do {
                try store.save(next)
            } catch {
                meetings = previous
                throw error
            }
            persisted = next
        }
        if statuses != meetingStatuses || !report.notifications.isEmpty {
            meetingStatuses = statuses
            publish()
        }
        return report
    }

    /// Ingests a batch of events. Already-seen events are ignored; affected workstreams are
    /// re-evaluated once, and each is compared with what the user was last shown.
    @discardableResult
    func ingest(_ events: [ObservedEvent], mode: IngestMode = .live, completingImport importKey: String? = nil) throws -> IngestReport {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
        if let importKey, !next.completedImports.contains(importKey) {
            next.completedImports.append(importKey)
        }
        var nextResolver = resolver
        var nextSeen = seen
        var report = IngestReport()
        var touched: [WorkstreamID] = []

        // Deduplicate and link.
        for observed in events {
            guard !nextSeen.contains(observed.id) else {
                report.duplicates.append(observed.id)
                continue
            }
            guard !observed.references.isEmpty else {
                report.unlinked.append(observed.id)
                continue
            }
            let workstreamID: WorkstreamID
            let placement = nextResolver.place(references: observed.references, candidates: observed.candidates)
            record(placement.issues, in: &next, report: &report)
            if let resolved = placement.workstream {
                workstreamID = resolved
            } else if observed.allowsNewWorkstream {
                let key = observed.workstreamKey ?? observed.references[0]
                workstreamID = Self.newWorkstreamID(for: key)
                if !next.workstreams.contains(where: { $0.id == workstreamID }) {
                    next.workstreams.append(WorkstreamRecord(
                        id: workstreamID,
                        title: observed.suggestedTitle ?? key.value,
                        events: []
                    ))
                    report.createdWorkstreams.append(workstreamID)
                }
            } else {
                report.unlinked.append(observed.id)
                continue
            }
            let linkIssues = nextResolver.link(observed.references, candidates: observed.candidates, to: workstreamID)
            record(linkIssues, in: &next, report: &report)
            guard let index = next.workstreams.firstIndex(where: { $0.id == workstreamID }) else { continue }
            next.workstreams[index].events.append(observed.linked(to: workstreamID))
            if next.workstreams[index].pullRequest == nil, let pullRequest = observed.pullRequest {
                next.workstreams[index].pullRequest = pullRequest
            }
            // A Plane work item is the workstream's identity: it supplies the title too.
            if next.workstreams[index].planeItem == nil, let planeItem = observed.planeItem {
                next.workstreams[index].planeItem = planeItem
                if let title = planeItem.title { next.workstreams[index].title = title }
            }
            nextSeen.insert(observed.id)
            report.accepted.append(observed.id)
            if !touched.contains(workstreamID) { touched.append(workstreamID) }
        }
        next.links = nextResolver.allLinks
        next.hints = nextResolver.allHints

        // Evaluate and decide what is new to the user.
        var rebuilt: [WorkstreamID: Workstream] = [:]
        for id in touched {
            guard let record = next.workstreams.first(where: { $0.id == id }) else { continue }
            var workstream = rebuild(record)
            let notification = next.surface(workstream.evaluation.transition, of: workstream.subjectID,
                                            in: next.contextRules.context(of: workstream), headline: workstream.status.headline,
                                            mode: mode, isContextScoped: isContextScoped, at: now())
            // A workstream's "New" marker lasts until it is next evaluated.
            workstream.evaluation.decision = workstream.evaluation.decision.with(shouldNotify: notification != nil)
            if let notification { report.notifications.append(notification) }
            rebuilt[id] = workstream
        }

        // Persist, then commit in memory and publish.
        if !report.accepted.isEmpty || next.completedImports != persisted.completedImports {
            try store.save(next)
            persisted = next
            resolver = nextResolver
            seen = nextSeen
            workstreams.merge(rebuilt) { _, new in new }
            publish()
        }
        return report
    }

    // MARK: - Meetings

    /// How long a meeting's shown transition and notification record are kept after it was surfaced.
    static let meetingBookkeepingRetention: TimeInterval = 24 * 60 * 60
    static let meetingHeadline = "Meeting starting soon"

    /// Evaluates the current meetings against `state` (its rules, active context and shown
    /// transitions) at `now()`, through the same `surface` path as workstreams. Meetings are
    /// always live: Calendar has no history to import.
    private func evaluateMeetings(in state: inout PersistedState, notifications: inout [NotificationRecord]) -> [MeetingStatus] {
        let at = now()
        var statuses: [MeetingStatus] = []
        var included: Set<[String]> = []
        for meeting in meetings.sorted(by: { ($0.startsAt, $0.id) < ($1.startsAt, $1.id) }) {
            let context = state.contextRules.context(forCalendar: meeting.calendarID)
            guard context != .unclassified else { continue }
            // One invitation in two calendars of the same context is one meeting. In different
            // contexts each copy belongs to its own context, with its own bookkeeping.
            guard included.insert([context.title, meeting.occurrenceKey]).inserted else { continue }
            var status = MeetingEvaluator.evaluate(meeting, context: context, at: at, policy: meetingPolicy)
            guard status.phase != .ended else { continue }
            // A meeting has a transition worth remembering only once it claims attention; a quiet
            // upcoming meeting leaves no trace in the saved state.
            if status.needsAttentionNow {
                let subject = meeting.subjectID
                if let notification = state.surface(status.transition, of: subject, in: context, headline: Self.meetingHeadline,
                                                    mode: .live, isContextScoped: isContextScoped, at: at) {
                    notifications.append(notification)
                }
                // A meeting's "New" marker lasts while the transition it was surfaced for is current.
                status.decision = status.decision.with(shouldNotify: state.wasNotified(status.transition, of: subject))
            }
            statuses.append(status)
        }
        // Forget meetings surfaced long ago, so bookkeeping doesn't grow with every meeting.
        state.shownTransitions.removeAll { shown in
            guard shown.subjectID.isMeeting, let causeAt = shown.transition.causeAt else { return false }
            return at.timeIntervalSince(causeAt) > Self.meetingBookkeepingRetention
        }
        state.notifications.removeAll { $0.subjectID.isMeeting && at.timeIntervalSince($0.createdAt) > Self.meetingBookkeepingRetention }
        return statuses
    }

    // MARK: - Helpers

    private func rebuild(_ record: WorkstreamRecord) -> Workstream {
        engine.rebuild(Workstream(
            id: record.id,
            title: record.title,
            planeItem: record.planeItem,
            pullRequest: record.pullRequest,
            events: record.events
        ))
    }

    /// Keeps declined associations for diagnostics, without repeats.
    private func record(_ issues: [AssociationIssue], in state: inout PersistedState, report: inout IngestReport) {
        for issue in issues where !state.unresolvedAssociations.contains(issue) {
            state.unresolvedAssociations.append(issue)
            report.unresolvedAssociations.append(issue)
        }
        state.unresolvedAssociations = Array(state.unresolvedAssociations.suffix(PersistedState.unresolvedAssociationLimit))
    }

    private func publish() {
        continuation.yield(snapshot)
    }

    private static func newWorkstreamID(for reference: ExternalReference) -> WorkstreamID {
        WorkstreamID("\(reference.kind):\(reference.value)")
    }

    #if DEBUG
    /// Debug-only: drops a workstream's history and shown transition, then imports `events`
    /// silently. Lets the mock scenario step backwards.
    func debugReplaceHistory(of id: WorkstreamID, with events: [ObservedEvent]) throws {
        guard isStarted, let index = persisted.workstreams.firstIndex(where: { $0.id == id }) else { return }
        var next = persisted
        for event in next.workstreams[index].events {
            seen.remove(event.id)
        }
        next.workstreams[index].events = []
        next.shownTransitions.removeAll { $0.subjectID == SubjectID(workstream: id) }
        try store.save(next)
        persisted = next
        workstreams[id] = rebuild(next.workstreams[index])
        publish()
        try ingest(events, mode: .historyImport)
    }
    #endif
}
