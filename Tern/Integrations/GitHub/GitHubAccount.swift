import Foundation
import Observation

/// UI-facing GitHub status. Tern doesn't own GitHub authentication — the GitHub CLI does —
/// so this only reports what `gh` can do and offers a manual refresh.
@MainActor
@Observable
final class GitHubAccount {
    enum State: Equatable {
        case checking
        case connected(login: String)
        case cliUnavailable
        case notAuthenticated
        case rateLimited(until: Date)
        case failing(String)
    }

    private(set) var sync = GitHubSyncService.Status()
    private let service: GitHubSyncService

    init(
        ingestion: IngestionService,
        cli: GitHubCLI = GitHubCLI(),
        bookmarks: any GitHubSyncBookmarks = UserDefaultsSyncBookmarks(),
        interval: TimeInterval = GitHubSyncService.defaultInterval,
        startSyncing: Bool = true,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        service = GitHubSyncService(cli: cli, ingestion: ingestion, bookmarks: bookmarks, interval: interval, now: now)
        Task { [weak self, service] in
            for await status in service.statusUpdates {
                self?.sync = status
            }
        }
        if startSyncing {
            Task { [service] in await service.start() }
        }
    }

    var state: State {
        switch sync.phase {
        case .starting:
            .checking
        case .cliUnavailable:
            .cliUnavailable
        case .notAuthenticated:
            .notAuthenticated
        case .rateLimited(let until):
            .rateLimited(until: until)
        case .failing where sync.login == nil:
            .failing(sync.lastError ?? "GitHub unavailable")
        case .idle, .syncing, .failing:
            sync.login.map { .connected(login: $0) } ?? .checking
        }
    }

    /// Syncs now instead of waiting for the next poll.
    func refresh() {
        Task { [service] in await service.syncOnce() }
    }
}
