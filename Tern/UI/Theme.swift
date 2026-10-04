import SwiftUI

extension AttentionLevel {
    var tint: Color {
        switch self {
        case .urgent, .high: .red
        case .medium: .orange
        case .low: .yellow
        case .silent: .secondary
        }
    }
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
        case .calendarEventScheduled: "Meeting scheduled"
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

    /// Compact time until a future date such as "in 45m".
    static func until(_ date: Date, now: Date = .now) -> String {
        let minutes = Int(date.timeIntervalSince(now) / 60)
        guard minutes > 0 else { return "now" }
        return minutes < 60 ? "in \(minutes)m" : "in \(minutes / 60)h"
    }
}
