import Foundation
import os

/// Remembers which accounts have finished their first (silent) import. Not secret.
protocol GitHubSyncBookmarks: Sendable {
    func hasImported(_ login: String) -> Bool
    func markImported(_ login: String)
    func clear()
}

struct UserDefaultsSyncBookmarks: GitHubSyncBookmarks {
    private let key = "github.importedLogins"

    func hasImported(_ login: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(login.lowercased())
    }

    func markImported(_ login: String) {
        let logins = Set(UserDefaults.standard.stringArray(forKey: key) ?? []).union([login.lowercased()])
        UserDefaults.standard.set(logins.sorted(), forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Polls GitHub and feeds normalized events into ingestion. Runs off the main actor;
/// the UI only sees published `Status` values and ingestion snapshots.
///
///     GitHubSyncService → ObservedEvents → IngestionService → snapshot → AppModel
actor GitHubSyncService {
    struct Status: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case idle
            case syncing
            case unauthorized
            case rateLimited(until: Date)
            case failing
        }

        var login: String?
        var phase: Phase = .idle
        var lastSync: Date?
        var lastError: String?
        var repositories = 0
        var authoredOpen = 0
        var reviewRequests = 0
        var trackedPullRequests = 0
    }

    static let defaultInterval: TimeInterval = 90
    static let maximumBackoff: TimeInterval = 15 * 60

    nonisolated let statusUpdates: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation

    private let client: GitHubClient
    private let credentials: any GitHubCredentialStore
    private let deviceFlow: GitHubDeviceFlow?
    private let ingestion: IngestionService
    private let bookmarks: any GitHubSyncBookmarks
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
        client: GitHubClient,
        credentials: any GitHubCredentialStore,
        deviceFlow: GitHubDeviceFlow?,
        ingestion: IngestionService,
        bookmarks: any GitHubSyncBookmarks,
        interval: TimeInterval = GitHubSyncService.defaultInterval,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.credentials = credentials
        self.deviceFlow = deviceFlow
        self.ingestion = ingestion
        self.bookmarks = bookmarks
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
                guard let self, let delay = await self.cycle() else { return }
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Stops polling and forgets in-memory sync state (used on disconnect).
    func reset() {
        stop()
        fingerprints = [:]
        consecutiveFailures = 0
        status = Status()
        publish()
    }

    /// One poll; returns the delay before the next, or `nil` to stop polling.
    private func cycle() async -> TimeInterval? {
        let result = await syncOnce()
        switch result.phase {
        case .unauthorized:
            loop = nil
            return nil
        case .rateLimited(let until):
            return max(until.timeIntervalSince(now()), interval)
        case .failing:
            return min(interval * pow(2, Double(consecutiveFailures)), Self.maximumBackoff)
        case .idle, .syncing:
            return interval
        }
    }

    /// Runs one sync. Safe to call while a poll is in flight: concurrent calls return the current status.
    @discardableResult
    func syncOnce() async -> Status {
        guard !isSyncing else { return status }
        isSyncing = true
        defer { isSyncing = false }
        status.phase = .syncing
        publish()

        do {
            let token = try await validToken()
            try await sync(token: token)
            consecutiveFailures = 0
            status.phase = .idle
        } catch let error as GitHubAPIError {
            record(error)
        } catch {
            record(.network("unavailable"))
        }
        publish()
        return status
    }

    private func record(_ error: GitHubAPIError) {
        status.lastError = error.summary
        switch error {
        case .unauthorized:
            status.phase = .unauthorized
        case .rateLimited(let until):
            status.phase = .rateLimited(until: until)
        default:
            consecutiveFailures += 1
            status.phase = .failing
        }
        logger.error("GitHub sync failed: \(error.summary, privacy: .public)")
    }

    private func validToken() async throws -> String {
        guard var credential = try? credentials.load() else { throw GitHubAPIError.unauthorized }
        if credential.isExpired(at: now()) {
            guard let deviceFlow, let refreshed = try? await deviceFlow.refresh(credential) else { throw GitHubAPIError.unauthorized }
            credential = refreshed
            try? credentials.save(credential)
        }
        return credential.accessToken
    }

    private func sync(token: String) async throws {
        // 1. Cheap index of everything that might matter.
        let known = await knownPullRequestIDs()
        let (index, indexErrors) = try await client.query(
            GitHubQueries.index,
            variables: [
                "authored": .string(GitHubQueries.authoredSearch),
                "requested": .string(GitHubQueries.reviewRequestedSearch),
                "known": .strings(known),
            ],
            token: token,
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
                let (payload, errors) = try await client.query(GitHubQueries.detail, variables: ["ids": .strings(ids)], token: token, as: GitHubDetailPayload.self)
                details += payload.nodes.compactMap { $0 }
                problems += errors.map(\.message)
            } catch .rateLimited(let until) {
                throw GitHubAPIError.rateLimited(until: until)
            } catch .unauthorized {
                throw GitHubAPIError.unauthorized
            } catch {
                // Partial failure: keep what we have; these are retried next poll.
                completed = false
                problems.append(error.summary)
            }
        }

        // 3. Normalize and ingest. The first sync of an account is history: silent.
        let normalizer = GitHubNormalizer(viewerLogin: login)
        let events = details.flatMap { normalizer.events(for: $0, requestedViaSearch: requestedIDs.contains($0.id)) }
        let firstImport = !bookmarks.hasImported(login)
        if !events.isEmpty {
            try await ingestion.ingest(events, mode: firstImport ? .historyImport : .live)
        }
        if completed { bookmarks.markImported(login) }
        for pr in details {
            if let fingerprint = candidates[pr.id]?.fingerprint { fingerprints[pr.id] = fingerprint }
        }

        status.lastSync = now()
        status.lastError = problems.isEmpty ? nil : "\(problems.count) partial error\(problems.count == 1 ? "" : "s"): \(problems[0])"
        logger.debug("GitHub sync: \(candidates.count) PRs, \(changed.count) changed, \(events.count) events")
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
