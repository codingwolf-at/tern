import Foundation
@testable import Tern

/// Builders for GitHub API values, so tests read like the situations they describe.
enum GH {
    static let me = "atul"
    static let repo = "acme/web"
    static let repoID = 100
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }
    static func user(_ login: String) -> GitHubActor { GitHubActor(login: login) }
    static func reviewer(_ login: String) -> GitHubRequestedReviewer { GitHubRequestedReviewer(login: login) }
    static func team(_ slug: String) -> GitHubRequestedReviewer { GitHubRequestedReviewer(slug: slug) }

    static func pr(
        id: String = "PR_1",
        number: Int = 421,
        title: String = "Avatar migration",
        body: String? = nil,
        author: String = me,
        head: String = "feat/avatar-migration",
        headSHA: String = "sha1",
        isDraft: Bool = false,
        state: String = "OPEN",
        merged: Bool = false,
        created: Date = at(0),
        updated: Date = at(0),
        requests: [GitHubRequestedReviewer] = [],
        reviews: [GitHubPullRequest.Review] = [],
        threads: [GitHubPullRequest.ReviewThread] = [],
        comments: [GitHubPullRequest.Comment] = [],
        timeline: [GitHubPullRequest.TimelineItem] = [],
        checks: [GitHubPullRequest.CheckContext] = [],
        commitAt: Date? = nil
    ) -> GitHubPullRequest {
        GitHubPullRequest(
            id: id,
            number: number,
            title: title,
            body: body,
            url: URL(string: "https://github.com/\(repo)/pull/\(number)")!,
            isDraft: isDraft,
            state: state,
            merged: merged,
            createdAt: created,
            updatedAt: updated,
            author: user(author),
            headRefName: head,
            headRefOid: headSHA,
            baseRefName: "main",
            repository: .init(databaseId: repoID, nameWithOwner: repo),
            headRepository: .init(nameWithOwner: repo),
            reviewRequests: GitHubNodes(nodes: requests.map { .init(requestedReviewer: $0) }),
            reviews: GitHubNodes(nodes: reviews),
            reviewThreads: GitHubNodes(nodes: threads),
            comments: GitHubNodes(nodes: comments),
            timelineItems: GitHubNodes(nodes: timeline),
            commits: GitHubNodes(nodes: [.init(commit: .init(oid: headSHA, committedDate: commitAt ?? created, author: .init(user: .init(login: author))))]),
            statusCheckRollup: checks.isEmpty ? nil : .init(contexts: GitHubNodes(nodes: checks))
        )
    }

    static func review(_ id: Int, _ state: String, by login: String, at date: Date, on commit: String? = nil) -> GitHubPullRequest.Review {
        .init(databaseId: id, state: state, submittedAt: date, author: user(login), commit: commit.map { .init(oid: $0) })
    }

    static func comment(_ id: Int, by login: String, at date: Date) -> GitHubPullRequest.Comment {
        .init(databaseId: id, createdAt: date, author: user(login))
    }

    static func thread(_ id: String, last: GitHubPullRequest.Comment, resolvedBy: String? = nil) -> GitHubPullRequest.ReviewThread {
        .init(id: id, isResolved: resolvedBy != nil, resolvedBy: resolvedBy.map { .init(login: $0) }, comments: GitHubNodes(nodes: [last]))
    }

    static func timeline(
        _ type: String,
        id: String,
        at date: Date,
        actor: String = me,
        reviewer: GitHubRequestedReviewer? = nil,
        dismissedReview: Int? = nil
    ) -> GitHubPullRequest.TimelineItem {
        .init(typename: type, id: id, createdAt: date, actor: user(actor), requestedReviewer: reviewer, review: dismissedReview.map { .init(databaseId: $0) })
    }

    static func check(_ id: Int, _ name: String, status: String = "COMPLETED", conclusion: String? = "SUCCESS", at date: Date) -> GitHubPullRequest.CheckContext {
        .init(typename: "CheckRun", databaseId: id, name: name, status: status, conclusion: status == "COMPLETED" ? conclusion : nil,
              startedAt: date, completedAt: status == "COMPLETED" ? date : nil, id: nil, context: nil, state: nil, createdAt: nil)
    }

    static func status(_ id: String, _ context: String, state: String, at date: Date) -> GitHubPullRequest.CheckContext {
        .init(typename: "StatusContext", databaseId: nil, name: nil, status: nil, conclusion: nil,
              startedAt: nil, completedAt: nil, id: id, context: context, state: state, createdAt: date)
    }

    static func events(_ pr: GitHubPullRequest, requested: Bool = false) -> [ObservedEvent] {
        GitHubNormalizer(viewerLogin: me).events(for: pr, requestedViaSearch: requested)
    }
}

/// A fake `gh` that answers Tern's index and detail queries from `pullRequests`, and
/// `gh auth status` from `auth`.
final class FakeGitHubCLI: GitHubCLIRunner, @unchecked Sendable {
    struct State {
        var viewer = GH.me
        var pullRequests: [GitHubPullRequest] = []
        /// Pull requests that show up in the "review requested from me" search.
        var reviewRequested: Set<String> = []
        var auth: Auth = .loggedIn
        var failure: Failure?
        var detailRequests = 0
        var indexRequests = 0
        var authChecks = 0
        var rateLimitRemaining = 4000
        var invocations: [[String]] = []
    }

    enum Auth {
        case loggedIn
        case loggedOut
        case rejected
    }

    enum Failure {
        case notInstalled
        case exit(Int32, stderr: String, stdout: String = "")
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) {
        lock.withLock { body(&state) }
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.withLock { body(state) }
    }

    func run(_ arguments: [String], input: Data?) async throws(GitHubAPIError) -> GitHubCLIOutput {
        update { $0.invocations.append(arguments) }
        let snapshot = read { $0 }
        switch snapshot.failure {
        case .notInstalled:
            throw .cliNotFound
        case .exit(let code, let stderr, let stdout):
            return GitHubCLIOutput(stdout: Data(stdout.utf8), stderr: stderr, exitCode: code)
        case nil:
            break
        }

        if arguments.starts(with: ["auth", "status"]) {
            update { $0.authChecks += 1 }
            return authStatus(snapshot.auth)
        }
        if snapshot.auth != .loggedIn {
            return GitHubCLIOutput(stdout: Data(), stderr: "To get started with GitHub CLI, please run:  gh auth login", exitCode: 4)
        }
        do {
            return GitHubCLIOutput(stdout: try graphQL(input ?? Data(), snapshot), stderr: "", exitCode: 0)
        } catch {
            return GitHubCLIOutput(stdout: Data(), stderr: "gh: bad request", exitCode: 1)
        }
    }

    /// Mirrors `gh auth status --json hosts`, including the token-source label.
    private func authStatus(_ auth: Auth) -> GitHubCLIOutput {
        let json: String
        switch auth {
        case .loggedIn:
            json = #"{"hosts":{"github.com":[{"state":"success","active":true,"host":"github.com","login":"\#(GH.me)","tokenSource":"keyring","scopes":"repo, read:org","gitProtocol":"https"}]}}"#
        case .loggedOut:
            return GitHubCLIOutput(stdout: Data(#"{"hosts":{}}"#.utf8), stderr: "You are not logged into any GitHub hosts. To log in, run: gh auth login", exitCode: 0)
        case .rejected:
            json = #"{"hosts":{"github.com":[{"state":"error","error":"401 Unauthorized","active":true,"host":"github.com","login":"","tokenSource":"GH_TOKEN"}]}}"#
        }
        return GitHubCLIOutput(stdout: Data(json.utf8), stderr: "", exitCode: 0)
    }

    private func graphQL(_ input: Data, _ snapshot: State) throws -> Data {
        let body = try JSONSerialization.jsonObject(with: input) as? [String: Any] ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        update { if query.contains("TernIndex") { $0.indexRequests += 1 } else { $0.detailRequests += 1 } }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rateLimit = GitHubRateLimit(cost: 1, remaining: snapshot.rateLimitRemaining, resetAt: GH.at(60))
        let payload: Data
        if query.contains("TernIndex") {
            let known = Set(variables["known"] as? [String] ?? [])
            let open = snapshot.pullRequests.filter { $0.state == "OPEN" }
            payload = try encoder.encode(GitHubIndexPayload(
                viewer: .init(login: snapshot.viewer, databaseId: 1),
                rateLimit: rateLimit,
                authored: GitHubNodes(nodes: open.filter { $0.author?.login == snapshot.viewer }.map(Self.index)),
                requested: GitHubNodes(nodes: open.filter { snapshot.reviewRequested.contains($0.id) }.map(Self.index)),
                known: snapshot.pullRequests.filter { known.contains($0.id) }.map(Self.index)
            ))
        } else {
            let ids = variables["ids"] as? [String] ?? []
            payload = try encoder.encode(GitHubDetailPayload(rateLimit: rateLimit, nodes: ids.map { id in snapshot.pullRequests.first { $0.id == id } }))
        }
        return Data("{\"data\":".utf8) + payload + Data("}".utf8)
    }

    private static func index(_ pr: GitHubPullRequest) -> GitHubIndexPullRequest {
        GitHubIndexPullRequest(
            id: pr.id,
            updatedAt: pr.updatedAt,
            headRefOid: pr.headRefOid,
            isDraft: pr.isDraft,
            state: pr.state,
            repository: .init(nameWithOwner: pr.repository.nameWithOwner),
            reviewRequests: GitHubCount(totalCount: pr.reviewRequests.items.count),
            statusCheckRollup: nil
        )
    }
}

/// Sync service wired to a fake `gh` and an in-memory ingestion service.
struct GitHubHarness {
    let github: FakeGitHubCLI
    let store: InMemoryTernStore
    let ingestion: IngestionService
    let sync: GitHubSyncService

    init() async throws {
        let store = InMemoryTernStore()
        let ingestion = IngestionService(store: store, now: { GH.t0 })
        try await ingestion.start()
        self.init(github: FakeGitHubCLI(), store: store, ingestion: ingestion)
    }

    /// The same GitHub and store, as if Tern relaunched.
    func relaunched() async throws -> GitHubHarness {
        let ingestion = IngestionService(store: store, now: { GH.t0 })
        try await ingestion.start()
        return GitHubHarness(github: github, store: store, ingestion: ingestion)
    }

    private init(github: FakeGitHubCLI, store: InMemoryTernStore, ingestion: IngestionService) {
        self.github = github
        self.store = store
        self.ingestion = ingestion
        self.sync = GitHubSyncService(cli: GitHubCLI(runner: github, now: { GH.t0 }), ingestion: ingestion, now: { GH.t0 })
    }

    func workstream(_ title: String = "Avatar migration") async -> Workstream? {
        await ingestion.snapshot.workstreams.first { $0.title == title }
    }

    func notificationCount() async -> Int {
        await ingestion.snapshot.notifications.count
    }
}
