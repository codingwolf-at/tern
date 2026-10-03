import AppKit

/// Receives URLs opened by the system and hands them to a handler one at a time, in order.
/// URLs that arrive before the handler is installed (e.g. the one that launched the app)
/// are buffered.
@MainActor
final class OpenURLRouter {
    static let shared = OpenURLRouter()

    private let urls: AsyncStream<URL>
    private let continuation: AsyncStream<URL>.Continuation
    private var consumer: Task<Void, Never>?

    init() {
        (urls, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(500))
    }

    func open(_ newURLs: [URL]) {
        for url in newURLs {
            continuation.yield(url)
        }
    }

    /// Installs the handler. Only the first call takes effect.
    func start(_ handler: @escaping @MainActor (URL) async -> Void) {
        guard consumer == nil else { return }
        consumer = Task { [urls] in
            for await url in urls {
                await handler(url)
            }
        }
    }
}

/// AppKit entry point for `tern://` URLs. Handling them never shows a window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            OpenURLRouter.shared.open(urls)
        }
    }
}
