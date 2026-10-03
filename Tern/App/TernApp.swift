import SwiftUI

@main
struct TernApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            TernPanel(model: model)
        } label: {
            MenuBarLabel(backWithYouCount: model.backWithYou.count)
        }
        .menuBarExtraStyle(.window)
    }
}
