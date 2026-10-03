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
}

/// What the UI renders.
struct TernSnapshot: Hashable, Sendable {
    var workstreams: [Workstream] = []
    var notifications: [NotificationRecord] = []
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
    private let engine = AttentionEngine()
    private let now: @Sendable () -> Date

    private var isStarted = false
    private var persisted = PersistedState()
    private var seen: Set<EventID> = []
    private var resolver = WorkstreamResolver()
    /// Evaluated workstreams, derived from `persisted`.
    private var workstreams: [WorkstreamID: Workstream] = [:]

    init(store: any TernStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.now = now
        (updates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        continuation.finish()
    }

    var snapshot: TernSnapshot {
        TernSnapshot(
            workstreams: persisted.workstreams.compactMap { workstreams[$0.id] },
            notifications: persisted.notifications
        )
    }

    /// Loads persisted state and rebuilds every workstream. Never notifies. Safe to call more than once.
    @discardableResult
    func start() throws -> TernSnapshot {
        if !isStarted {
            persisted = try store.load()
            seen = Set(persisted.workstreams.flatMap { $0.events.map(\.id) })
            resolver = WorkstreamResolver(links: persisted.links)
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

    /// Ingests a batch of events. Already-seen events are ignored; affected workstreams are
    /// re-evaluated once, and each is compared with what the user was last shown.
    @discardableResult
    func ingest(_ events: [ObservedEvent], mode: IngestMode = .live) throws -> IngestReport {
        guard isStarted else { throw IngestionError.notStarted }
        var next = persisted
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
            if let resolved = nextResolver.resolve(observed.references) {
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
            nextResolver.link(observed.references, to: workstreamID)
            guard let index = next.workstreams.firstIndex(where: { $0.id == workstreamID }) else { continue }
            next.workstreams[index].events.append(observed.linked(to: workstreamID))
            nextSeen.insert(observed.id)
            report.accepted.append(observed.id)
            if !touched.contains(workstreamID) { touched.append(workstreamID) }
        }
        next.links = nextResolver.allLinks

        // Evaluate and decide what is new to the user.
        var rebuilt: [WorkstreamID: Workstream] = [:]
        for id in touched {
            guard let record = next.workstreams.first(where: { $0.id == id }) else { continue }
            var workstream = rebuild(record)
            let transition = workstream.evaluation.transition
            let lastShown = next.shownTransitions.first { $0.workstreamID == id }?.transition
            let notify = mode == .live && NotificationPolicy.shouldNotify(transition, lastShown: lastShown)

            workstream.evaluation.decision = workstream.evaluation.decision.with(shouldNotify: notify)
            next.shownTransitions.removeAll { $0.workstreamID == id }
            next.shownTransitions.append(ShownTransition(workstreamID: id, transition: transition))
            if notify {
                let record = NotificationRecord(
                    workstreamID: id,
                    fingerprint: transition.fingerprint,
                    headline: workstream.status.headline,
                    attention: transition.attention,
                    createdAt: now()
                )
                next.notifications.append(record)
                report.notifications.append(record)
            }
            rebuilt[id] = workstream
        }
        next.notifications = Array(next.notifications.suffix(PersistedState.notificationHistoryLimit))

        // Persist, then commit in memory and publish.
        if !report.accepted.isEmpty {
            try store.save(next)
            persisted = next
            resolver = nextResolver
            seen = nextSeen
            workstreams.merge(rebuilt) { _, new in new }
            publish()
        }
        return report
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
        next.shownTransitions.removeAll { $0.workstreamID == id }
        try store.save(next)
        persisted = next
        workstreams[id] = rebuild(next.workstreams[index])
        publish()
        try ingest(events, mode: .historyImport)
    }
    #endif
}
