import AppKit
import SwiftUI

/// Root content of the menu bar window.
struct TernPanel: View {
    let model: AppModel
    @State private var expandedID: WorkstreamID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Back with you", model.backWithYou, empty: "Nothing needs you right now.")
                    section("Waiting", model.waiting, empty: nil)
                    if !model.done.isEmpty {
                        doneSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)

            #if DEBUG
            if let player = model.scenarioPlayer {
                Divider()
                ScenarioControls(player: player)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            #endif
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        .animation(.snappy(duration: 0.2), value: model.workstreams)
        .animation(.snappy(duration: 0.2), value: expandedID)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Tern")
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Spacer()
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var summary: String {
        let count = model.backWithYou.count
        return count == 0 ? "All quiet" : "\(count) your turn"
    }

    @ViewBuilder
    private func section(_ title: String, _ workstreams: [Workstream], empty: String?) -> some View {
        if !workstreams.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: title)
                if workstreams.isEmpty, let empty {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(workstreams) { workstream in
                    WorkstreamRow(
                        workstream: workstream,
                        isExpanded: expandedID == workstream.id,
                        toggle: { expandedID = expandedID == workstream.id ? nil : workstream.id }
                    )
                }
            }
        }
    }

    private var doneSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Done")
            ForEach(model.done) { workstream in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(workstream.primaryLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(workstream.title)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else {
                Text("Quiet unless it's your turn")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .keyboardShortcut("q")
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
