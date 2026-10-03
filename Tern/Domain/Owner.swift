/// Who currently holds the next action in a workstream.
enum Owner: String, Hashable, Sendable, Codable, CaseIterable {
    case me
    case agent
    case reviewer
    case ci
    case external
    case none
}
