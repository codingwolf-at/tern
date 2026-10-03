import Foundation

// Lightweight pointers into external systems. They identify where a workstream lives;
// they are not mirrors of the external services' full data models.

struct PlaneItemReference: Hashable, Sendable, Codable {
    /// Human-readable identifier, e.g. "PLANE-1842".
    let identifier: String
    var title: String?
}

struct PullRequestReference: Hashable, Sendable, Codable {
    let repository: String
    let number: Int

    var label: String { "PR #\(number)" }
}

struct AgentSession: Identifiable, Hashable, Sendable, Codable {
    enum Status: String, Hashable, Sendable, Codable {
        case working
        case needsInput
        case completed
        case failed
    }

    let id: String
    /// Full agent name, e.g. "Claude Code".
    let agentName: String
    var status: Status
    var startedAt: Date
    var updatedAt: Date

    /// Short conversational name, e.g. "Claude" for "Claude Code".
    var shortName: String {
        agentName.split(separator: " ").first.map(String.init) ?? agentName
    }
}

struct CalendarContext: Hashable, Sendable, Codable {
    var title: String
    var startsAt: Date
}
