import Foundation
import Observation

/// UI-facing Plane connection: connect with a workspace and personal access token, disconnect,
/// and sync status. The token goes straight to the Keychain; nothing here talks to Plane itself.
@MainActor
@Observable
final class PlaneAccount {
    enum State: Equatable {
        case notConnected
        case connecting
        case connected(workspace: String, user: String?)
        case invalidCredentials(workspace: String)
        case workspaceUnavailable(workspace: String)
        case problem(String)
    }

    private(set) var sync = PlaneSyncService.Status()
    private(set) var connectError: String?
    private(set) var isConnecting = false

    private let service: PlaneSyncService
    private let credentials: any PlaneCredentialStore
    private let defaults: UserDefaults
    private static let workspaceKey = "plane.workspace"

    init(
        ingestion: IngestionService,
        credentials: any PlaneCredentialStore = KeychainPlaneCredentialStore(),
        http: any PlaneHTTP = URLSessionPlaneHTTP(),
        defaults: UserDefaults = .standard,
        interval: TimeInterval = PlaneSyncService.defaultInterval,
        startSyncing: Bool = true,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.credentials = credentials
        self.defaults = defaults
        service = PlaneSyncService(credentials: credentials, http: http, ingestion: ingestion, interval: interval, now: now)

        let workspace = defaults.data(forKey: Self.workspaceKey).flatMap { try? JSONDecoder().decode(PlaneWorkspace.self, from: $0) }
        Task { [weak self, service] in
            for await status in service.statusUpdates {
                self?.sync = status
            }
        }
        Task { [service] in
            await service.configure(workspace)
            if workspace != nil && startSyncing { await service.start() }
        }
    }

    var state: State {
        if isConnecting { return .connecting }
        switch sync.phase {
        case .notConfigured:
            return .notConnected
        case .invalidCredentials:
            return .invalidCredentials(workspace: sync.workspace ?? "")
        case .workspaceUnavailable:
            return .workspaceUnavailable(workspace: sync.workspace ?? "")
        case .failing where sync.lastSync == nil:
            return .problem(sync.lastError ?? "Plane unavailable")
        case .rateLimited, .failing, .idle, .syncing:
            return .connected(workspace: sync.workspace ?? "", user: sync.userName)
        }
    }

    /// Verifies the token against the workspace, then stores it in the Keychain and starts syncing.
    func connect(workspace slug: String, api: String = PlaneWorkspace.cloudAPI.absoluteString, token: String) {
        connectError = nil
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace: PlaneWorkspace
        do {
            workspace = try PlaneWorkspace(slug: slug, api: api)
        } catch {
            connectError = error.message
            return
        }
        guard !token.isEmpty else {
            connectError = "Enter a personal access token"
            return
        }
        isConnecting = true
        Task { [service, credentials, defaults] in
            defer { self.isConnecting = false }
            do {
                _ = try await service.verify(token, workspace: workspace)
                try credentials.save(token, for: workspace.slug)
                defaults.set(try JSONEncoder().encode(workspace), forKey: Self.workspaceKey)
                await service.configure(workspace)
                await service.syncOnce()
                await service.start()
            } catch let error as PlaneAPIError {
                self.connectError = error.summary
            } catch {
                self.connectError = "Couldn't save the token to the Keychain"
            }
        }
    }

    /// Removes the token and workspace. Synced workstreams stay.
    func disconnect() {
        let workspace = sync.workspace
        Task { [service, credentials] in
            await service.stop()
            await service.forgetImport()
            if let workspace { try? credentials.delete(for: workspace) }
            await service.configure(nil)
        }
        defaults.removeObject(forKey: Self.workspaceKey)
        connectError = nil
    }

    func refresh() {
        Task { [service] in await service.syncOnce() }
    }
}
