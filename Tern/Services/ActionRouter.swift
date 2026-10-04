import AppKit
import Foundation

/// Takes the user to an already-resolved destination. Holds no rules, changes no state, and
/// never logs the URL. The default browser or app handles it from there.
@MainActor
protocol ActionRouter {
    func open(_ url: URL)
}

/// Opens URLs with the system's default handler: the browser for GitHub and Plane, the call
/// app (Zoom, Meet in the browser, …) for meetings.
struct SystemActionRouter: ActionRouter {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
