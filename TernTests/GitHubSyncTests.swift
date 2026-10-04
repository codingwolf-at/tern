import Foundation
import OSLog
import Testing
@testable import Tern

@Suite("GitHub sync", .serialized)
struct GitHubSyncTests {
    @Test("First sync imports history silently and learns who I am from gh")
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
        #expect(status.isAuthenticated == true)
        #expect(status.authoredOpen == 1)
        #expect(status.reviewRequests == 1)
        #expect(status.repositories == 1)
        #expect(await h.notificationCount() == 0)
        #expect(await h.workstream()?.attention == .high)
        #expect(await h.workstream("Rate limiter")?.nextOwner == .me)
        #expect(h.bookmarks.hasImported(GH.me))
    }

    @Test("Queries go through `gh api graphql` with the body on stdin")
    func invocations() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()] }
        await h.sync.syncOnce()
        let calls = h.github.read { $0.invocations }
        #expect(calls.first == ["auth", "status", "--active", "--hostname", "github.com", "--json", "hosts"])
        #expect(calls.dropFirst().allSatisfy { $0 == ["api", "graphql", "--hostname", "github.com", "--input", "-"] })
        #expect(!calls.flatMap { $0 }.contains("token") && !calls.flatMap { $0 }.contains("--show-token"))

        // Once healthy, polls don't re-check auth.
        await h.sync.syncOnce()
        #expect(h.github.read { $0.authChecks } == 1)
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

        let relaunched = try await h.relaunched()
        await relaunched.sync.syncOnce()
        #expect(h.github.read { $0.detailRequests } == detailFetches + 1)
        #expect(await relaunched.workstream()?.events == before?.events)
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

    @Test("Missing gh is reported and recovers once installed")
    func missingCLI() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.failure = .notInstalled }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .cliUnavailable)
        #expect(status.isCLIAvailable == false)
        #expect(status.lastError == "GitHub CLI not found")

        h.github.update { $0.failure = nil; $0.pullRequests = [GH.pr()] }
        #expect(await h.sync.syncOnce().phase == .idle)
    }

    @Test("A logged-out or rejected gh session is not authenticated; state is kept")
    func notAuthenticated() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr(requests: [GH.reviewer("sarah")])] }
        await h.sync.syncOnce()

        // Session expires mid-way: the API call fails with exit 4.
        h.github.update { $0.auth = .loggedOut }
        var status = await h.sync.syncOnce()
        #expect(status.phase == .notAuthenticated)
        #expect(status.login == nil)
        #expect(await h.workstream()?.nextOwner == .reviewer)

        h.github.update { $0.auth = .rejected }
        status = await h.sync.syncOnce()
        #expect(status.phase == .notAuthenticated)

        // `gh auth login` in a terminal; the next poll recovers.
        h.github.update { $0.auth = .loggedIn }
        status = await h.sync.syncOnce()
        #expect(status.phase == .idle)
        #expect(status.login == GH.me)
    }

    @Test("Network, rate-limit and API failures are reported, not fatal")
    func failures() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()] }
        await h.sync.syncOnce()

        h.github.update { $0.failure = .exit(1, stderr: #"Post "https://api.github.com/graphql": dial tcp: lookup api.github.com: no such host"#) }
        var status = await h.sync.syncOnce()
        #expect(status.phase == .failing)
        #expect(status.lastError == "Network: unreachable")

        h.github.update { $0.failure = .exit(1, stderr: "gh: API rate limit exceeded for user ID 1. (HTTP 403)") }
        status = await h.sync.syncOnce()
        #expect(status.phase == .rateLimited(until: GH.t0.addingTimeInterval(15 * 60)))

        h.github.update { $0.failure = .exit(1, stderr: "gh: Something went wrong (HTTP 502)") }
        status = await h.sync.syncOnce()
        #expect(status.lastError == "GitHub: Something went wrong (HTTP 502)")

        h.github.update { $0.failure = .exit(0, stderr: "", stdout: "not json") }
        status = await h.sync.syncOnce()
        #expect(status.lastError == "Unexpected output from GitHub CLI")

        h.github.update { $0.failure = nil }
        #expect(await h.sync.syncOnce().phase == .idle)
        #expect(await h.workstream() != nil)
    }

    @Test("Low remaining rate limit pauses before fetching details")
    func lowRateLimit() async throws {
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()]; $0.rateLimitRemaining = 10 }
        let status = await h.sync.syncOnce()
        #expect(status.phase == .rateLimited(until: GH.at(60)))
        #expect(h.github.read { $0.detailRequests } == 0)
    }
}

@Suite("GitHub CLI")
struct GitHubCLITests {
    private func output(_ code: Int32, stderr: String = "", stdout: String = "") -> GitHubCLIOutput {
        GitHubCLIOutput(stdout: Data(stdout.utf8), stderr: stderr, exitCode: code)
    }

    @Test("Failures are classified from exit status and stderr")
    func classify() {
        let now = GH.t0
        #expect(GitHubCLI.classify(output(4, stderr: "To get started with GitHub CLI, please run:  gh auth login"), now: now) == .notAuthenticated)
        #expect(GitHubCLI.classify(output(1, stderr: "gh: Bad credentials (HTTP 401)"), now: now) == .notAuthenticated)
        #expect(GitHubCLI.classify(output(1, stderr: #"Post "https://api.github.com/graphql": net/http: TLS handshake timeout"#), now: now) == .network("timed out"))
        #expect(GitHubCLI.classify(output(1, stderr: "dial tcp 127.0.0.1:9: connect: connection refused"), now: now) == .network("unreachable"))
        #expect(GitHubCLI.classify(output(1, stderr: "gh: API rate limit exceeded"), now: now) == .rateLimited(until: now.addingTimeInterval(900)))
        #expect(GitHubCLI.classify(output(1, stderr: "gh: Not Found (HTTP 404)\nmore"), now: now) == .api("Not Found (HTTP 404)"))
        #expect(GitHubCLI.classify(output(0, stdout: "<html>"), now: now) == .malformedOutput)
        #expect(GitHubCLI.classify(output(1, stderr: "gh: odd failure with ghp_abc123XYZ and github_pat_11AA_bb"), now: now)
            == .api("odd failure with ghp_<redacted> and github_pat_<redacted>"))
    }

    @Test("Partial GraphQL errors still return data, as gh exits non-zero with JSON on stdout")
    func partialErrors() async throws {
        struct Runner: GitHubCLIRunner {
            func run(_ arguments: [String], input: Data?) async throws(GitHubAPIError) -> GitHubCLIOutput {
                let json = #"{"data":{"viewer":{"login":"atul","databaseId":1}},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a node"}]}"#
                return GitHubCLIOutput(stdout: Data(json.utf8), stderr: "gh: Could not resolve to a node", exitCode: 1)
            }
        }
        struct Viewer: Decodable, Sendable { struct V: Decodable, Sendable { let login: String }; let viewer: V }
        let (payload, errors) = try await GitHubCLI(runner: Runner()).graphQL("{viewer{login}}", variables: [:], as: Viewer.self)
        #expect(payload.viewer.login == "atul")
        #expect(errors.map(\.type) == ["NOT_FOUND"])
    }

    @Test("Auth status reads the active github.com account, never a token")
    func authStatus() async throws {
        let fake = FakeGitHubCLI()
        let cli = GitHubCLI(runner: fake)
        let status = try await cli.authStatus()
        #expect(status == GitHubAuthStatus(host: "github.com", login: GH.me, isAuthenticated: true, tokenSource: "keyring"))

        fake.update { $0.auth = .loggedOut }
        #expect(try await cli.authStatus().isAuthenticated == false)
        fake.update { $0.auth = .rejected }
        let rejected = try await cli.authStatus()
        #expect(rejected.isAuthenticated == false)
        #expect(rejected.login == nil)
    }

    @Test("gh is found on PATH, then in common install locations, else not at all")
    func locator() {
        let homebrew = GitHubCLILocator(environment: ["PATH": "/usr/bin:/bin"], homeDirectory: "/Users/me", isExecutable: { $0 == "/opt/homebrew/bin/gh" })
        #expect(homebrew.locate()?.path == "/opt/homebrew/bin/gh")

        let onPath = GitHubCLILocator(environment: ["PATH": "/custom/bin:/usr/bin"], homeDirectory: "/Users/me", isExecutable: { $0 == "/custom/bin/gh" || $0 == "/opt/homebrew/bin/gh" })
        #expect(onPath.locate()?.path == "/custom/bin/gh")

        let override = GitHubCLILocator(environment: ["TERN_GH_PATH": "/tools/gh"], homeDirectory: "/Users/me", isExecutable: { _ in true })
        #expect(override.locate()?.path == "/tools/gh")

        let none = GitHubCLILocator(environment: [:], homeDirectory: "/Users/me", isExecutable: { _ in false })
        #expect(none.locate() == nil)
    }

    @Test("A missing gh is a clear error, with no fallback")
    func missing() async {
        let runner = ProcessGitHubCLIRunner(locator: GitHubCLILocator(environment: [:], homeDirectory: "/nonexistent", isExecutable: { _ in false }))
        await #expect(throws: GitHubAPIError.cliNotFound) { try await runner.run(["api", "user"], input: nil) }
    }

    @Test("The process runner captures stdout, stderr, exit status and stdin — even for large output")
    func processRunner() async throws {
        let script = FileManager.default.temporaryDirectory.appending(path: "fake-gh-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: script) }
        try """
        #!/bin/sh
        cat > /dev/null
        echo "prompt=$GH_PROMPT_DISABLED args=$*" >&2
        head -c 1048576 /dev/zero | tr '\\0' 'a'
        exit 3
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let runner = ProcessGitHubCLIRunner(locator: GitHubCLILocator(environment: ["TERN_GH_PATH": script.path], homeDirectory: "/", isExecutable: { $0 == script.path }))
        let result = try await runner.run(["api", "graphql"], input: Data(repeating: 1, count: 200_000))
        #expect(result.exitCode == 3)
        #expect(result.stdout.count == 1_048_576)
        #expect(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines) == "prompt=1 args=api graphql")
    }
}

@Suite("GitHub privacy", .serialized)
struct GitHubPrivacyTests {
    @Test("No credential reaches app state, defaults, diagnostics or logs")
    func noCredentials() async throws {
        let start = Date()
        let secret = "gho_FakeSecretTokenValue1234567890"
        let h = try await GitHubHarness()
        h.github.update { $0.pullRequests = [GH.pr()] }
        await h.sync.syncOnce()
        // Even if gh printed something token-like on failure, it must not travel further than the error summary.
        h.github.update { $0.failure = .exit(1, stderr: "gh: request failed for token \(secret) (HTTP 401)") }
        let failed = await h.sync.syncOnce()

        let state = String(decoding: try JSONEncoder().encode(h.store.load()), as: UTF8.self)
        let diagnostics = String(describing: failed) + String(describing: await h.sync.status)
        let defaults = UserDefaults.standard.dictionaryRepresentation().description
        #expect(!state.contains("gho_"))
        #expect(!diagnostics.contains(secret))
        #expect(!defaults.contains(secret))

        let log = try OSLogStore(scope: .currentProcessIdentifier)
        let messages = try log.getEntries(at: log.position(date: start))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "so.plane.tern" }
            .map(\.composedMessage)
        #expect(messages.contains { $0.contains("GitHub CLI is not authenticated") })
        #expect(!messages.contains { $0.contains(secret) })
    }
}

@Suite("GitHub account status", .serialized)
@MainActor
struct GitHubAccountTests {
    private func account(_ configure: (FakeGitHubCLI) -> Void) async throws -> GitHubAccount {
        let fake = FakeGitHubCLI()
        configure(fake)
        let account = GitHubAccount(
            ingestion: IngestionService(store: InMemoryTernStore()),
            cli: GitHubCLI(runner: fake),
            bookmarks: InMemoryBookmarks(),
            startSyncing: false
        )
        account.refresh()
        for _ in 0..<300 where account.state == .checking {
            try await Task.sleep(for: .milliseconds(10))
        }
        return account
    }

    @Test("Connection states mirror what gh can do")
    func states() async throws {
        #expect(try await account { _ in }.state == .connected(login: GH.me))
        #expect(try await account { $0.update { $0.failure = .notInstalled } }.state == .cliUnavailable)
        #expect(try await account { $0.update { $0.auth = .loggedOut } }.state == .notAuthenticated)
    }
}
