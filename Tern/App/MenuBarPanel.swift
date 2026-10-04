import AppKit
import Observation
import SwiftUI

/// Tern's menu bar icon and panel, owned in AppKit so the panel can be opened from code — e.g.
/// by a notification click — which SwiftUI's `MenuBarExtra` has no API for. The panel is the
/// same SwiftUI `TernPanel`, shown in a popover anchored to the icon.
@MainActor
final class MenuBarPanel: NSObject {
    static let shared = MenuBarPanel()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var model: AppModel?

    /// Creates the icon and panel. Called once, at launch.
    func install(model: AppModel) {
        guard statusItem == nil else { return }
        self.model = model

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let host = NSHostingController(rootView: TernPanel(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        self.popover = popover

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(toggle)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        updateIcon()
    }

    /// Shows the panel, bringing Tern forward. Does nothing if it's already showing.
    func show() {
        guard let popover, let button = statusItem?.button, !popover.isShown else { return }
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func toggle() {
        if popover?.isShown == true {
            popover?.performClose(nil)
        } else {
            show()
        }
    }

    /// Keeps the icon in step with the attention queue: re-renders whenever what it reads changes.
    private func updateIcon() {
        guard let model, let button = statusItem?.button else { return }
        let count = withObservationTracking {
            model.attentionQueue.count
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
        let label = Self.label(needsYou: count, build: .current)
        let image = NSImage(named: label.image)
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        button.image = image
        button.title = label.title
        button.setAccessibilityLabel(label.accessibility)
    }

    /// What the icon shows: the Turn mark's path alone while nothing needs the user, and the
    /// path with its ball once the turn comes back. Monochrome template images, so the menu bar
    /// tints them for light and dark. Debug builds carry a "D" so they can't be mistaken for the
    /// installed Tern running beside them.
    nonisolated static func label(needsYou count: Int, build: BuildEnvironment) -> (image: String, title: String, accessibility: String) {
        let mark = build == .debug ? "D" : ""
        let name = build == .debug ? "Tern Debug" : "Tern"
        if count > 0 {
            return ("TernMark", " \(count)\(mark.isEmpty ? "" : " \(mark)")", "\(name), \(count) need\(count == 1 ? "s" : "") you")
        }
        return ("TernMarkPath", mark.isEmpty ? "" : " \(mark)", name)
    }
}
