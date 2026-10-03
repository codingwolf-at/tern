import Foundation

/// A pointer to something in an external system that a workstream can be linked to.
/// Integrations attach these to events so ingestion can work out which workstream
/// the event belongs to, independently of the event's own identity.
struct ExternalReference: Hashable, Sendable, Codable {
    let kind: String
    let value: String

    static func planeItem(_ identifier: String) -> ExternalReference {
        ExternalReference(kind: "plane.item", value: identifier)
    }

    static func pullRequest(repository: String, number: Int) -> ExternalReference {
        ExternalReference(kind: "github.pr", value: "\(repository.lowercased())#\(number)")
    }

    /// One agent session, namespaced by provider (e.g. `claude`).
    static func agentSession(provider: String, id: String) -> ExternalReference {
        ExternalReference(kind: "agent.session", value: "\(provider):\(id)")
    }

    static func workingDirectory(_ path: String) -> ExternalReference {
        ExternalReference(kind: "fs.directory", value: path)
    }

    /// A branch in a repository. `repository` is `github.com/owner/name` when the repository is
    /// on GitHub (so local sessions and pull requests agree), otherwise a local path.
    static func branch(_ name: String, repository: String) -> ExternalReference {
        ExternalReference(kind: "git.branch", value: "\(repository.lowercased())@\(name)")
    }

    /// Canonical repository identity for a GitHub `owner/name`.
    static func gitHubRepository(_ nameWithOwner: String) -> String {
        "github.com/\(nameWithOwner)"
    }
}

/// An event as an integration reports it, before it is linked to a workstream.
struct ObservedEvent: Hashable, Sendable {
    let id: EventID
    let source: EventSource
    let kind: WorkEventKind
    let timestamp: Date
    let metadata: [String: String]
    /// Everything the event is known to relate to, most specific first.
    let references: [ExternalReference]
    /// Title to use if this event starts a new workstream.
    let suggestedTitle: String?
    /// Reference that names a new workstream if this event creates one. Defaults to the first reference.
    let workstreamKey: ExternalReference?
    /// Whether an event that matches no existing workstream may start one. Events that only
    /// close something (e.g. a session ending) should not create work.
    let allowsNewWorkstream: Bool
    /// Pull request this event belongs to; attached to the workstream if it has none yet.
    let pullRequest: PullRequestReference?

    init(
        id: EventID,
        source: EventSource,
        kind: WorkEventKind,
        timestamp: Date,
        metadata: [MetadataKey: String] = [:],
        references: [ExternalReference],
        suggestedTitle: String? = nil,
        workstreamKey: ExternalReference? = nil,
        allowsNewWorkstream: Bool = true,
        pullRequest: PullRequestReference? = nil
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.timestamp = timestamp
        self.metadata = Dictionary(uniqueKeysWithValues: metadata.map { ($0.key.rawValue, $0.value) })
        self.references = references
        self.suggestedTitle = suggestedTitle
        self.workstreamKey = workstreamKey
        self.allowsNewWorkstream = allowsNewWorkstream
        self.pullRequest = pullRequest
    }

    func linked(to workstreamID: WorkstreamID) -> WorkEvent {
        WorkEvent(id: id, workstreamID: workstreamID, source: source, kind: kind, timestamp: timestamp, metadata: metadata)
    }
}
