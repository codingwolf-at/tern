import Foundation
import Testing
@testable import Tern

@Suite("GitHub sync", .serialized)
struct GitHubSyncTests {
    @Test("First sync imports history silently and learns who I am")
    func firstSyncSilent() async throws {
        let h = try await GitHubHarness()
        h.github.update {
            $0.pullRequests = [
                GH.pr(reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5))]),
                GH.pr(id: "PR_2", number: 430, title: "Rate limiter", author: "sarah", head: "rate", requests: [GH.reviewer(GH.me)]),
            ]
            $0.reviewRequested = ["PR_2"]
        }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .idle)
        #expect(status.login == GH.me)
        #expect(status.authoredOpen == 1)
        #expect(status.reviewRequests == 1)
        #expect(status.repositories == 1)
        #expect(await h.notificationCount() == 0)
        #expect(await h.workstream()?.attention == .high)
        #expect(await h.workstream("Rate limiter")?.nextOwner == .me)
        #expect(h.bookmarks.hasImported(GH.me))
        #expect(h.github.read { $0.lastToken } == "Bearer gho_test_secret_token")
    }

    @Test("After the first sync, a new review request notifies")
    func newReviewRequestNotifies() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()] }
        await h.sync.syncOnce()

        h.github.update {
            $0.pullRequests.append(GH.pr(id: "PR_2", number: 430, title: "Rate limiter", author: "sarah", head: "rate",
                                         updated: GH.at(10), requests: [GH.reviewer(GH.me)]))
            $0.reviewRequested = ["PR_2"]
        }
        await h.sync.syncOnce()
        let notifications = await h.ingestion.snapshot.notifications
        #expect(notifications.count == 1)
        #expect(notifications.first?.headline == "Review requested")
    }

    @Test("A new changes-requested review notifies")
    func changesRequestedNotifies() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("priya")])] }
        await h.sync.syncOnce()
        #expect(await h.workstream()?.nextOwner == .reviewer)

        h.github.update { $0.pullRequests = [GH.pr(updated: GH.at(10), reviews: [GH.review(7, "CHANGES_REQUESTED", by: "priya", at: GH.at(10))])] }
        await h.sync.syncOnce()
        #expect(await h.notificationCount() == 1)
        #expect(await h.workstream()?.attention == .high)
    }

    @Test("Unchanged PRs aren't re-fetched; re-fetched data doesn't duplicate or notify")
    func duplicateSync() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5))])] }
        await h.sync.syncOnce()
        let before = await h.workstream()
        let detailFetches = h.github.read { $0.detailRequests }

        await h.sync.syncOnce()
        #expect(h.github.read { $0.detailRequests } == detailFetches, "fingerprint unchanged → no detail query")

        // A relaunch forgets fingerprints, so everything is fetched again.
        let relaunched = try await h.relaunched()
        await relaunched.sync.syncOnce()
        #expect(h.github.read { $0.detailRequests } == detailFetches + 1)
        let after = await relaunched.workstream()
        #expect(after?.events == before?.events)
        #expect(await relaunched.notificationCount() == 0)
        #expect(await relaunched.ingestion.snapshot.workstreams.count == 1)
    }

    @Test("A transition already shown isn't notified again after relaunch")
    func handledTransition() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("priya")])] }
        await h.sync.syncOnce()
        h.github.update { $0.pullRequests = [GH.pr(updated: GH.at(10), reviews: [GH.review(7, "CHANGES_REQUESTED", by: "priya", at: GH.at(10))])] }
        await h.sync.syncOnce()
        #expect(await h.notificationCount() == 1)

        let relaunched = try await h.relaunched()
        await relaunched.sync.syncOnce()
        #expect(await relaunched.notificationCount() == 1)
    }

    @Test("A known PR that leaves the searches is still followed to its merge")
    func followsToMerge() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("sarah")])] }
        await h.sync.syncOnce()
        h.github.update { $0.pullRequests = [GH.pr(state: "MERGED", merged: true, updated: GH.at(20), timeline: [GH.timeline("MergedEvent", id: "M_1", at: GH.at(20))])] }
        await h.sync.syncOnce()
        #expect(await h.workstream()?.state == .complete)
    }

    @Test("Unauthorized stops syncing; existing state stays")
    func unauthorized() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("sarah")])] }
        await h.sync.syncOnce()
        h.github.update { $0.failure = .status(401, headers: [:]) }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .unauthorized)
        #expect(await h.workstream()?.nextOwner == .reviewer)
    }

    @Test("Rate limits and network failures are reported, not fatal")
    func failures() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.failure = .status(403, headers: ["X-RateLimit-Remaining": "0", "X-RateLimit-Reset": "1800003600"]) }
        #expect(await h.sync.syncOnce().phase == .rateLimited(until: Date(timeIntervalSince1970: 1_800_003_600)))

        h.github.update { $0.failure = .offline }
        let offline = await h.sync.syncOnce()
        #expect(offline.phase == .failing)
        #expect(offline.lastError == "Network: offline")

        h.github.update { $0.failure = nil; $0.pullRequests = [GH.pr()] }
        #expect(await h.sync.syncOnce().phase == .idle)
    }

    @Test("Low remaining rate limit pauses before fetching details")
    func lowRateLimit() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()]; $0.rateLimitRemaining = 10 }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .rateLimited(until: GH.at(60)))
        #expect(h.github.read { $0.detailRequests } == 0)
    }

    @Test("The token never reaches Tern's state file")
    func tokenNotPersisted() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()] }
        await h.sync.syncOnce()
        let json = String(decoding: try JSONEncoder().encode(h.store.load()), as: UTF8.self)
        #expect(!json.contains("gho_test_secret_token"))
        #expect(json.contains("github:pr:100:421:opened"))
    }
}

@Suite("GitHub authentication", .serialized)
@MainActor
struct GitHubAuthTests {
    /// Answers the device-flow endpoints with a scripted sequence of token responses.
    final class DeviceStub: GitHubHTTP, @unchecked Sendable {
        var tokenResponses: [[String: Any]]
        var requests: [URLRequest] = []

        init(_ tokenResponses: [[String: Any]]) {
            self.tokenResponses = tokenResponses
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            let json: [String: Any] = request.url == GitHubDeviceFlow.deviceCodeURL
                ? ["device_code": "dev-123", "user_code": "ABCD-1234", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5]
                : tokenResponses.removeFirst()
            return (try JSONSerialization.data(withJSONObject: json), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }

    private func flow(_ stub: DeviceStub, slept: SleepLog = SleepLog()) -> GitHubDeviceFlow {
        var flow = GitHubDeviceFlow(clientID: "Iv1.test", http: stub, now: { GH.t0 })
        flow.sleep = { seconds in await slept.record(seconds) }
        return flow
    }

    actor SleepLog {
        var intervals: [TimeInterval] = []
        func record(_ seconds: TimeInterval) { intervals.append(seconds) }
    }

    @Test("Device flow: code, pending, slow down, token — without a client secret")
    func deviceFlow() async throws {
        let stub = DeviceStub([["error": "authorization_pending"], ["error": "slow_down", "interval": 10], ["access_token": "ghu_abc", "token_type": "bearer"]])
        let log = SleepLog()
        let flow = flow(stub, slept: log)
        let code = try await flow.requestCode()
        #expect(code.userCode == "ABCD-1234")
        let credential = try await flow.waitForToken(code)
        #expect(credential.accessToken == "ghu_abc")
        #expect(await log.intervals == [5, 5, 10])
        let bodies = stub.requests.compactMap { $0.httpBody.map { String(decoding: $0, as: UTF8.self) } }
        #expect(bodies.allSatisfy { !$0.contains("client_secret") })
        #expect(bodies.first == "client_id=Iv1.test")
    }

    @Test("Device flow: denied and expired")
    func deviceFlowFailures() async throws {
        let denied = flow(DeviceStub([["error": "access_denied"]]))
        await #expect(throws: GitHubDeviceFlow.FlowError.denied) { try await denied.waitForToken(try await denied.requestCode()) }
        let expired = flow(DeviceStub([["error": "expired_token"]]))
        await #expect(throws: GitHubDeviceFlow.FlowError.expired) { try await expired.waitForToken(try await expired.requestCode()) }
    }

    @Test("Expiring tokens carry refresh details")
    func expiringToken() async throws {
        let flow = flow(DeviceStub([["access_token": "ghu_abc", "refresh_token": "ghr_def", "expires_in": 28800]]))
        let credential = try await flow.waitForToken(try await flow.requestCode())
        #expect(credential.refreshToken == "ghr_def")
        #expect(credential.expiresAt == GH.t0.addingTimeInterval(28800))
        #expect(credential.isExpired(at: GH.t0) == false)
        #expect(credential.isExpired(at: GH.t0.addingTimeInterval(28800)))
    }

    private func account(clientID: String = "Iv1.test", credential: GitHubCredential? = nil) -> (GitHubAccount, InMemoryCredentialStore, UserDefaults) {
        let defaults = UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)")!
        let store = InMemoryCredentialStore(credential)
        let account = GitHubAccount(
            clientID: clientID,
            ingestion: IngestionService(store: InMemoryTernStore()),
            credentials: store,
            bookmarks: InMemoryBookmarks(),
            http: StubGitHub(),
            defaults: defaults,
            startSyncing: false
        )
        return (account, store, defaults)
    }

    @Test("Connection state: unconfigured, disconnected, connected")
    func connectionStates() {
        #expect(account(clientID: "").0.state == .unconfigured)
        #expect(account().0.state == .disconnected)
        #expect(account(credential: GitHubCredential(accessToken: "t")).0.state == .connected(login: nil))
    }

    @Test("Syncing reveals the GitHub identity")
    func identity() async throws {
        let h = try await GitHubHarness()
        #expect(await h.sync.syncOnce().login == GH.me)
    }

    @Test("Disconnect removes the local credential")
    func disconnect() {
        let (account, store, defaults) = account(credential: GitHubCredential(accessToken: "t"))
        defaults.set("atul", forKey: "github.login")
        account.disconnect()
        #expect(store.load() == nil)
        #expect(account.state == .disconnected)
        #expect(defaults.string(forKey: "github.login") == nil)
    }

    @Test("The keychain store round-trips and deletes")
    func keychain() throws {
        let store = KeychainCredentialStore(service: "so.plane.tern.tests.\(UUID().uuidString)")
        defer { try? store.delete() }
        #expect(try store.load() == nil)
        try store.save(GitHubCredential(accessToken: "first"))
        try store.save(GitHubCredential(accessToken: "second", refreshToken: "r"))
        #expect(try store.load() == GitHubCredential(accessToken: "second", refreshToken: "r"))
        try store.delete()
        #expect(try store.load() == nil)
    }
}
