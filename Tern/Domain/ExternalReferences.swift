import Foundation

// Lightweight pointers into external systems. They identify where a workstream lives;
// they are not mirrors of the external services' full data models.

struct PlaneItemReference: Hashable, Sendable, Codable {
    /// Human-readable identifier, e.g. "PLANE-1842".
    let identifier: String
    var title: String?
    var url: URL?

    init(identifier: String, title: String? = nil, url: URL? = nil) {
        self.identifier = identifier
        self.title = title
        self.url = url
    }
}

/// Finds Plane work item identifiers (`WEB-9295`) mentioned in branch names and titles.
enum PlaneIdentifiers {
    /// Identifiers in text, upper-cased, in order of appearance, without duplicates.
    /// The project prefix must start with a letter (2–10 characters); the number is 1–6 digits.
    static func find(in text: String) -> [String] {
        var seen: Set<String> = []
        return text.matches(of: /\b([A-Za-z][A-Za-z0-9]{1,9})-(\d{1,6})(?![0-9])/)
            .map { "\($0.output.1.uppercased())-\($0.output.2)" }
            .filter { seen.insert($0).inserted }
    }

    /// Identifiers in Plane links such as `https://app.plane.so/<workspace>/browse/WEB-9295/`.
    static func findInLinks(_ text: String) -> [String] {
        var seen: Set<String> = []
        return text.matches(of: /\/browse\/([A-Za-z][A-Za-z0-9]{1,9}-\d{1,6})/)
            .map { String($0.output.1).uppercased() }
            .filter { seen.insert($0).inserted }
    }
}

struct PullRequestReference: Hashable, Sendable, Codable {
    /// `owner/name`.
    let repository: String
    let number: Int
    var title: String?
    var url: URL?

    init(repository: String, number: Int, title: String? = nil, url: URL? = nil) {
        self.repository = repository
        self.number = number
        self.title = title
        self.url = url
    }

    var label: String { "PR #\(number)" }
}

struct AgentSession: Identifiable, Hashable, Sendable, Codable {
    enum Status: String, Hashable, Sendable, Codable {
        /// Session open, no turn running and nothing new to review.
        case idle
        case working
        case needsInput
        /// Last turn finished and returned control to the user.
        case completed
        /// Last turn ended with an error.
        case failed
        /// The session itself has closed.
        case ended
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
