import AppKit
import Foundation
import Observation
import os

/// UI-facing GitHub connection: connect via device flow, disconnect, and sync status.
/// Owns no GitHub parsing; sync runs in `GitHubSyncService`.
@MainActor
@Observable
final class GitHubAccount {
    enum State: Equatable {
        /// No GitHub App client ID configured in this build.
        case unconfigured
        case disconnected
        case requestingCode
        case authorizing(userCode: String, verificationURL: URL)
        case connected(login: String?)
        /// The stored credential stopped working.
        case needsReconnect(login: String?)
    }

    static let authorizationsURL = URL(string: "https://github.com/settings/apps/authorizations")!

    private(set) var state: State
    private(set) var sync = GitHubSyncService.Status()
    private(set) var connectError: String?

    private let deviceFlow: GitHubDeviceFlow
    private let credentials: any GitHubCredentialStore
    private let bookmarks: any GitHubSyncBookmarks
    private let service: GitHubSyncService
    private let defaults: UserDefaults
    private var flow: Task<Void, Never>?
    private let logger = Logger(subsystem: "so.plane.tern", category: "github")

    private static let loginKey = "github.login"

    init(
        clientID: String,
        ingestion: IngestionService,
        credentials: any GitHubCredentialStore = KeychainCredentialStore(),
        bookmarks: any GitHubSyncBookmarks = UserDefaultsSyncBookmarks(),
        http: any GitHubHTTP = URLSessionGitHubHTTP(),
        defaults: UserDefaults = .standard,
        interval: TimeInterval = GitHubSyncService.defaultInterval,
        startSyncing: Bool = true
    ) {
        self.defaults = defaults
        let now: @Sendable () -> Date = { .now }
        let deviceFlow = GitHubDeviceFlow(clientID: clientID, http: http, now: now)
        self.deviceFlow = deviceFlow
        self.credentials = credentials
        self.bookmarks = bookmarks
        self.service = GitHubSyncService(
            client: GitHubClient(http: http, now: now),
            credentials: credentials,
            deviceFlow: deviceFlow,
            ingestion: ingestion,
            bookmarks: bookmarks,
            interval: interval,
            now: now
        )

        let hasCredential = (try? credentials.load()) != nil
        let login = defaults.string(forKey: Self.loginKey)
        if clientID.isEmpty && !hasCredential {
            state = .unconfigured
        } else {
            state = hasCredential ? .connected(login: login) : .disconnected
        }

        Task { [weak self, service] in
            for await status in service.statusUpdates {
                self?.apply(status)
            }
        }
        if hasCredential && startSyncing {
            Task { [service] in await service.start() }
        }
    }

    /// The client ID baked into this build (see `TERN_GITHUB_CLIENT_ID`).
    static var configuredClientID: String {
        (Bundle.main.object(forInfoDictionaryKey: "TernGitHubClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }

    var login: String? {
        switch state {
        case .connected(let login), .needsReconnect(let login): login
        default: nil
        }
    }

    /// Starts the device flow: shows a code, opens GitHub in the browser, waits for approval.
    func connect() {
        flow?.cancel()
        connectError = nil
        state = .requestingCode
        flow = Task { [weak self, deviceFlow, credentials, service] in
            do {
                let code = try await deviceFlow.requestCode()
                self?.state = .authorizing(userCode: code.userCode, verificationURL: code.verificationURL)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code.userCode, forType: .string)
                NSWorkspace.shared.open(code.verificationURL)

                let credential = try await deviceFlow.waitForToken(code)
                try credentials.save(credential)
                self?.state = .connected(login: nil)
                let status = await service.syncOnce()
                await service.start()
                self?.apply(status)
            } catch is CancellationError {
                return
            } catch {
                self?.logger.error("GitHub connect failed: \(String(describing: error), privacy: .public)")
                self?.connectError = Self.describe(error)
                self?.state = .disconnected
            }
        }
    }

    func cancel() {
        flow?.cancel()
        flow = nil
        state = .disconnected
    }

    /// Removes the local credential and stops syncing. Already-synced workstreams stay.
    func disconnect() {
        flow?.cancel()
        flow = nil
        try? credentials.delete()
        bookmarks.clear()
        defaults.removeObject(forKey: Self.loginKey)
        Task { [service] in await service.reset() }
        sync = GitHubSyncService.Status()
        state = .disconnected
    }

    func syncNow() {
        Task { [service] in await service.syncOnce() }
    }

    private func apply(_ status: GitHubSyncService.Status) {
        sync = status
        if let login = status.login {
            defaults.set(login, forKey: Self.loginKey)
        }
        switch (state, status.phase) {
        case (.connected, .unauthorized):
            state = .needsReconnect(login: status.login ?? login)
        case (.connected, _), (.needsReconnect, .idle):
            state = .connected(login: status.login ?? login)
        default:
            break
        }
    }

    private static func describe(_ error: any Error) -> String {
        switch error {
        case GitHubDeviceFlow.FlowError.denied: "Authorization was denied"
        case GitHubDeviceFlow.FlowError.expired: "The code expired; try again"
        case GitHubDeviceFlow.FlowError.notConfigured: "No GitHub App configured"
        case is KeychainError: "Couldn't save to the keychain"
        default: "Couldn't connect to GitHub"
        }
    }
}
