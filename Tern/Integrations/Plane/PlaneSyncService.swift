import Foundation
import os

/// Where the Plane token lives. Only the Keychain in the app; memory in tests.
protocol PlaneCredentialStore: Sendable {
    func token(for workspace: String) throws -> String?
    func save(_ token: String, for workspace: String) throws
    func delete(for workspace: String) throws
}

/// Plane tokens in the login keychain, one item per workspace, in this build's own namespace.
struct KeychainPlaneCredentialStore: PlaneCredentialStore {
    var keychain: KeychainStore

    init(environment: BuildEnvironment = .current) {
        keychain = KeychainStore(service: environment.keychainService("plane"))
    }

    init(keychain: KeychainStore) {
        self.keychain = keychain
    }

    func token(for workspace: String) throws -> String? {
        try keychain.read(workspace).map { String(decoding: $0, as: UTF8.self) }
    }

    func save(_ token: String, for workspace: String) throws {
        try keychain.write(Data(token.utf8), account: workspace, label: "Tern Plane access (\(workspace))")
    }

    func delete(for workspace: String) throws {
        try keychain.delete(workspace)
    }
}

/// Polls Plane for the user's open work items and feeds normalized events into ingestion.
/// Runs off the main actor; the UI only sees published `Status` values.
///
///     PlaneSyncService → Plane API → models → PlaneNormalizer → ObservedEvents → IngestionService
actor PlaneSyncService {
    struct Status: Sendable, Equatable {
        enum Phase: Sendable, Equatable {
            case notConfigured
            case idle
            case syncing
            case invalidCredentials
            case workspaceUnavailable
            case rateLimited(until: Date)
            case failing
        }

        var phase: Phase = .notConfigured
        var workspace: String?
        var userName: String?
        var lastSync: Date?
        var lastError: String?
        var activeItems = 0
        var linkedWorkstreams = 0
        var unresolvedAssociations = 0
    }

    static let defaultInterval: TimeInterval = 3 * 60
    static let maximumBackoff: TimeInterval = 30 * 60
    /// Items no longer in the open list that are re-checked individually per poll.
    static let followUpLimit = 10

    nonisolated let statusUpdates: AsyncStream<Status>
    private let continuation: AsyncStream<Status>.Continuation

    private let credentials: any PlaneCredentialStore
    private let http: any PlaneHTTP
    private let ingestion: IngestionService
    private let interval: TimeInterval
    private let now: @Sendable () -> Date
    private let logger = Logger(subsystem: "so.plane.tern", category: "plane")

    private(set) var status = Status()
    private var workspace: PlaneWorkspace?
    private var user: PlaneUser?
    private var fingerprints: [String: String] = [:]
    private var isSyncing = false
    private var consecutiveFailures = 0
    private var loop: Task<Void, Never>?

    init(
        credentials: any PlaneCredentialStore,
        http: any PlaneHTTP,
        ingestion: IngestionService,
        interval: TimeInterval = PlaneSyncService.defaultInterval,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.credentials = credentials
        self.http = http
        self.ingestion = ingestion
        self.interval = interval
        self.now = now
        (statusUpdates, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    deinit {
        loop?.cancel()
        continuation.finish()
    }

    /// Points the service at a workspace (or none) and forgets per-workspace state.
    func configure(_ workspace: PlaneWorkspace?) {
        self.workspace = workspace
        user = nil
        fingerprints = [:]
        consecutiveFailures = 0
        status = Status(phase: workspace == nil ? .notConfigured : .idle, workspace: workspace?.slug)
        publish()
    }

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

    /// Checks a token against a workspace without storing anything.
    func verify(_ token: String, workspace: PlaneWorkspace) async throws(PlaneAPIError) -> PlaneUser {
        let client = PlaneClient(workspace: workspace, token: token, http: http, now: now)
        let user = try await client.me()
        _ = try await client.openItems(assignedTo: user.id).count
        return user
    }

    private func cycle() async -> TimeInterval {
        let result = await syncOnce()
        switch result.phase {
        case .notConfigured, .invalidCredentials, .workspaceUnavailable:
            return Self.maximumBackoff
        case .rateLimited(let until):
            return max(until.timeIntervalSince(now()), interval)
        case .failing:
            return min(interval * pow(2, Double(consecutiveFailures)), Self.maximumBackoff)
        case .idle, .syncing:
            return interval
        }
    }

    @discardableResult
    func syncOnce() async -> Status {
        guard !isSyncing else { return status }
        guard let workspace else {
            status.phase = .notConfigured
            publish()
            return status
        }
        isSyncing = true
        defer { isSyncing = false }
        status.phase = .syncing
        publish()

        do {
            let token: String?
            do { token = try credentials.token(for: workspace.slug) } catch { throw PlaneAPIError.network("keychain unavailable") }
            guard let token else { throw PlaneAPIError.notConnected }
            try await sync(PlaneClient(workspace: workspace, token: token, http: http, now: now), workspace: workspace)
            consecutiveFailures = 0
            status.phase = .idle
        } catch let error as PlaneAPIError {
            status.lastError = error.summary
            switch error {
            case .notConnected: status.phase = .notConfigured
            case .invalidCredentials: status.phase = .invalidCredentials
            case .workspaceUnavailable: status.phase = .workspaceUnavailable
            case .rateLimited(let until): status.phase = .rateLimited(until: until)
            default:
                consecutiveFailures += 1
                status.phase = .failing
            }
            logger.error("Plane sync failed: \(error.summary, privacy: .public)")
        } catch {
            consecutiveFailures += 1
            status.phase = .failing
            status.lastError = "Ingestion failed"
        }
        await refreshCounts()
        publish()
        return status
    }

    private func sync(_ client: PlaneClient, workspace: PlaneWorkspace) async throws {
        let user: PlaneUser
        if let cached = self.user {
            user = cached
        } else {
            user = try await client.me()
            self.user = user
        }
        status.userName = user.name

        let open = try await client.openItems(assignedTo: user.id)
        status.activeItems = open.count
        let normalizer = PlaneNormalizer(workspace: workspace, userID: user.id, observedAt: now())

        // Items Tern follows that left the open list: completed, unassigned, archived or deleted.
        let openIDs = Set(open.map(\.id))
        var followUps: [PlaneWorkItem] = []
        var removals: [ObservedEvent] = []
        for tracked in await trackedItems(workspace: workspace) where !openIDs.contains(tracked.itemID) {
            guard followUps.count + removals.count < Self.followUpLimit else { break }
            if let item = try await client.item(tracked.identifier) {
                followUps.append(item)
            } else {
                removals.append(normalizer.removed(itemID: tracked.itemID, identifier: tracked.identifier, title: nil, at: now()))
            }
        }

        let changed = (open + followUps).filter { fingerprints[$0.id] != $0.fingerprint }
        let events = changed.flatMap(normalizer.events(for:)) + removals
        try await ingestion.ingest(events, importKey: Self.importKey(workspace: workspace, userID: user.id), completesImport: true)
        for item in changed { fingerprints[item.id] = item.fingerprint }
        status.lastSync = now()
        status.lastError = nil
    }

    static func importKey(workspace: PlaneWorkspace, userID: String) -> String {
        "plane:\(workspace.slug):\(userID)"
    }

    /// Forgets the current account's import, so a reconnect imports silently again.
    func forgetImport() async {
        guard let workspace, let user else { return }
        try? await ingestion.resetImport(Self.importKey(workspace: workspace, userID: user.id))
    }

    /// Plane items Tern tracks in this workspace that aren't finished.
    private func trackedItems(workspace: PlaneWorkspace) async -> [(itemID: String, identifier: String)] {
        let workstreams = await ingestion.snapshot.workstreams.filter { $0.state != .complete }
        var tracked: [(String, String)] = []
        var seen: Set<String> = []
        for workstream in workstreams {
            guard let identifier = workstream.planeItem?.identifier else { continue }
            for event in workstream.events where event.source == .plane && event.kind == .planeItemCreated {
                if let itemID = event[.planeItemID], event.id.rawValue.hasPrefix("plane:item:\(workspace.slug):"), seen.insert(itemID).inserted {
                    tracked.append((itemID, identifier))
                }
            }
        }
        return tracked
    }

    private func refreshCounts() async {
        let snapshot = await ingestion.snapshot
        status.linkedWorkstreams = snapshot.workstreams.filter { $0.planeItem != nil && ($0.pullRequest != nil || !$0.agentSessions.isEmpty) }.count
        status.unresolvedAssociations = snapshot.unresolvedAssociations.count
    }

    private func publish() {
        continuation.yield(status)
    }
}
