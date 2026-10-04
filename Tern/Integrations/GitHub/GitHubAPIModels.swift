import Foundation

// Decodable shapes of the GraphQL responses in `GitHubQueries`. Only fields Tern uses.
// No comment bodies, review bodies or file contents are requested.

struct GitHubGraphQLResponse<Payload: Decodable & Sendable>: Decodable, Sendable {
    let data: Payload?
    let errors: [GitHubGraphQLError]?
}

struct GitHubGraphQLError: Codable, Sendable, Hashable {
    let type: String?
    let message: String
}

struct GitHubRateLimit: Codable, Sendable, Hashable {
    let cost: Int
    let remaining: Int
    let resetAt: Date
}

struct GitHubNodes<Node: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    let nodes: [Node?]

    var items: [Node] { nodes.compactMap { $0 } }
}

struct GitHubCount: Codable, Sendable, Hashable {
    let totalCount: Int
}

// MARK: - Index

struct GitHubIndexPayload: Codable, Sendable {
    struct Viewer: Codable, Sendable, Hashable {
        let login: String
        let databaseId: Int?
    }

    let viewer: Viewer
    let rateLimit: GitHubRateLimit
    let authored: GitHubNodes<GitHubIndexPullRequest>
    let requested: GitHubNodes<GitHubIndexPullRequest>
    let known: [GitHubIndexPullRequest?]
}

/// Search results can contain non-PR nodes, which decode as empty objects; every field is optional.
struct GitHubIndexPullRequest: Codable, Sendable, Hashable {
    struct Repository: Codable, Sendable, Hashable { let nameWithOwner: String }
    struct Rollup: Codable, Sendable, Hashable { let state: String }

    let id: String?
    let updatedAt: Date?
    let headRefOid: String?
    let isDraft: Bool?
    let state: String?
    let repository: Repository?
    let reviewRequests: GitHubCount?
    let statusCheckRollup: Rollup?
    var labels: GitHubNodes<GitHubLabel>? = nil

    /// Changes whenever something Tern cares about may have changed.
    var fingerprint: String {
        [
            updatedAt.map { String($0.timeIntervalSince1970) } ?? "-",
            headRefOid ?? "-",
            isDraft.map(String.init) ?? "-",
            state ?? "-",
            String(reviewRequests?.totalCount ?? -1),
            statusCheckRollup?.state ?? "-",
            (labels?.items.map(\.name).sorted() ?? []).joined(separator: ","),
        ].joined(separator: "|")
    }
}

// MARK: - Detail

struct GitHubDetailPayload: Codable, Sendable {
    let rateLimit: GitHubRateLimit
    let nodes: [GitHubPullRequest?]
}

struct GitHubActor: Codable, Sendable, Hashable {
    let typename: String?
    let login: String

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login
    }

    init(login: String, typename: String? = "User") {
        self.login = login
        self.typename = typename
    }

    var isBot: Bool { typename == "Bot" || login.hasSuffix("[bot]") }
}

struct GitHubRequestedReviewer: Codable, Sendable, Hashable {
    let typename: String?
    let login: String?
    let slug: String?

    enum CodingKeys: String, CodingKey {
        case typename = "__typename"
        case login, slug
    }

    init(login: String? = nil, slug: String? = nil, typename: String? = nil) {
        self.login = login
        self.slug = slug
        self.typename = typename ?? (slug != nil ? "Team" : "User")
    }

    var isTeam: Bool { typename == "Team" }
    var isBot: Bool { typename == "Bot" || (login?.hasSuffix("[bot]") ?? false) }
    /// Stable key: a login, or `team:<slug>`.
    var key: String? { login ?? slug.map { "team:\($0)" } }
}

struct GitHubPullRequest: Codable, Sendable, Hashable {
    struct Repository: Codable, Sendable, Hashable {
        let databaseId: Int
        let nameWithOwner: String
    }

    struct HeadRepository: Codable, Sendable, Hashable {
        let nameWithOwner: String
    }

    struct ReviewRequest: Codable, Sendable, Hashable {
        let requestedReviewer: GitHubRequestedReviewer?
    }

    struct Review: Codable, Sendable, Hashable {
        struct CommitRef: Codable, Sendable, Hashable { let oid: String }

        let databaseId: Int
        /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`, `PENDING`.
        let state: String
        let submittedAt: Date?
        let author: GitHubActor?
        /// The head commit the review was submitted on.
        let commit: CommitRef?
    }

    struct Comment: Codable, Sendable, Hashable {
        let databaseId: Int
        let createdAt: Date
        let author: GitHubActor?
    }

    struct ReviewThread: Codable, Sendable, Hashable {
        struct Resolver: Codable, Sendable, Hashable { let login: String }

        let id: String
        let isResolved: Bool
        let resolvedBy: Resolver?
        let comments: GitHubNodes<Comment>
    }

    struct TimelineItem: Codable, Sendable, Hashable {
        struct ReviewReference: Codable, Sendable, Hashable { let databaseId: Int? }

        let typename: String
        let id: String?
        let createdAt: Date?
        let actor: GitHubActor?
        let requestedReviewer: GitHubRequestedReviewer?
        let review: ReviewReference?
        /// Labeled and unlabeled events.
        var label: GitHubLabel? = nil

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case id, createdAt, actor, requestedReviewer, review, label
        }
    }

    struct CommitNode: Codable, Sendable, Hashable {
        struct Commit: Codable, Sendable, Hashable {
            struct Author: Codable, Sendable, Hashable {
                struct User: Codable, Sendable, Hashable { let login: String }
                let user: User?
            }

            let oid: String
            let committedDate: Date
            let author: Author?
        }

        let commit: Commit
    }

    struct CheckContext: Codable, Sendable, Hashable {
        let typename: String
        // CheckRun
        let databaseId: Int?
        let name: String?
        let status: String?
        let conclusion: String?
        let startedAt: Date?
        let completedAt: Date?
        // StatusContext
        let id: String?
        let context: String?
        let state: String?
        let createdAt: Date?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case databaseId, name, status, conclusion, startedAt, completedAt, id, context, state, createdAt
        }
    }

    struct Rollup: Codable, Sendable, Hashable {
        let contexts: GitHubNodes<CheckContext>
    }

    let id: String
    let number: Int
    let title: String
    /// Only scanned for Plane links; never stored.
    let body: String?
    let url: URL
    let isDraft: Bool
    /// `OPEN`, `CLOSED`, `MERGED`.
    let state: String
    let merged: Bool
    let createdAt: Date
    let updatedAt: Date
    let author: GitHubActor?
    let headRefName: String
    let headRefOid: String
    let baseRefName: String
    let repository: Repository
    let headRepository: HeadRepository?
    let reviewRequests: GitHubNodes<ReviewRequest>
    let reviews: GitHubNodes<Review>
    let reviewThreads: GitHubNodes<ReviewThread>
    let comments: GitHubNodes<Comment>
    let timelineItems: GitHubNodes<TimelineItem>
    let commits: GitHubNodes<CommitNode>
    let statusCheckRollup: Rollup?
    /// Labels currently on the pull request.
    var labels: GitHubNodes<GitHubLabel>? = nil
}

struct GitHubLabel: Codable, Sendable, Hashable {
    let name: String
}
