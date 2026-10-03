/// Links external references (Plane item, PR, agent session, branch…) to workstreams.
///
/// Event identity answers "have I seen this event?"; the resolver answers
/// "which workstream does it belong to?". Links are only ever added, never re-pointed,
/// so a reference keeps resolving to the workstream it was first linked to.
struct WorkstreamResolver: Hashable, Sendable {
    private(set) var links: [ExternalReference: WorkstreamID] = [:]

    init(links: [WorkstreamLink] = []) {
        for link in links {
            self.links[link.reference] = link.workstreamID
        }
    }

    /// The workstream linked to the first reference that has a link, in the order given.
    func resolve(_ references: [ExternalReference]) -> WorkstreamID? {
        for reference in references {
            if let id = links[reference] { return id }
        }
        return nil
    }

    /// Links every not-yet-linked reference to `workstreamID`.
    mutating func link(_ references: [ExternalReference], to workstreamID: WorkstreamID) {
        for reference in references where links[reference] == nil {
            links[reference] = workstreamID
        }
    }

    /// All links in a stable order, for persistence.
    var allLinks: [WorkstreamLink] {
        links
            .map { WorkstreamLink(reference: $0.key, workstreamID: $0.value) }
            .sorted { ($0.reference.kind, $0.reference.value) < ($1.reference.kind, $1.reference.value) }
    }
}

struct WorkstreamLink: Hashable, Sendable, Codable {
    let reference: ExternalReference
    let workstreamID: WorkstreamID
}
