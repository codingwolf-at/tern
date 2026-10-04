import SwiftUI

/// An item's one obvious action, plus a secondary one when there is a second real destination.
/// Pressing either only takes the user there; nothing in Tern changes.
struct ActionButtons: View {
    let actions: ItemActions
    /// Filled coral: the one action on screen that says "your turn". Everything else is neutral.
    var prominent = false
    let perform: @MainActor (ActionTarget) -> Void

    var body: some View {
        if let primary = actions.primary {
            HStack(spacing: 6) {
                let button = Button { perform(primary) } label: {
                    Label(primary.title, systemImage: primary.symbol)
                }
                if prominent {
                    button.buttonStyle(.borderedProminent).tint(TernColor.yourTurn)
                } else {
                    button.buttonStyle(.bordered)
                }
                if let secondary = actions.secondary {
                    Button { perform(secondary) } label: {
                        Label(secondary.title, systemImage: secondary.symbol)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            .font(.caption.weight(.medium))
            .labelStyle(.titleAndIcon)
        }
    }
}

/// "Not now" for an item: the few snooze lengths. Secondary to the item's own action.
struct SnoozeMenu: View {
    let snooze: @MainActor (SnoozeOption) -> Void

    var body: some View {
        Menu("Snooze") {
            ForEach(SnoozeOption.allCases, id: \.self) { option in
                Button(option.title) { snooze(option) }
            }
        }
    }
}

extension ItemActions {
    /// The same destinations as context-menu entries.
    @MainActor @ViewBuilder
    func menuItems(perform: @escaping @MainActor (ActionTarget) -> Void) -> some View {
        ForEach([primary, secondary].compactMap(\.self), id: \.self) { target in
            Button(target.title) { perform(target) }
        }
    }
}
