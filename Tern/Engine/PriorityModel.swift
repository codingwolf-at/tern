import Foundation

/// How much a workstream deserves a place at the top, separate from its attention level.
/// Attention says how loud the current situation is; priority says how much it matters
/// relative to everything else. A loud item in a muted side project can rank below a
/// medium item in primary work.
struct Priority: Hashable, Sendable, Comparable {
    struct Part: Hashable, Sendable {
        let label: String
        let points: Int
    }

    let parts: [Part]
    var score: Int { parts.reduce(0) { $0 + $1.points } }

    static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.score < rhs.score }
}

/// A transparent, deterministic score: the sum of five parts, each explainable on its own.
///
/// | Part        | Points | Why |
/// |-------------|--------|-----|
/// | Ownership   | me 40 · agent 20 · reviewer/CI/external 5 · nobody 0 | Things you can act on come first; an agent at work is your work in progress. |
/// | Reason      | needs input 30 · changes requested 28 · CI failed / reviewer responded 26 · review requested / agent failed 24 · approved 20 · agent finished 18 · reopened 15 · changes pushed / approval outdated 8 · no reviewer 4 · draft / ready to start 2 | Direct requests from people and blocked agents outrank housekeeping. |
/// | Relevance   | primary +25 · normal 0 · low priority −20 · muted −60 | The user's own statement of what matters; never inferred from names. |
/// | Recency     | <1h +15 · <1d +10 · <3d +5 · <14d 0 · older −10 | A fresh transition is more likely to matter now than an old state. |
/// | Active work | agent in progress +10 · planned work (linked work item) +5 | What you're doing now beats unrelated stale work. |
///
/// Reason weights keep the levels apart: a person waiting on you (24–30) always beats a
/// merge (20) at equal relevance, while one step of relevance (±20–25) can reorder them,
/// which is the point of letting the user mark work as primary or low priority.
enum PriorityModel {
    static func priority(of workstream: Workstream, importance: RepositoryImportance, now: Date) -> Priority {
        var parts: [Priority.Part] = []

        let ownership = switch workstream.nextOwner {
        case .me: 40
        case .agent: 20
        case .reviewer, .ci, .external: 5
        case .none: 0
        }
        parts.append(.init(label: "owner \(workstream.nextOwner.rawValue)", points: ownership))

        if let reason = workstream.evaluation.decision.reason {
            parts.append(.init(label: reason.rawValue, points: weight(reason)))
        }

        let relevance = switch importance {
        case .primary: 25
        case .normal: 0
        case .lowPriority: -20
        case .muted: -60
        }
        if relevance != 0 { parts.append(.init(label: importance.rawValue, points: relevance)) }

        let age = workstream.lastMeaningfulChange.map { now.timeIntervalSince($0) } ?? .infinity
        let recency = switch age {
        case ..<3600: 15
        case ..<86_400: 10
        case ..<(3 * 86_400): 5
        case ..<(14 * 86_400): 0
        default: -10
        }
        if recency != 0 { parts.append(.init(label: "recency", points: recency)) }

        if workstream.agentSessions.contains(where: { $0.status == .working || $0.status == .needsInput }) {
            parts.append(.init(label: "agent active", points: 10))
        }
        if workstream.planeItem != nil {
            parts.append(.init(label: "planned work", points: 5))
        }
        return Priority(parts: parts)
    }

    static func weight(_ reason: AttentionReason) -> Int {
        switch reason {
        case .agentNeedsInput: 30
        case .changesRequested: 28
        case .ciFailed, .reviewerResponded: 26
        case .reviewRequested, .agentFailed: 24
        case .approvedReadyToMerge: 20
        case .agentCompleted: 18
        case .workReopened: 15
        case .deadline: 15
        case .changesPushed, .approvalOutdated: 8
        case .stale: 5
        case .needsReviewer: 4
        case .draft, .readyToStart: 2
        // Meetings are shown on their own and never ranked against workstreams.
        case .meetingSoon: 0
        }
    }

    /// Highest priority first; ties go to the more recent change, then the workstream ID, so
    /// the order never depends on input order.
    static func ranked(_ workstreams: [Workstream], importance: (Workstream) -> RepositoryImportance, now: Date) -> [Workstream] {
        workstreams
            .map { ($0, priority(of: $0, importance: importance($0), now: now)) }
            .sorted { lhs, rhs in
                if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
                let l = lhs.0.lastMeaningfulChange ?? .distantPast, r = rhs.0.lastMeaningfulChange ?? .distantPast
                if l != r { return l > r }
                return lhs.0.id.rawValue < rhs.0.id.rawValue
            }
            .map(\.0)
    }
}

extension Workstream {
    /// The repository this work lives in, as an importance key, when known.
    /// The GitHub repository the work is in: its pull request's, otherwise the one an agent
    /// session reported working in.
    var repositoryKey: String? {
        if let pullRequest { return RepositoryImportance.key(forRepository: pullRequest.repository) }
        return events.last { $0[.repository] != nil }?[.repository].map(RepositoryImportance.key(forRepository:))
    }

    /// Worth interrupting the user for: their move, at medium attention or above.
    var needsAttentionNow: Bool {
        nextOwner == .me && attention >= .medium && state != .complete
    }
}
