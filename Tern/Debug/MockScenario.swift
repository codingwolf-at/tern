#if DEBUG
import Foundation

/// Seed data for development and tests. Everything is positioned relative to `now`, and every
/// event has a stable source ID, so the same scenario can be ingested repeatedly.
/// Events reach workstreams only through reference linking, the way real integrations will.
struct MockScenario: Sendable {
    struct Registration: Sendable {
        let id: WorkstreamID
        let title: String
        let planeItem: PlaneItemReference?
        let pullRequest: PullRequestReference?
        let references: [ExternalReference]
    }

    let now: Date

    static let avatarMigrationID = WorkstreamID("avatar-migration")
    static let repository = "makeplane/plane"

    init(now: Date = .now) {
        self.now = now
    }

    /// Workstreams the user has set up, with the references that link events to them.
    var registrations: [Registration] {
        [
            Registration(
                id: Self.avatarMigrationID,
                title: "Avatar migration",
                planeItem: PlaneItemReference(identifier: "PLANE-1842", title: "Migrate avatars to the new storage bucket"),
                pullRequest: PullRequestReference(repository: Self.repository, number: 421),
                references: [.branch("avatar-migration", repository: Self.repository)]
            ),
            Registration(
                id: WorkstreamID("settings-cleanup"),
                title: "Settings page cleanup",
                planeItem: PlaneItemReference(identifier: "PLANE-1857"),
                pullRequest: nil,
                references: [.branch("settings-cleanup", repository: Self.repository)]
            ),
            Registration(
                id: WorkstreamID("rate-limiter"),
                title: "API rate limiter",
                planeItem: nil,
                pullRequest: PullRequestReference(repository: Self.repository, number: 430),
                references: []
            ),
            Registration(
                id: WorkstreamID("search-indexing"),
                title: "Search indexing",
                planeItem: PlaneItemReference(identifier: "PLANE-1860"),
                pullRequest: nil,
                references: [.branch("search-indexing", repository: Self.repository)]
            ),
            Registration(
                id: WorkstreamID("webhook-retries"),
                title: "Webhook retries",
                planeItem: nil,
                pullRequest: PullRequestReference(repository: Self.repository, number: 433),
                references: []
            ),
            Registration(
                id: WorkstreamID("billing-export"),
                title: "Billing CSV export",
                planeItem: nil,
                pullRequest: PullRequestReference(repository: Self.repository, number: 415),
                references: []
            ),
        ]
    }

    /// The featured story, in order: from Plane ticket to a reviewer coming back with feedback.
    var avatarMigrationScript: [ObservedEvent] {
        let plane = ExternalReference.planeItem("PLANE-1842")
        let pr = ExternalReference.pullRequest(repository: Self.repository, number: 421)
        let meeting = ISO8601DateFormatter().string(from: now.addingTimeInterval(minutes(45)))
        return [
            event(EventID(.calendar, "event", "avatar-sync"), .calendar, .calendarEventScheduled, 24 * 60, [plane], [.title: "Avatar rollout sync", .startsAt: meeting]),
            event(EventID(.plane, "item", "PLANE-1842", "created"), .plane, .planeItemCreated, 6 * 60, [plane]),
            event(EventID(.github, "pr", "421", "opened"), .github, .pullRequestOpened, 4 * 60, [pr]),
            event(EventID(.github, "review-request", "7001"), .github, .reviewRequested, 3 * 60 + 50, [pr], [.reviewer: "Priya"]),
            event(EventID(.github, "review", "7002"), .github, .changesRequested, 2 * 60, [pr], [.reviewer: "Priya", .commentCount: "3"]),
            agent("avatar-1", "start", .agentStarted, 110, branch: "avatar-migration"),
            agent("avatar-1", "stop", .agentCompleted, 40, branch: "avatar-migration"),
            event(EventID(.github, "check-run", "8001", "passed"), .github, .ciPassed, 30, [pr], [.checkName: "build"]),
            event(EventID(.github, "review", "7003"), .github, .reviewerResponded, 8, [pr], [.reviewer: "Priya", .commentCount: "2"]),
        ]
    }

    /// History for the supporting workstreams.
    var otherEvents: [ObservedEvent] {
        func pr(_ number: Int) -> ExternalReference { .pullRequest(repository: Self.repository, number: number) }
        return [
            event(EventID(.plane, "item", "PLANE-1857", "created"), .plane, .planeItemCreated, 3 * 60, [.planeItem("PLANE-1857")]),
            agent("settings-1", "start", .agentStarted, 55, branch: "settings-cleanup"),
            agent("settings-1", "stop", .agentCompleted, 12, branch: "settings-cleanup"),

            event(EventID(.github, "pr", "430", "opened"), .github, .pullRequestOpened, 26 * 60, [pr(430)]),
            event(EventID(.github, "review-request", "7101"), .github, .reviewRequested, 5 * 60, [pr(430)], [.reviewer: "Sarah"]),

            event(EventID(.plane, "item", "PLANE-1860", "created"), .plane, .planeItemCreated, 90, [.planeItem("PLANE-1860")]),
            agent("search-1", "start", .agentStarted, 20, branch: "search-indexing"),

            event(EventID(.github, "pr", "433", "opened"), .github, .pullRequestOpened, 2 * 60, [pr(433)]),
            event(EventID(.github, "check-run", "8101", "started"), .github, .ciStarted, 6, [pr(433)], [.checkName: "test"]),

            event(EventID(.github, "pr", "415", "opened"), .github, .pullRequestOpened, 30 * 60, [pr(415)]),
            event(EventID(.github, "review", "7201"), .github, .reviewApproved, 4 * 60, [pr(415)], [.reviewer: "Sarah"]),
            event(EventID(.github, "pr", "415", "merged"), .github, .pullRequestMerged, 3 * 60, [pr(415)]),
        ]
    }

    /// Registers every workstream and silently imports all history except the featured
    /// workstream's last `liveTail` events, which are left for the caller to play live.
    func seed(into service: IngestionService, liveTail: Int = 0) async throws {
        for registration in registrations {
            try await service.register(
                registration.id,
                title: registration.title,
                planeItem: registration.planeItem,
                pullRequest: registration.pullRequest,
                references: registration.references
            )
        }
        let script = avatarMigrationScript
        try await service.ingest(otherEvents + script.dropLast(liveTail), mode: .historyImport)
    }

    // MARK: - Helpers

    private func event(
        _ id: EventID,
        _ source: EventSource,
        _ kind: WorkEventKind,
        _ minutesAgo: Int,
        _ references: [ExternalReference],
        _ metadata: [MetadataKey: String] = [:]
    ) -> ObservedEvent {
        ObservedEvent(
            id: id,
            source: source,
            kind: kind,
            timestamp: now.addingTimeInterval(-minutes(minutesAgo)),
            metadata: metadata,
            references: references
        )
    }

    private func agent(_ session: String, _ step: String, _ kind: WorkEventKind, _ minutesAgo: Int, branch: String) -> ObservedEvent {
        event(
            EventID(.agent, "session", session, step),
            .agent,
            kind,
            minutesAgo,
            [.agentSession(provider: "claude", id: session), .branch(branch, repository: Self.repository)],
            [.agentName: "Claude Code", .agentSessionID: session]
        )
    }

    private func minutes(_ value: Int) -> TimeInterval {
        TimeInterval(value * 60)
    }
}
#endif
