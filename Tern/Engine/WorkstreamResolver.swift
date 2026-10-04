/// Links external references (Plane item, PR, agent session, branch…) to workstreams.
///
/// Event identity answers "have I seen this event?"; the resolver answers
/// "which workstream does it belong to?". Two kinds of association exist:
///
/// - **Links** are explicit: a reference an event carries about itself (its PR, its session,
///   its branch). Links are only ever added, never re-pointed.
/// - **Hints** are mentions: a Plane identifier spotted in a branch name or PR title. A hint
///   never links on its own; it only lets the mentioned item find the workstream that
///   mentioned it, and lets the mentioning event find the item's workstream.
///
/// Placement precedence, strongest first:
/// 1. the event's own identity reference, if already linked;
/// 2. explicit identifiers the event mentions (candidates) that are linked — exactly one
///    workstream, or none if they disagree;
/// 3. the event's other references (branch, directory), if linked;
/// 4. workstreams that mentioned the event's identity — exactly one, or none if several.
///
/// Anything ambiguous or contradictory is reported as an `AssociationIssue` rather than guessed.
struct WorkstreamResolver: Hashable, Sendable {
    private(set) var links: [ExternalReference: WorkstreamID] = [:]
    private(set) var hints: [ExternalReference: Set<WorkstreamID>] = [:]

    init(links: [WorkstreamLink] = [], hints: [WorkstreamHint] = []) {
        for link in links {
            self.links[link.reference] = link.workstreamID
        }
        for hint in hints {
            self.hints[hint.reference, default: []].formUnion(hint.workstreamIDs)
        }
    }

    /// The workstream linked to the first reference that has a link, in the order given.
    func resolve(_ references: [ExternalReference]) -> WorkstreamID? {
        for reference in references {
            if let id = links[reference] { return id }
        }
        return nil
    }

    /// Where an event belongs, by the precedence above. `nil` means "start a new workstream".
    func place(references: [ExternalReference], candidates: [ExternalReference]) -> (workstream: WorkstreamID?, issues: [AssociationIssue]) {
        var issues: [AssociationIssue] = []
        if let identity = references.first, let id = links[identity] {
            return (id, issues)
        }

        let mentioned = Set(candidates.compactMap { links[$0] })
        if mentioned.count == 1 { return (mentioned.first, issues) }
        if mentioned.count > 1 {
            issues.append(AssociationIssue(kind: .ambiguous, references: candidates.filter { links[$0] != nil }, workstreams: mentioned.sorted { $0.rawValue < $1.rawValue }))
        }

        for reference in references.dropFirst() {
            if let id = links[reference] { return (id, issues) }
        }

        if let identity = references.first {
            // A workstream that already has its own reference of this kind can't adopt another.
            let mentioners = (hints[identity] ?? []).filter { !hasLink(ofKind: identity.kind, to: $0) }
            if mentioners.count == 1 { return (mentioners.first, issues) }
            if mentioners.count > 1 {
                issues.append(AssociationIssue(kind: .ambiguous, references: [identity], workstreams: mentioners.sorted { $0.rawValue < $1.rawValue }))
            }
        }
        return (nil, issues)
    }

    /// Links every not-yet-linked reference to `workstreamID` and records candidates as hints.
    /// A reference already linked elsewhere is left alone and reported.
    @discardableResult
    mutating func link(_ references: [ExternalReference], candidates: [ExternalReference] = [], to workstreamID: WorkstreamID) -> [AssociationIssue] {
        var issues: [AssociationIssue] = []
        for reference in references {
            if let existing = links[reference] {
                if existing != workstreamID {
                    issues.append(AssociationIssue(kind: .conflict, references: [reference], workstreams: [existing, workstreamID]))
                }
            } else {
                links[reference] = workstreamID
            }
        }
        for candidate in candidates where links[candidate] == nil {
            hints[candidate, default: []].insert(workstreamID)
        }
        return issues
    }

    private func hasLink(ofKind kind: String, to workstream: WorkstreamID) -> Bool {
        links.contains { $0.key.kind == kind && $0.value == workstream }
    }

    /// All links in a stable order, for persistence.
    var allLinks: [WorkstreamLink] {
        links
            .map { WorkstreamLink(reference: $0.key, workstreamID: $0.value) }
            .sorted { ($0.reference.kind, $0.reference.value) < ($1.reference.kind, $1.reference.value) }
    }

    var allHints: [WorkstreamHint] {
        hints
            .map { WorkstreamHint(reference: $0.key, workstreamIDs: $0.value.sorted { $0.rawValue < $1.rawValue }) }
            .sorted { ($0.reference.kind, $0.reference.value) < ($1.reference.kind, $1.reference.value) }
    }
}

struct WorkstreamLink: Hashable, Sendable, Codable {
    let reference: ExternalReference
    let workstreamID: WorkstreamID
}

struct WorkstreamHint: Hashable, Sendable, Codable {
    let reference: ExternalReference
    let workstreamIDs: [WorkstreamID]
}

/// An association Tern declined to make. Shown in diagnostics; never acted on automatically.
struct AssociationIssue: Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable {
        /// Signals pointed at more than one workstream.
        case ambiguous
        /// A reference was already linked to a different workstream than the event joined.
        case conflict
    }

    let kind: Kind
    let references: [ExternalReference]
    let workstreams: [WorkstreamID]
}
