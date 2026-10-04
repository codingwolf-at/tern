import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        let model = AppModel.makeDefault()
        AppDelegate.model = model
        OpenURLRouter.shared.start { url in
            guard ClaudeHookURL.isHookURL(url) else { return }
            await model.claudeHooks.handle(url)
        }
    }

    /// The menu bar icon and panel are AppKit's (see `MenuBarPanel`), so a notification click can
    /// open the panel. A menu bar app still needs a scene; this one never shows anything.
    var body: some Scene {
        Settings { EmptyView() }
    }
}
