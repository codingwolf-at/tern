import Foundation

/// Which build is running. Debug and Release builds keep separate bundle IDs, URL schemes,
/// defaults and Keychain items, so a development build never touches the installed app's data.
enum BuildEnvironment: Sendable {
    case debug
    case release

    static var current: BuildEnvironment {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }

    static let root = "so.plane.tern"

    /// Keychain service for an integration's secrets. Release keeps the original
    /// `so.plane.tern.<integration>`, so existing tokens are found without migration;
    /// Debug gets its own `so.plane.tern.debug.<integration>` and starts empty.
    func keychainService(_ integration: String, root: String = BuildEnvironment.root) -> String {
        switch self {
        case .release: "\(root).\(integration)"
        case .debug: "\(root).debug.\(integration)"
        }
    }
}
