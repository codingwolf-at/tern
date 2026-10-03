import Foundation
import Synchronization
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

    static func review(_ id: Int, _ state: String, by login: String, at date: Date) -> GitHubPullRequest.Review {
        .init(databaseId: id, state: state, submittedAt: date, author: user(login))
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

/// An in-memory GitHub that answers Tern's index and detail queries from `pullRequests`.
final class StubGitHub: GitHubHTTP, @unchecked Sendable {
    struct State {
        var viewer = GH.me
        var pullRequests: [GitHubPullRequest] = []
        /// Pull requests that show up in the "review requested from me" search.
        var reviewRequested: Set<String> = []
        var failure: Failure?
        var detailRequests = 0
        var indexRequests = 0
        var rateLimitRemaining = 4000
        var lastToken: String?
    }

    enum Failure {
        case status(Int, headers: [String: String])
        case offline
    }

    private let lock = NSLock()
    private var state = State()

    func update(_ body: (inout State) -> Void) {
        lock.withLock { body(&state) }
    }

    func read<T>(_ body: (State) -> T) -> T {
        lock.withLock { body(state) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any] ?? [:]
        let query = body["query"] as? String ?? ""
        let variables = body["variables"] as? [String: Any] ?? [:]
        update { state in
            state.lastToken = request.value(forHTTPHeaderField: "Authorization")
            if query.contains("TernIndex") { state.indexRequests += 1 } else { state.detailRequests += 1 }
        }
        let snapshot = read { $0 }

        switch snapshot.failure {
        case .offline:
            throw URLError(.notConnectedToInternet)
        case .status(let code, let headers):
            return (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
        case nil:
            break
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let rateLimit = GitHubRateLimit(cost: 1, remaining: snapshot.rateLimitRemaining, resetAt: GH.at(60))
        let payload: Data
        if query.contains("TernIndex") {
            let known = Set(variables["known"] as? [String] ?? [])
            let open = snapshot.pullRequests.filter { $0.state == "OPEN" }
            let index = GitHubIndexPayload(
                viewer: .init(login: snapshot.viewer, databaseId: 1),
                rateLimit: rateLimit,
                authored: GitHubNodes(nodes: open.filter { $0.author?.login == snapshot.viewer }.map(Self.index)),
                requested: GitHubNodes(nodes: open.filter { snapshot.reviewRequested.contains($0.id) }.map(Self.index)),
                known: snapshot.pullRequests.filter { known.contains($0.id) }.map(Self.index)
            )
            payload = try encoder.encode(index)
        } else {
            let ids = variables["ids"] as? [String] ?? []
            let detail = GitHubDetailPayload(rateLimit: rateLimit, nodes: ids.map { id in snapshot.pullRequests.first { $0.id == id } })
            payload = try encoder.encode(detail)
        }
        let wrapped = Data("{\"data\":".utf8) + payload + Data("}".utf8)
        return (wrapped, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
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

final class InMemoryCredentialStore: GitHubCredentialStore {
    let credential: Mutex<GitHubCredential?>

    init(_ credential: GitHubCredential? = nil) {
        self.credential = Mutex(credential)
    }

    func load() -> GitHubCredential? { credential.withLock { $0 } }
    func save(_ credential: GitHubCredential) { self.credential.withLock { $0 = credential } }
    func delete() { credential.withLock { $0 = nil } }
}

final class InMemoryBookmarks: GitHubSyncBookmarks {
    let logins = Mutex<Set<String>>([])

    func hasImported(_ login: String) -> Bool { logins.withLock { $0.contains(login.lowercased()) } }
    func markImported(_ login: String) { logins.withLock { _ = $0.insert(login.lowercased()) } }
    func clear() { logins.withLock { $0.removeAll() } }
}

/// Sync service wired to a stub GitHub and an in-memory ingestion service.
struct GitHubHarness {
    let github: StubGitHub
    let credentials: InMemoryCredentialStore
    let bookmarks: InMemoryBookmarks
    let store: InMemoryTernStore
    let ingestion: IngestionService
    let sync: GitHubSyncService

    init() async throws {
        let store = InMemoryTernStore()
        let ingestion = IngestionService(store: store, now: { GH.t0 })
        try await ingestion.start()
        self.init(
            github: StubGitHub(),
            credentials: InMemoryCredentialStore(GitHubCredential(accessToken: "gho_test_secret_token")),
            bookmarks: InMemoryBookmarks(),
            store: store,
            ingestion: ingestion
        )
    }

    /// The same GitHub, credentials and store, as if Tern relaunched.
    func relaunched() async throws -> GitHubHarness {
        let ingestion = IngestionService(store: store, now: { GH.t0 })
        try await ingestion.start()
        return GitHubHarness(github: github, credentials: credentials, bookmarks: bookmarks, store: store, ingestion: ingestion)
    }

    private init(github: StubGitHub, credentials: InMemoryCredentialStore, bookmarks: InMemoryBookmarks, store: InMemoryTernStore, ingestion: IngestionService) {
        self.store = store
        self.ingestion = ingestion
        self.sync = GitHubSyncService(
            client: GitHubClient(http: github, now: { GH.t0 }),
            credentials: credentials,
            deviceFlow: nil,
            ingestion: ingestion,
            bookmarks: bookmarks,
            now: { GH.t0 }
        )
        self.github = github
        self.credentials = credentials
        self.bookmarks = bookmarks
    }

    func workstream(_ title: String = "Avatar migration") async -> Workstream? {
        await ingestion.snapshot.workstreams.first { $0.title == title }
    }

    func notificationCount() async -> Int {
        await ingestion.snapshot.notifications.count
    }
}
