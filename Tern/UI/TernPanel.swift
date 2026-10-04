import AppKit
import SwiftUI

/// Root content of the menu bar window.
struct TernPanel: View {
    let model: AppModel
    @State private var expandedID: WorkstreamID?
    /// Height of the scrolling content. A scroll view has no useful ideal height of its own,
    /// so the menu bar window would otherwise size it to nothing.
    @State private var contentHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 460

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Needs you", model.needsYou, empty: "Nothing needs you right now.")
                    if !model.more.isEmpty {
                        compactSection("More", model.more, symbol: "circle.fill", detail: true)
                    }
                    section("Waiting", Array(model.waiting.prefix(AppModel.waitingLimit)), empty: nil)
                    if model.waiting.count > AppModel.waitingLimit {
                        compactSection("More waiting", Array(model.waiting.dropFirst(AppModel.waitingLimit)), symbol: "circle", detail: true)
                    }
                    section("Active", model.active, empty: nil)
                    if !model.yourWork.isEmpty {
                        compactSection("Your other work", model.yourWork, symbol: "minus", detail: true)
                    }
                    if !model.doneToday.isEmpty {
                        compactSection("Done today", model.doneToday, symbol: "checkmark", detail: false)
                    }
                    if !model.idle.isEmpty {
                        compactSection("Idle", model.idle, symbol: "pause", detail: true)
                    }
                    if !model.unclassified.isEmpty {
                        unclassifiedSection
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollIndicators(contentHeight > Self.maxListHeight ? .automatic : .never)
            .frame(height: min(contentHeight, Self.maxListHeight))

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
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Tern")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                Spacer()
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if model.isContextScoped {
                Picker("Context", selection: Binding(get: { model.activeContext }, set: { model.setActiveContext($0) })) {
                    ForEach(TernContext.allCases, id: \.self) { context in
                        Text(context.title.uppercased()).tag(context)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    /// Work whose repository isn't classified yet. It takes part in neither context; one
    /// right-click files the owner (or just the repository) under Personal or Professional.
    private var unclassifiedSection: some View {
        DisclosureGroup {
            ForEach(model.unclassified) { workstream in
                HStack(spacing: 8) {
                    Image(systemName: "questionmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(workstream.repositoryKey.map { $0.replacingOccurrences(of: "github.com/", with: "") } ?? "No GitHub repository")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(workstream.title)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.vertical, 2)
                .contextMenu { classifyMenu(for: workstream) }
            }
        } label: {
            Text("UNCLASSIFIED · \(model.unclassified.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .help("Not in Personal or Professional yet. Right-click to classify.")
        }
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func classifyMenu(for workstream: Workstream) -> some View {
        if let repository = workstream.repositoryKey, let owner = ContextRules.owner(of: repository) {
            let name = repository.replacingOccurrences(of: "github.com/", with: "")
            Section("Everything from \(owner) is…") {
                ForEach(TernContext.allCases, id: \.self) { context in
                    Button(context.title) { model.setContext(context, forOwner: owner) }
                }
            }
            Section("Only \(name) is…") {
                ForEach(TernContext.allCases, id: \.self) { context in
                    Button(context.title) { model.setContext(context, repository: repository) }
                }
            }
        } else {
            Text("Only work in a GitHub repository can be classified")
        }
    }

    private var summary: String {
        let count = model.attentionQueue.count
        return count == 0 ? "All quiet" : "\(count) need\(count == 1 ? "s" : "") you"
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
                    .contextMenu {
                        importanceMenu(for: workstream)
                        if model.isContextScoped, workstream.repositoryKey != nil { classifyMenu(for: workstream) }
                    }
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
                .contextMenu {
                        importanceMenu(for: workstream)
                        if model.isContextScoped, workstream.repositoryKey != nil { classifyMenu(for: workstream) }
                    }
            }
        } label: {
            Text("\(title.uppercased()) · \(workstreams.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    /// Lets the user say how much a repository matters. Only for work with a known repository.
    @ViewBuilder
    private func importanceMenu(for workstream: Workstream) -> some View {
        if let repository = workstream.pullRequest?.repository {
            let current = model.importance(of: workstream)
            Section("\(repository) is…") {
                ForEach(RepositoryImportance.allCases, id: \.self) { value in
                    Button {
                        model.setImportance(value, for: workstream)
                    } label: {
                        if value == current {
                            Label(value.rawValue.capitalized, systemImage: "checkmark")
                        } else {
                            Text(value.rawValue.capitalized)
                        }
                    }
                }
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
