import AppKit

/// Opens Tern's menu bar panel from code (e.g. after a notification click). SwiftUI's
/// `MenuBarExtra` has no API for this, so it clicks Tern's own status item. Best effort: if the
/// status item can't be found, Tern is only activated.
@MainActor
enum MenuBarPanel {
    static func open() {
        NSApp.activate()
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            guard window.responds(to: Selector(("statusItem"))),
                  let item = window.value(forKey: "statusItem") as? NSStatusItem,
                  let button = item.button
            else { continue }
            button.performClick(nil)
            return
        }
    }
}
