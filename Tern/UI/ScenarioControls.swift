import SwiftUI

/// Steps the featured mock workstream through its script so the engine's
/// transitions can be watched live. Stands in for real integrations in Phase 1.
struct ScenarioControls: View {
    let model: AppModel

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
                control("arrow.counterclockwise", "Restart scenario", disabled: model.scenarioStep == 0, model.restartScenario)
                control("chevron.left", "Previous event", disabled: model.scenarioStep == 0, model.stepBackward)
                Text("\(model.scenarioStep)/\(model.scenarioLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28)
                control("chevron.right", "Next event", disabled: model.scenarioStep == model.scenarioLength, model.stepForward)
            }
        }
    }

    private var caption: String {
        let script = model.scenario.avatarMigrationScript
        if model.scenarioStep < script.count {
            return "Next: \(script[model.scenarioStep].kind.displayName)"
        }
        return "Last: \(script[script.count - 1].kind.displayName)"
    }

    private func control(_ symbol: String, _ label: String, disabled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
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
