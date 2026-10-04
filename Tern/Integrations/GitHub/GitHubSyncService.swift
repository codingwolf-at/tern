import Foundation
import os

/// Polls GitHub through the GitHub CLI and feeds normalized events into ingestion. Runs off
/// the main actor; the UI only sees published `Status` values and ingestion snapshots.
///
///     GitHubSyncService → gh → JSON → models → GitHubNormalizer → ObservedEvents → IngestionService
actor GitHubSyncService {
    struct Status: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            /// Not checked yet.
            case starting
            case idle
            case syncing
            case cliUnavailable
            case notAuthenticated
            case rateLimited(until: Date)
            case failing
        }

        var phase: Phase = .starting
        /// The account `gh` is logged in as on github.com.
        var login: String?
        var host = GitHubCLI.host
        var lastSync: Date?
        var lastError: String?
        var repositories = 0
        var authoredOpen = 0
        var reviewRequests = 0
        var trackedPullRequests = 0

        var isCLIAvailable: Bool? {
            switch phase {
            case .starting: nil
            case .cliUnavailable: false
            default: true
            }
        }

        var isAuthenticated: Bool? {
            switch phase {
            case .starting, .cliUnavailable: nil
            case .notAuthenticated: false
            default: login != nil
            }
        }
    }

    static let defaultInterval: TimeInterval = 90
    /// How often to look again while `gh` is missing or logged out.
    static let unavailableInterval: TimeInterval = 5 * 60
    static let maximumBackoff: TimeInterval = 15 * 60

    nonisolated let statusUpdates: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation

    private let cli: GitHubCLI
    private let ingestion: IngestionService
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "so.plane.tern", category: "github")

    private(set) var status = Status()
    /// Fingerprint of each pull request at its last successful detail fetch.
    private var fingerprints: [String: String] = [:]
    private var isSyncing = false
    private var consecutiveFailures = 0
    private var loop: Task<Void, Never>?

    init(
        cli: GitHubCLI,
        ingestion: IngestionService,
        interval: TimeInterval = GitHubSyncService.defaultInterval,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.cli = cli
        self.ingestion = ingestion
        self.interval = interval
        self.now = now
        (statusUpdates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    /// Starts polling. Idempotent.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.cycle()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One poll; returns the delay before the next.
    private func cycle() async -> TimeInterval {
        let result = await syncOnce()
        switch result.phase {
        case .cliUnavailable, .notAuthenticated:
            return Self.unavailableInterval
        case .rateLimited(let until):
            return max(until.timeIntervalSince(now()), interval)
        case .failing:
            return min(interval * pow(2, Double(consecutiveFailures)), Self.maximumBackoff)
        case .starting, .idle, .syncing:
            return interval
        }
    }

    /// Runs one sync. Safe to call while a poll is in flight: concurrent calls return the current status.
    @discardableResult
    func syncOnce() async -> Status {
        guard !isSyncing else { return status }
        isSyncing = true
        defer { isSyncing = false }
        let previous = status.phase
        status.phase = .syncing
        publish()

        do {
            // Ask `gh` who it's logged in as only when that's in doubt; a healthy sync
            // learns the login from the query itself.
            if previous != .idle && previous != .syncing {
                let auth = try await cli.authStatus()
                guard auth.isAuthenticated else { throw GitHubAPIError.notAuthenticated }
                status.login = auth.login
            }
            try await sync()
            consecutiveFailures = 0
            status.phase = .idle
        } catch let error as GitHubAPIError {
            record(error)
        } catch {
            record(.api("ingestion failed"))
        }
        publish()
        return status
    }

    private func record(_ error: GitHubAPIError) {
        status.lastError = error.summary
        switch error {
        case .cliNotFound:
            status.phase = .cliUnavailable
            status.login = nil
        case .notAuthenticated:
            status.phase = .notAuthenticated
            status.login = nil
        case .rateLimited(let until):
            status.phase = .rateLimited(until: until)
        default:
            consecutiveFailures += 1
            status.phase = .failing
        }
        logger.error("GitHub sync failed: \(error.summary, privacy: .public)")
    }

    private func sync() async throws {
        // 1. Cheap index of everything that might matter.
        let known = await knownPullRequestIDs()
        let (index, indexErrors) = try await cli.graphQL(
            GitHubQueries.index,
            variables: [
                "authored": .string(GitHubQueries.authoredSearch),
                "requested": .string(GitHubQueries.reviewRequestedSearch),
                "known": .strings(known),
            ],
            as: GitHubIndexPayload.self
        )
        let login = index.viewer.login
        status.login = login

        let authored = index.authored.items.filter { $0.id != nil }
        let requested = index.requested.items.filter { $0.id != nil }
        let requestedIDs = Set(requested.compactMap(\.id))
        var candidates: [String: GitHubIndexPullRequest] = [:]
        for pr in authored + requested + index.known.compactMap({ $0 }) {
            if let id = pr.id { candidates[id] = pr }
        }
        status.authoredOpen = authored.count
        status.reviewRequests = requested.count
        status.trackedPullRequests = candidates.count
        status.repositories = Set(candidates.values.compactMap(\.repository?.nameWithOwner)).count

        if index.rateLimit.remaining < 50 {
            throw GitHubAPIError.rateLimited(until: index.rateLimit.resetAt)
        }

        // 2. Full detail only for pull requests whose fingerprint changed.
        let changed = candidates.filter { fingerprints[$0.key] != $0.value.fingerprint }.keys.sorted()
        var details: [GitHubPullRequest] = []
        var problems = indexErrors.map(\.message)
        var completed = true
        for batch in stride(from: 0, to: changed.count, by: GitHubQueries.detailBatchSize) {
            let ids = Array(changed[batch..<min(batch + GitHubQueries.detailBatchSize, changed.count)])
            do {
                let (payload, errors) = try await cli.graphQL(GitHubQueries.detail, variables: ["ids": .strings(ids)], as: GitHubDetailPayload.self)
                details += payload.nodes.compactMap { $0 }
                problems += errors.map(\.message)
            } catch .rateLimited(let until) {
                throw GitHubAPIError.rateLimited(until: until)
            } catch .notAuthenticated {
                throw GitHubAPIError.notAuthenticated
            } catch .cliNotFound {
                throw GitHubAPIError.cliNotFound
            } catch {
                // Partial failure: keep what we have; these are retried next poll.
                completed = false
                problems.append(error.summary)
            }
        }

        // 3. Normalize and ingest. Until the account's first full sync completes, it's history: silent.
        let normalizer = GitHubNormalizer(viewerLogin: login)
        let events = details.flatMap { normalizer.events(for: $0, requestedViaSearch: requestedIDs.contains($0.id)) }
        try await ingestion.ingest(events, importKey: Self.importKey(login), completesImport: completed)
        for pr in details {
            if let fingerprint = candidates[pr.id]?.fingerprint { fingerprints[pr.id] = fingerprint }
        }

        status.lastSync = now()
        status.lastError = problems.isEmpty ? nil : "\(problems.count) partial error\(problems.count == 1 ? "" : "s"): \(problems[0])"
        logger.debug("GitHub sync: \(candidates.count) PRs, \(changed.count) changed, \(events.count) events")
    }

    static func importKey(_ login: String) -> String {
        "github:\(login.lowercased())"
    }

    /// Open pull requests Tern already tracks, so closures and merges are noticed even
    /// after a PR drops out of the searches.
    private func knownPullRequestIDs() async -> [String] {
        let workstreams = await ingestion.snapshot.workstreams
        let ids = workstreams
            .filter { $0.state != .complete }
            .flatMap(\.events)
            .compactMap { $0.source == .github && $0.kind == .pullRequestOpened ? $0[.pullRequestNodeID] : nil }
        return Array(Set(ids)).sorted().prefix(100).map { $0 }
    }

    private func publish() {
        continuation.yield(status)
    }
}
