import Foundation
import OSLog
import Testing
@testable import Tern

@Suite("Plane normalization")
struct PlaneNormalizationTests {
    @Test("A work item becomes events carrying its identity, state, assignment and link")
    func workItem() throws {
        let events = PL.events(PL.item())
        #expect(events.map(\.kind) == [.planeItemCreated, .planeItemStateChanged])
        let created = try #require(events.first)
        #expect(created.id == EventID(rawValue: "plane:item:plane:item-WEB-9295:created"))
        #expect(created.references == [.planeItem("WEB-9295")])
        #expect(created.planeItem == PlaneItemReference(identifier: "WEB-9295", title: "Customer property chevron", url: URL(string: "https://app.plane.so/plane/browse/WEB-9295/")))
        #expect(created.metadata["stateName"] == "In Progress")
        #expect(created.metadata["stateGroup"] == "started")
        #expect(created.metadata["assignedToMe"] == "true")
        #expect(events[1].timestamp == PL.at(1))
    }

    @Test("Identity is stable across syncs; a state change is a new event")
    func identity() {
        #expect(PL.events(PL.item()) == PL.events(PL.item()))
        let moved = PL.events(PL.item(state: PL.inReview, updated: PL.at(5)))
        #expect(moved[0].id == PL.events(PL.item())[0].id)
        #expect(moved[1].id != PL.events(PL.item())[1].id)
    }

    @Test("Unassigned and archived items are reflected")
    func unassignedAndArchived() {
        #expect(PL.events(PL.item(assignees: ["someone-else"]))[0].metadata["assignedToMe"] == "false")
        let archived = PL.events(PL.item(state: PL.done, archived: PL.at(9)))
        #expect(archived.last?.kind == .planeItemRemoved)
    }

    @Test("Plane's microsecond timestamps parse")
    func dates() throws {
        let date = try #require(PlaneJSON.parseDate("2026-08-05T11:34:24.026442Z"))
        #expect(abs(date.timeIntervalSince1970 - 1_785_929_664.026) < 0.001)
        #expect(PlaneJSON.parseDate("2026-08-05T11:34:24Z") != nil)
    }

    @Test("Workspace slug and API base are separate; Plane Cloud by default")
    func workspaces() throws {
        let cloud = try PlaneWorkspace(slug: "plane")
        #expect(cloud.slug == "plane")
        #expect(cloud.apiBase.absoluteString == "https://api.plane.so")
        #expect(cloud.webBase.absoluteString == "https://app.plane.so")
        #expect(try PlaneWorkspace(slug: " plane ", api: "https://api.plane.so/") == cloud)

        let hosted = try PlaneWorkspace(slug: "team", api: "https://plane.example.com")
        #expect(hosted.apiBase.absoluteString == "https://plane.example.com")
        #expect(hosted.webBase.absoluteString == "https://plane.example.com")
    }

    @Test("Mistaken inputs are rejected with a reason, never used as an endpoint")
    func invalidInputs() {
        #expect(throws: PlaneWorkspace.InputError.slugIsURL) { try PlaneWorkspace(slug: "https://app.plane.so/plane/") }
        #expect(throws: PlaneWorkspace.InputError.invalidSlug) { try PlaneWorkspace(slug: "my workspace") }
        #expect(throws: PlaneWorkspace.InputError.webAppURL) { try PlaneWorkspace(slug: "plane", api: "https://app.plane.so") }
        #expect(throws: PlaneWorkspace.InputError.invalidAPIBase) { try PlaneWorkspace(slug: "plane", api: "https://api.plane.so/api/v2/") }
        #expect(throws: PlaneWorkspace.InputError.invalidAPIBase) { try PlaneWorkspace(slug: "plane", api: "http://api.plane.so") }
        #expect(throws: PlaneWorkspace.InputError.invalidAPIBase) { try PlaneWorkspace(slug: "plane", api: "api.plane.so") }
    }

    @Test("Requests go to api.plane.so under /api/v2/, ask only for documented fields, and authenticate with X-API-Key")
    func requestURLs() async throws {
        final class Spy: PlaneHTTP, @unchecked Sendable {
            let lock = NSLock()
            var requests: [URLRequest] = []
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                lock.withLock { requests.append(request) }
                let path = request.url!.path()
                let body = path.hasSuffix("/users/me/") ? #"{"id":"u1"}"#
                    : path.hasSuffix("/work-items/") ? #"{"data":[],"next":null}"#
                    : #"{"id":"i1","identifier":"WEB-1","name":"x","created_at":"2026-01-01T00:00:00.000000Z"}"#
                return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let spy = Spy()
        let client = PlaneClient(workspace: PL.workspace, token: "plane_api_test", http: spy, now: { PL.t0 })
        _ = try await client.me()
        _ = try await client.openItems(assignedTo: "u1")
        _ = try await client.item("WEB-1")

        let urls = spy.requests.map(\.url!)
        #expect(urls.map { "\($0.scheme!)://\($0.host()!)\($0.path())" } == [
            "https://api.plane.so/api/v2/users/me/",
            "https://api.plane.so/api/v2/workspaces/plane/work-items/",
            "https://api.plane.so/api/v2/workspaces/plane/work-items/WEB-1/",
        ])
        #expect(spy.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-API-Key") == "plane_api_test" && ($0.httpMethod ?? "GET") == "GET" })

        let documented: Set<String> = ["archived_at", "assignee_ids", "created_at", "created_by_id", "cycle_id", "id", "identifier", "is_draft",
                                       "label_ids", "module_ids", "name", "parent_id", "priority", "project_id", "sequence_id", "start_date",
                                       "state_id", "target_date", "type_id"]
        for url in urls.dropFirst() {
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
            #expect(Set(query["fields"]!.split(separator: ",").map(String.init)).isSubset(of: documented))
            #expect(query["order_by"] == nil)
        }
        let list = Dictionary(uniqueKeysWithValues: URLComponents(url: urls[1], resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value!) })
        #expect(list["assignee_id"] == "u1")
        #expect(list["state_group__in"] == "backlog,unstarted,started")
        #expect(list["expand"] == "state")
    }

    @Test("Plane identifiers are found in branches, titles and Plane links")
    func identifiers() {
        #expect(PlaneIdentifiers.find(in: "fix/WEB-9295-customer-property-chevron") == ["WEB-9295"])
        #expect(PlaneIdentifiers.find(in: "WEB-8423/labels-improvement") == ["WEB-8423"])
        #expect(PlaneIdentifiers.find(in: "[WIKI-1218] fix: picker; see WEB-9295") == ["WIKI-1218", "WEB-9295"])
        #expect(PlaneIdentifiers.find(in: "fix/dropdowns-after-react-upgrade").isEmpty)
        #expect(PlaneIdentifiers.findInLinks("Closes https://app.plane.so/plane/browse/WEB-9295/") == ["WEB-9295"])
    }
}

@Suite("Plane sync", .serialized)
struct PlaneSyncTests {
    @Test("First sync creates one workstream per assigned item, silently")
    func firstSync() async throws {
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item(), PL.item("WIKI-1218", name: "Picker", state: PL.todo), PL.item("WEB-1", assignees: ["other"])] }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .idle)
        #expect(status.userName == "Atul")
        #expect(status.activeItems == 2)
        let workstreams = await h.ingestion.snapshot.workstreams
        #expect(workstreams.map { $0.planeItem?.identifier } == ["WEB-9295", "WIKI-1218"])
        #expect(workstreams.first?.title == "Customer property chevron")
        #expect(await h.ingestion.snapshot.notifications.isEmpty)
        #expect(h.plane.read { $0.lastAPIKey } == "plane_api_valid_test_token")
    }

    @Test("Repeated sync is idempotent and skips unchanged items")
    func repeated() async throws {
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item()] }
        await h.sync.syncOnce()
        let before = await h.ingestion.snapshot
        await h.sync.syncOnce()
        #expect(await h.ingestion.snapshot == before)
        #expect(before.workstreams.count == 1)
    }

    @Test("Items leaving the open list are followed: completed, or removed")
    func followUps() async throws {
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item(), PL.item("WEB-2", name: "Other")] }
        await h.sync.syncOnce()

        h.plane.update { $0.items = [PL.item(state: PL.done, updated: PL.at(10))] }
        await h.sync.syncOnce()
        #expect(h.plane.read { $0.lookups }.sorted() == ["WEB-2", "WEB-9295"])
        #expect(await h.workstream()?.state == .complete)
        #expect(await h.workstream("WEB-2")?.state == .complete)
        #expect(await h.workstream("WEB-2")?.status.detail == "Removed from Plane")
    }

    @Test("Auth, access, rate-limit and network failures are reported and state is kept")
    func failures() async throws {
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item()] }
        await h.sync.syncOnce()

        h.plane.update { $0.token = "plane_api_rotated" }
        #expect(await h.sync.syncOnce().phase == .invalidCredentials)
        h.plane.update { $0.token = "plane_api_valid_test_token"; $0.failure = .status(403, body: #"{"detail":"Given API token is not valid"}"#) }
        #expect(await h.sync.syncOnce().phase == .invalidCredentials)
        h.plane.update { $0.failure = .status(404) }
        #expect(await h.sync.syncOnce().phase == .workspaceUnavailable)
        h.plane.update { $0.failure = .status(429, headers: ["X-RateLimit-Reset": "1800000600"]) }
        #expect(await h.sync.syncOnce().phase == .rateLimited(until: Date(timeIntervalSince1970: 1_800_000_600)))
        h.plane.update { $0.failure = .offline }
        #expect(await h.sync.syncOnce().phase == .failing)
        h.plane.update { $0.failure = .malformed }
        let malformed = await h.sync.syncOnce()
        #expect(malformed.lastError == "Unexpected response from Plane")

        h.plane.update { $0.failure = nil }
        #expect(await h.sync.syncOnce().phase == .idle)
        #expect(await h.workstream() != nil)
    }

    @Test("Without a token the service is simply not configured")
    func noToken() async throws {
        let h = try await PlaneHarness(token: nil)
        #expect(await h.sync.syncOnce().phase == .notConfigured)
        #expect(h.plane.read { $0.listRequests } == 0)
    }
}

@Suite("Plane account", .serialized)
@MainActor
struct PlaneAccountTests {
    private func account(_ credentials: InMemoryPlaneCredentials, _ plane: PlaneStub, defaults: UserDefaults) -> PlaneAccount {
        let ingestion = IngestionService(store: InMemoryTernStore())
        Task { try? await ingestion.start() }
        return PlaneAccount(
            ingestion: ingestion,
            credentials: credentials,
            http: plane,
            defaults: defaults,
            startSyncing: false,
            now: { PL.t0 }
        )
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("Connect verifies the token, stores it in the credential store only, and connects")
    func connect() async throws {
        let credentials = InMemoryPlaneCredentials()
        let defaults = UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)")!
        let account = account(credentials, PlaneStub(), defaults: defaults)
        try await wait { account.state == .notConnected }
        #expect(account.state == .notConnected)

        account.connect(workspace: "plane", token: "plane_api_valid_test_token")
        try await wait { if case .connected(_, .some) = account.state { true } else { false } }
        #expect(account.state == .connected(workspace: "plane", user: "Atul"))
        #expect(credentials.all == ["plane": "plane_api_valid_test_token"])
        #expect(!(defaults.dictionaryRepresentation().description.contains("plane_api_valid_test_token")))

        account.disconnect()
        try await wait { account.state == .notConnected }
        #expect(credentials.all.isEmpty)
    }

    @Test("A pasted web-app URL is explained, not sent to Plane")
    func webURLInput() async throws {
        let credentials = InMemoryPlaneCredentials()
        let plane = PlaneStub()
        let account = account(credentials, plane, defaults: UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)")!)
        account.connect(workspace: "https://app.plane.so/plane/", token: "plane_api_valid_test_token")
        #expect(account.connectError == "Enter just the workspace slug, e.g. plane")
        account.connect(workspace: "plane", api: "https://app.plane.so/plane/", token: "plane_api_valid_test_token")
        #expect(account.connectError == "That's the Plane web app. The API is https://api.plane.so")
        #expect(plane.read { $0.listRequests } == 0)
        #expect(credentials.all.isEmpty)
    }

    @Test("An invalid token is rejected and never stored")
    func invalid() async throws {
        let credentials = InMemoryPlaneCredentials()
        let account = account(credentials, PlaneStub(), defaults: UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)")!)
        account.connect(workspace: "plane", token: "plane_api_wrong")
        try await wait { account.connectError != nil }
        #expect(account.connectError == "Plane rejected the token")
        #expect(credentials.all.isEmpty)
    }

    @Test("A token revoked later shows as rejected")
    func revoked() async throws {
        let credentials = InMemoryPlaneCredentials()
        let plane = PlaneStub()
        let account = account(credentials, plane, defaults: UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)")!)
        account.connect(workspace: "plane", token: "plane_api_valid_test_token")
        try await wait { if case .connected(_, .some) = account.state { true } else { false } }
        plane.update { $0.token = "plane_api_rotated" }
        account.refresh()
        try await wait { account.state == .invalidCredentials(workspace: "plane") }
        #expect(account.state == .invalidCredentials(workspace: "plane"))
    }

    @Test("The token never reaches app state, defaults, diagnostics or logs")
    func privacy() async throws {
        let start = Date()
        let h = try await PlaneHarness()
        h.plane.update { $0.items = [PL.item()] }
        let status = await h.sync.syncOnce()
        h.plane.update { $0.token = "plane_api_rotated" }
        let rejected = await h.sync.syncOnce()

        let secret = "plane_api_valid_test_token"
        let state = String(decoding: try JSONEncoder().encode(h.store.load()), as: UTF8.self)
        #expect(!state.contains(secret))
        #expect(!String(describing: status).contains(secret) && !String(describing: rejected).contains(secret))
        #expect(!UserDefaults.standard.dictionaryRepresentation().description.contains(secret))
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(at: log.position(date: start)).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "so.plane.tern" }.map(\.composedMessage)
        #expect(messages.contains { $0.contains("Plane rejected the token") })
        #expect(!messages.contains { $0.contains(secret) })
    }

    @Test("The Keychain store round-trips and deletes")
    func keychain() throws {
        let store = KeychainPlaneCredentialStore(keychain: KeychainStore(service: "so.plane.tern.tests.\(UUID().uuidString)"))
        defer { try? store.delete(for: "plane") }
        #expect(try store.token(for: "plane") == nil)
        try store.save("first", for: "plane")
        try store.save("second", for: "plane")
        #expect(try store.token(for: "plane") == "second")
        try store.delete(for: "plane")
        #expect(try store.token(for: "plane") == nil)
    }
}

/// Plane, GitHub and Claude describing the same work end up in one workstream.
@Suite("Plane correlation")
struct PlaneCorrelationTests {
    private func service() async throws -> IngestionService {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 })
        try await service.start()
        return service
    }

    private func claude(_ session: String, branch: String, seq: Int = 1) -> ObservedEvent {
        ClaudeHookNormalizer.normalize(ClaudeHookPayload(
            hookEventName: "UserPromptSubmit", sessionID: session, promptID: "p-\(session)-\(seq)", cwd: "/Users/me/plane-ee",
            sequence: seq, timestampMilliseconds: Int64(GH.at(Double(seq)).timeIntervalSince1970 * 1000),
            gitRoot: "/Users/me/plane-ee", gitRemote: "acme/web", gitBranch: branch
        ), receivedAt: GH.t0)!
    }

    @Test("A PR whose branch names the item joins the item's workstream")
    func branchMatch() async throws {
        let service = try await service()
        try await service.ingest(PL.events(PL.item()))
        let report = try await service.ingest(GH.events(GH.pr(head: "fix/WEB-9295-customer-property-chevron")))
        #expect(report.createdWorkstreams.isEmpty)
        let ws = try #require(await service.snapshot.workstreams.first)
        #expect(await service.snapshot.workstreams.count == 1)
        #expect(ws.planeItem?.identifier == "WEB-9295")
        #expect(ws.pullRequest?.number == 421)
        #expect(ws.primaryLabel == "WEB-9295")
        #expect(ws.contextLine == "PR #421 · In Progress")
    }

    @Test("A PR titled with the identifier joins, even on an unrelated branch")
    func titleMatch() async throws {
        let service = try await service()
        try await service.ingest(PL.events(PL.item()))
        try await service.ingest(GH.events(GH.pr(title: "[WEB-9295] fix: chevron", head: "chevron")))
        #expect(await service.snapshot.workstreams.count == 1)
    }

    @Test("A Plane link in the PR body joins")
    func bodyMatch() async throws {
        let service = try await service()
        try await service.ingest(PL.events(PL.item()))
        try await service.ingest(GH.events(GH.pr(title: "fix: chevron", body: "Fixes https://app.plane.so/plane/browse/WEB-9295/", head: "chevron")))
        #expect(await service.snapshot.workstreams.count == 1)
    }

    @Test("A PR seen before its Plane item: the item joins the PR's workstream and becomes its identity")
    func prFirst() async throws {
        let service = try await service()
        try await service.ingest(GH.events(GH.pr(title: "[WEB-9295] fix: keep chevron beside label", head: "fix/WEB-9295-chevron")))
        try await service.ingest(PL.events(PL.item()))
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        #expect(workstreams.first?.planeItem?.identifier == "WEB-9295")
        #expect(workstreams.first?.title == "Customer property chevron")
    }

    @Test("A PR naming two tracked items is ambiguous: it doesn't guess, and the issue is recorded")
    func ambiguous() async throws {
        let service = try await service()
        try await service.ingest(PL.events(PL.item()) + PL.events(PL.item("WEB-1", name: "Other")))
        let report = try await service.ingest(GH.events(GH.pr(title: "[WEB-9295][WEB-1] combined", head: "combined")))
        #expect(report.createdWorkstreams.count == 1)
        #expect(report.unresolvedAssociations.contains { $0.kind == .ambiguous })
        #expect(await service.snapshot.unresolvedAssociations.isEmpty == false)
        #expect(await service.snapshot.workstreams.count == 3)
    }

    @Test("An explicit PR link is never re-pointed by a later mention")
    func explicitLinkWins() async throws {
        let service = try await service()
        try await service.ingest(GH.events(GH.pr(head: "chevron")))
        let prWorkstream = try #require(await service.snapshot.workstreams.first?.id)
        try await service.ingest(PL.events(PL.item()))
        // The PR is retitled to mention the item; its events still go to its own workstream.
        try await service.ingest(GH.events(GH.pr(title: "[WEB-9295] chevron", head: "chevron", updated: GH.at(5),
                                                 reviews: [GH.review(1, "APPROVED", by: "sarah", at: GH.at(5))])))
        let pr = await service.snapshot.workstreams.first { $0.id == prWorkstream }
        #expect(pr?.events.contains { $0.id == EventID(rawValue: "github:review:1") } == true)
        #expect(await service.snapshot.workstreams.count == 2)
    }

    @Test("A Claude session on the item's branch joins; an unrelated branch stays separate")
    func claudeLinking() async throws {
        let service = try await service()
        try await service.ingest(PL.events(PL.item()))
        try await service.ingest([claude("a", branch: "fix/WEB-9295-chevron")])
        try await service.ingest([claude("b", branch: "chore/unrelated")])
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 2)
        let item = workstreams.first { $0.planeItem != nil }
        #expect(item?.agentSessions.map(\.id) == ["claude:a"])
        #expect(item?.nextOwner == .agent)
    }

    @Test("A Claude-only workstream later acquires Plane identity, and the PR joins it too")
    func claudeFirst() async throws {
        let service = try await service()
        try await service.ingest([claude("a", branch: "fix/WEB-9295-chevron")])
        #expect(await service.snapshot.workstreams.first?.planeItem == nil)

        try await service.ingest(PL.events(PL.item()))
        try await service.ingest(GH.events(GH.pr(head: "fix/WEB-9295-chevron")))
        let workstreams = await service.snapshot.workstreams
        #expect(workstreams.count == 1)
        let ws = try #require(workstreams.first)
        #expect(ws.planeItem?.identifier == "WEB-9295")
        #expect(ws.title == "Customer property chevron")
        #expect(ws.pullRequest?.number == 421)
        #expect(ws.agentSessions.count == 1)
    }
}

/// Plane describes the work item's lifecycle; Tern decides who owns the next action.
@Suite("Plane vs Tern state")
struct PlaneStateSeparationTests {
    private func evaluate(_ plane: PlaneWorkItem, _ pr: GitHubPullRequest? = nil) async throws -> Workstream {
        let service = IngestionService(store: InMemoryTernStore(), now: { GH.t0 })
        try await service.start()
        try await service.ingest(PL.events(plane) + (pr.map { GH.events($0) } ?? []))
        return try #require(await service.snapshot.workstreams.first)
    }

    @Test("In Progress in Plane while a reviewer has the PR → waiting on the reviewer")
    func inProgressWaiting() async throws {
        let ws = try await evaluate(PL.item(state: PL.inProgress), GH.pr(head: "fix/WEB-9295-x", requests: [GH.reviewer("sarah")]))
        #expect(ws.nextOwner == .reviewer)
        #expect(ws.state == .waiting)
        #expect(ws.attention == .silent)
    }

    @Test("Todo in Plane while changes are requested → mine, high")
    func todoButMine() async throws {
        let ws = try await evaluate(PL.item(state: PL.todo), GH.pr(head: "fix/WEB-9295-x", reviews: [GH.review(1, "CHANGES_REQUESTED", by: "priya", at: GH.at(5))]))
        #expect(ws.nextOwner == .me)
        #expect(ws.attention == .high)
    }

    @Test("Done in Plane doesn't close a workstream whose PR is still open")
    func doneButPROpen() async throws {
        let ws = try await evaluate(PL.item(state: PL.done), GH.pr(head: "fix/WEB-9295-x", requests: [GH.reviewer("sarah")]))
        #expect(ws.state != .complete)
        #expect(ws.nextOwner == .reviewer)
    }

    @Test("Plane-only work shows its Plane state without inventing an owner")
    func planeOnly() async throws {
        let ws = try await evaluate(PL.item(state: PL.inReview))
        #expect(ws.nextOwner == .none)
        #expect(ws.attention == .silent)
        #expect(ws.status.headline == "In Review")
        #expect(try await evaluate(PL.item(state: PL.done)).state == .complete)
    }
}

/// Debug and Release builds keep their Plane tokens in separate Keychain namespaces.
/// Uses the real login keychain under a throwaway root, like the round-trip test above.
@Suite("Credential isolation", .serialized)
@MainActor
struct CredentialIsolationTests {
    private let root = "so.plane.tern.tests.\(UUID().uuidString)"

    private func store(_ environment: BuildEnvironment) -> KeychainPlaneCredentialStore {
        KeychainPlaneCredentialStore(keychain: KeychainStore(service: environment.keychainService("plane", root: root)))
    }

    private func cleanUp() {
        for environment in [BuildEnvironment.debug, .release] { try? store(environment).delete(for: "plane") }
    }

    @Test("Release keeps the original service; Debug has its own; this test host is Debug")
    func namespaces() {
        #expect(BuildEnvironment.release.keychainService("plane") == "so.plane.tern.plane")
        #expect(BuildEnvironment.debug.keychainService("plane") == "so.plane.tern.debug.plane")
        #expect(BuildEnvironment.current == .debug)
        #expect(KeychainPlaneCredentialStore().keychain.service == "so.plane.tern.debug.plane")
    }

    @Test("A Debug lookup never returns the Release token; Release finds its own")
    func debugCannotReadRelease() throws {
        defer { cleanUp() }
        try store(.release).save("plane_api_release_secret", for: "plane")
        #expect(try store(.debug).token(for: "plane") == nil)
        #expect(try store(.release).token(for: "plane") == "plane_api_release_secret")

        try store(.debug).save("plane_api_debug_secret", for: "plane")
        #expect(try store(.debug).token(for: "plane") == "plane_api_debug_secret")
        #expect(try store(.release).token(for: "plane") == "plane_api_release_secret")
    }

    @Test("Disconnecting deletes only this build's token, which never reaches defaults or logs")
    func disconnectDeletesOnlyOwnToken() async throws {
        defer { cleanUp() }
        let start = Date()
        try store(.release).save("plane_api_release_secret", for: "plane")
        let defaults = try #require(UserDefaults(suiteName: "tern-tests-\(UUID().uuidString)"))
        let ingestion = IngestionService(store: InMemoryTernStore())
        try await ingestion.start()
        let account = PlaneAccount(ingestion: ingestion, credentials: store(.debug), http: PlaneStub(),
                                   defaults: defaults, startSyncing: false, now: { PL.t0 })

        account.connect(workspace: "plane", token: "plane_api_valid_test_token")
        for _ in 0..<300 where !(try store(.debug).token(for: "plane") != nil) { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try store(.debug).token(for: "plane") == "plane_api_valid_test_token")

        account.disconnect()
        for _ in 0..<300 where try store(.debug).token(for: "plane") != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(try store(.debug).token(for: "plane") == nil)
        #expect(try store(.release).token(for: "plane") == "plane_api_release_secret")

        let secrets = ["plane_api_valid_test_token", "plane_api_release_secret"]
        let visible = [
            defaults.dictionaryRepresentation().description,
            String(describing: account.state),
            String(describing: account.sync),
            String(describing: store(.debug)),
        ]
        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(at: log.position(date: start)).compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "so.plane.tern" }.map(\.composedMessage)
        for secret in secrets {
            #expect(!visible.contains { $0.contains(secret) })
            #expect(!messages.contains { $0.contains(secret) })
        }
    }
}
