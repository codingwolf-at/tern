import Foundation

/// Where the user's next move actually happens: a destination Tern can take them to. Only ever
/// built from a URL the source system gave Tern; never guessed or reconstructed.
struct ActionTarget: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case openPullRequest
        case openPlaneItem
        case joinMeeting
    }

    let kind: Kind
    let url: URL
    /// The subject the action belongs to, and its context, so an action can never open a
    /// destination from the context the user isn't in.
    let subjectID: SubjectID
    let context: SubjectContext

    var title: String {
        switch kind {
        case .openPullRequest: "Open PR"
        case .openPlaneItem: "Open in Plane"
        case .joinMeeting: "Join meeting"
        }
    }

    var symbol: String {
        switch kind {
        case .openPullRequest: "arrow.up.right.square"
        case .openPlaneItem: "arrow.up.right.square"
        case .joinMeeting: "video.fill"
        }
    }
}

/// The actions an attention item offers: one obvious primary, and a secondary only when it is a
/// different, equally real destination (e.g. the PR and its Plane item).
struct ItemActions: Hashable, Sendable {
    var primary: ActionTarget?
    var secondary: ActionTarget?

    static let none = ItemActions()
}
