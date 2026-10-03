#if DEBUG
import SwiftUI

/// Steps the featured mock workstream through its script so the engine's
/// transitions can be watched live. Stands in for real integrations in Phase 1.
struct ScenarioControls: View {
    let player: ScenarioPlayer

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Simulate · Avatar migration")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer()
            HStack(spacing: 2) {
                control("arrow.counterclockwise", "Restart scenario", disabled: player.step == 0, { await player.restart() })
                control("chevron.left", "Previous event", disabled: player.step == 0, { await player.stepBackward() })
                Text("\(player.step)/\(player.length)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28)
                control("chevron.right", "Next event", disabled: player.step == player.length, { await player.stepForward() })
            }
        }
    }

    private var caption: String {
        let script = player.scenario.avatarMigrationScript
        if player.step < script.count {
            return "Next: \(script[player.step].kind.displayName)"
        }
        return "Last: \(script[script.count - 1].kind.displayName)"
    }

    private func control(_ symbol: String, _ label: String, disabled: Bool, _ action: @escaping @MainActor () async -> Void) -> some View {
        Button {
            Task { await action() }
        } label: {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .disabled(disabled)
        .help(label)
        .accessibilityLabel(label)
    }
}
#endif
