import Foundation

/// Seed data for Phase 1. Everything is positioned relative to `now`, so the same
/// `now` always produces the same workstreams.
struct MockScenario: Sendable {
    let now: Date

    static let avatarMigrationID = WorkstreamID("avatar-migration")

    init(now: Date = .now) {
        self.now = now
    }

    /// The featured workstream with no events; `avatarMigrationScript` plays into it.
    var avatarMigrationShell: Workstream {
        Workstream(
            id: Self.avatarMigrationID,
            title: "Avatar migration",
            planeItem: PlaneItemReference(identifier: "PLANE-1842", title: "Migrate avatars to the new storage bucket"),
            pullRequest: PullRequestReference(repository: "makeplane/plane", number: 421)
        )
    }

    /// The featured story, in order: from Plane ticket to a reviewer coming back with feedback.
    var avatarMigrationScript: [WorkEvent] {
        let id = Self.avatarMigrationID
        let meeting = ISO8601DateFormatter().string(from: now.addingTimeInterval(minutes(45)))
        return [
            event(id, .calendar, .calendarEventScheduled, minutesAgo: 24 * 60, [.title: "Avatar rollout sync", .startsAt: meeting]),
            event(id, .plane, .planeItemCreated, minutesAgo: 6 * 60),
            event(id, .github, .pullRequestOpened, minutesAgo: 4 * 60),
            event(id, .github, .reviewRequested, minutesAgo: 3 * 60 + 50, [.reviewer: "Priya"]),
            event(id, .github, .changesRequested, minutesAgo: 2 * 60, [.reviewer: "Priya", .commentCount: "3"]),
            event(id, .agent, .agentStarted, minutesAgo: 110, claude("avatar-1")),
            event(id, .agent, .agentCompleted, minutesAgo: 40, claude("avatar-1")),
            event(id, .github, .ciPassed, minutesAgo: 30, [.checkName: "build"]),
            event(id, .github, .reviewerResponded, minutesAgo: 8, [.reviewer: "Priya", .commentCount: "2"]),
        ]
    }

    /// Supporting workstreams that fill out the panel.
    var otherWorkstreams: [Workstream] {
        [
            seeded(
                Workstream(
                    id: WorkstreamID("settings-cleanup"),
                    title: "Settings page cleanup",
                    planeItem: PlaneItemReference(identifier: "PLANE-1857")
                ),
                [
                    (.plane, .planeItemCreated, 3 * 60, [:]),
                    (.agent, .agentStarted, 55, claude("settings-1")),
                    (.agent, .agentCompleted, 12, claude("settings-1")),
                ]
            ),
            seeded(
                Workstream(
                    id: WorkstreamID("rate-limiter"),
                    title: "API rate limiter",
                    pullRequest: PullRequestReference(repository: "makeplane/plane", number: 430)
                ),
                [
                    (.github, .pullRequestOpened, 26 * 60, [:]),
                    (.github, .reviewRequested, 5 * 60, [.reviewer: "Sarah"]),
                ]
            ),
            seeded(
                Workstream(
                    id: WorkstreamID("search-indexing"),
                    title: "Search indexing",
                    planeItem: PlaneItemReference(identifier: "PLANE-1860")
                ),
                [
                    (.plane, .planeItemCreated, 90, [:]),
                    (.agent, .agentStarted, 20, claude("search-1")),
                ]
            ),
            seeded(
                Workstream(
                    id: WorkstreamID("webhook-retries"),
                    title: "Webhook retries",
                    pullRequest: PullRequestReference(repository: "makeplane/plane", number: 433)
                ),
                [
                    (.github, .pullRequestOpened, 2 * 60, [:]),
                    (.github, .ciStarted, 6, [.checkName: "test"]),
                ]
            ),
            seeded(
                Workstream(
                    id: WorkstreamID("billing-export"),
                    title: "Billing CSV export",
                    pullRequest: PullRequestReference(repository: "makeplane/plane", number: 415)
                ),
                [
                    (.github, .pullRequestOpened, 30 * 60, [:]),
                    (.github, .reviewApproved, 4 * 60, [.reviewer: "Sarah"]),
                    (.github, .pullRequestMerged, 3 * 60, [:]),
                ]
            ),
        ]
    }

    // MARK: - Helpers

    private func seeded(
        _ shell: Workstream,
        _ entries: [(EventSource, WorkEventKind, Int, [MetadataKey: String])]
    ) -> Workstream {
        var workstream = shell
        workstream.events = entries.map { source, kind, minutesAgo, metadata in
            event(shell.id, source, kind, minutesAgo: minutesAgo, metadata)
        }
        return workstream
    }

    private func event(
        _ id: WorkstreamID,
        _ source: EventSource,
        _ kind: WorkEventKind,
        minutesAgo: Int,
        _ metadata: [MetadataKey: String] = [:]
    ) -> WorkEvent {
        WorkEvent(
            workstreamID: id,
            source: source,
            kind: kind,
            timestamp: now.addingTimeInterval(-minutes(minutesAgo)),
            metadata: Dictionary(uniqueKeysWithValues: metadata.map { ($0.key.rawValue, $0.value) })
        )
    }

    private func claude(_ session: String) -> [MetadataKey: String] {
        [.agentName: "Claude Code", .agentSessionID: session]
    }

    private func minutes(_ value: Int) -> TimeInterval {
        TimeInterval(value * 60)
    }
}
