import SwiftUI

/// Tern's colours, from the asset catalog (light and dark variants live there). See docs/BRAND.md.
/// Coral means "your turn". Crimson means something is wrong. Never use one for the other.
enum TernColor {
    /// The turn is yours: the ball, the lead action, the Needs you heading.
    static let yourTurn = Color(.coral)
    /// Coral for small text, darker in light mode so it stays legible.
    static let yourTurnText = Color(.coralText)
    /// Something is wrong: CI failed, an agent stopped, an error.
    static let critical = Color(.critical)
    static let warning = Color(.warning)
    static let success = Color(.success)
}

/// How loudly an item is drawn. Visual only: which level an item gets is the engine's business.
enum AttentionTone: Hashable, Sendable {
    /// Someone else holds it, or it doesn't claim attention. Neutral.
    case quiet
    /// The user's move.
    case yourTurn
    /// The user's move because something broke.
    case critical

    nonisolated static func of(level: AttentionLevel, reason: AttentionReason?, mine: Bool) -> AttentionTone {
        guard mine, level != .silent else { return .quiet }
        if level == .urgent || reason?.isProblem == true { return .critical }
        return .yourTurn
    }

    var color: Color {
        switch self {
        case .quiet: .secondary
        case .yourTurn: TernColor.yourTurn
        case .critical: TernColor.critical
        }
    }
}

extension AttentionLevel {
    /// Neutral when silent, coral while it's the user's move, crimson only when urgent.
    /// Failures are told apart by reason, not level: see `AttentionTone`.
    var tint: Color {
        AttentionTone.of(level: self, reason: nil, mine: true).color
    }
}

extension AttentionReason {
    /// The user's move because something went wrong, as opposed to an ordinary handoff.
    nonisolated var isProblem: Bool {
        switch self {
        case .ciFailed, .agentFailed: true
        default: false
        }
    }
}

/// The ownership glyph at the start of a row: filled ball when the turn is the user's,
/// a hollow ring while someone else holds it, nothing when nobody does.
enum OwnershipMark: Hashable, Sendable {
    case ball
    case ring
    case none

    nonisolated init(_ owner: Owner) {
        self = switch owner {
        case .me: .ball
        case .agent, .reviewer, .ci, .external: .ring
        case .none: .none
        }
    }
}

extension Font {
    /// Identifiers such as WEB-412 or PR #421.
    static func identifier(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }

    /// The lowercase "tern" wordmark. SF Pro Display Semibold.
    static let wordmark = Font.system(size: 17, weight: .semibold)
}

extension Owner {
    var displayName: String {
        switch self {
        case .me: "You"
        case .agent: "Agent"
        case .reviewer: "Reviewer"
        case .ci: "CI"
        case .external: "External"
        case .none: "Nobody"
        }
    }
}

extension WorkstreamState {
    var displayName: String {
        switch self {
        case .active: "Active"
        case .waiting: "Waiting"
        case .blocked: "Blocked"
        case .needsAttention: "Needs attention"
        case .complete: "Complete"
        }
    }
}

extension WorkEventKind {
    var displayName: String {
        switch self {
        case .planeItemCreated: "Plane item created"
        case .planeItemBlocked: "Plane item blocked"
        case .planeItemUnblocked: "Plane item unblocked"
        case .planeItemCompleted: "Plane item completed"
        case .pullRequestOpened: "PR created"
        case .reviewRequested: "Reviewer requested"
        case .changesRequested: "Changes requested"
        case .reviewerResponded: "Reviewer responded"
        case .reviewApproved: "PR approved"
        case .commitsPushed: "Commits pushed"
        case .ciStarted: "CI started"
        case .ciPassed: "CI passed"
        case .ciFailed: "CI failed"
        case .pullRequestMerged: "PR merged"
        case .pullRequestClosed: "PR closed"
        case .agentStarted: "Agent started"
        case .agentCompleted: "Agent completed"
        case .agentFailed: "Agent failed"
        default: rawValue
        }
    }
}

extension Workstream {
    /// The reference that best names this row. A Plane work item is the workstream's identity
    /// when it has one; otherwise the reference the current status is about.
    var primaryLabel: String {
        if let plane = planeItem { return plane.identifier }
        return switch status.focus {
        case .github: pullRequest?.label ?? planeItem?.identifier ?? title
        case .plane: planeItem?.identifier ?? pullRequest?.label ?? title
        case .agent: planeItem?.identifier ?? pullRequest?.label ?? agentSessions.last?.shortName ?? title
        case .calendar, nil: planeItem?.identifier ?? pullRequest?.label ?? title
        }
    }
}

extension Workstream {
    /// Whether `primaryLabel` is an identifier (WEB-412, PR #421), set in SF Mono, rather than a title.
    var primaryLabelIsIdentifier: Bool { planeItem != nil || pullRequest != nil }
}

extension Workstream {
    /// The item's current Plane state name, if Plane reported one.
    var planeStateName: String? {
        events.last { $0.source == .plane && $0[.stateName] != nil }?[.stateName]
    }

    /// Attached contexts beyond the identity: "PR #421 · Claude working · In Review".
    /// Only for Plane-identified workstreams, where the PR and sessions aren't otherwise named.
    var contextLine: String? {
        guard planeItem != nil else { return nil }
        var parts: [String] = []
        if let pr = pullRequest { parts.append(pr.label) }
        if let session = agentSessions.last(where: { $0.status != .ended }) {
            let status = switch session.status {
            case .working: "working"
            case .needsInput: "needs input"
            case .completed: "finished"
            case .failed: "stopped"
            case .idle, .ended: "idle"
            }
            parts.append("\(session.shortName) \(status)")
        }
        if let state = planeStateName { parts.append(state) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

enum Age {
    /// Compact relative age such as "now", "8m", "3h", "2d".
    static func compact(since date: Date, now: Date = .now) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        switch minutes {
        case 0: return "now"
        case ..<60: return "\(minutes)m"
        case ..<(24 * 60): return "\(minutes / 60)h"
        default: return "\(minutes / (24 * 60))d"
        }
    }
}
