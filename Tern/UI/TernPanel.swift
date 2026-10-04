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
                    if !model.notMoving.isEmpty {
                        compactSection("Not moving", model.notMoving, symbol: "pause", detail: true)
                    }
                    if !model.done.isEmpty {
                        compactSection("Done", model.done, symbol: "checkmark", detail: false)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: 460)

            #if DEBUG
            Divider()
            ClaudeDiagnosticsView(receiver: model.claudeHooks, workstreams: model.workstreams)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            if let github = model.github {
                GitHubDiagnosticsView(account: github)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if let plane = model.plane {
                PlaneDiagnosticsView(account: plane, unresolved: model.unresolvedAssociations)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            if let player = model.scenarioPlayer {
                Divider()
                ScenarioControls(player: player)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
            }
            #endif
            if let github = model.github {
                Divider()
                GitHubConnectionView(account: github)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, model.plane == nil ? 8 : 4)
            }
            if let plane = model.plane {
                PlaneConnectionView(account: plane)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .padding(.top, model.github == nil ? 8 : 0)
            }
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

    /// One line per workstream, collapsed behind a disclosure when there are many.
    private func compactSection(_ title: String, _ workstreams: [Workstream], symbol: String, detail: Bool) -> some View {
        DisclosureGroup {
            ForEach(workstreams) { workstream in
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(workstream.primaryLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workstream.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if detail {
                        Text(workstream.status.headline)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 2)
            }
        } label: {
            Text("\(title.uppercased()) · \(workstreams.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
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
