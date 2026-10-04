import SwiftUI

/// An item's one obvious action, plus a secondary one when there is a second real destination.
/// Pressing either only takes the user there; nothing in Tern changes.
struct ActionButtons: View {
    let actions: ItemActions
    let tint: Color
    let perform: @MainActor (ActionTarget) -> Void

    var body: some View {
        if let primary = actions.primary {
            HStack(spacing: 6) {
                Button { perform(primary) } label: {
                    Label(primary.title, systemImage: primary.symbol)
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
                if let secondary = actions.secondary {
                    Button { perform(secondary) } label: {
                        Label(secondary.title, systemImage: secondary.symbol)
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

extension ItemActions {
    /// The same destinations as context-menu entries.
    @MainActor @ViewBuilder
    func menuItems(perform: @escaping @MainActor (ActionTarget) -> Void) -> some View {
        ForEach([primary, secondary].compactMap(\.self), id: \.self) { target in
            Button(target.title) { perform(target) }
        }
    }
}
