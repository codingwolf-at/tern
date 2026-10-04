import SwiftUI

@main
struct TernApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel.makeDefault()
        _model = State(initialValue: model)
        OpenURLRouter.shared.start { url in
            guard ClaudeHookURL.isHookURL(url) else { return }
            await model.claudeHooks.handle(url)
        }
    }

    var body: some Scene {
        MenuBarExtra {
            TernPanel(model: model)
        } label: {
            MenuBarLabel(needsYouCount: model.needsYouCount)
        }
        .menuBarExtraStyle(.window)
    }
}
