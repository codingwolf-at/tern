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
    /// The reference that best names this row given what the current status is about.
    var primaryLabel: String {
        switch status.focus {
        case .github: pullRequest?.label ?? planeItem?.identifier ?? title
        case .plane: planeItem?.identifier ?? pullRequest?.label ?? title
        case .agent: planeItem?.identifier ?? pullRequest?.label ?? agentSessions.last?.shortName ?? title
        case .calendar, nil: planeItem?.identifier ?? pullRequest?.label ?? title
        }
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
