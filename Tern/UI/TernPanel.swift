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
                    if model.upNext != nil || model.meetingInProgress != nil {
                        upNextSection
                    }
                    if !model.more.isEmpty {
                        compactSection("More", model.more, symbol: "circle.fill", detail: true)
                    }
                    section("Waiting", model.waiting.prefix(AppModel.waitingLimit).map(AttentionItem.workstream), empty: nil)
                    if model.waiting.count > AppModel.waitingLimit {
                        compactSection("More waiting", model.waiting.dropFirst(AppModel.waitingLimit).map(AttentionItem.workstream), symbol: "circle", detail: true)
                    }
                    section("Active", model.active.map(AttentionItem.workstream), empty: nil)
                    if !model.yourWork.isEmpty {
                        compactSection("Your other work", model.yourWork.map(AttentionItem.workstream), symbol: "minus", detail: true)
                    }
                    if !model.doneToday.isEmpty {
                        compactSection("Done today", model.doneToday.map(AttentionItem.workstream), symbol: "checkmark", detail: false)
                    }
                    if !model.idle.isEmpty {
                        compactSection("Idle", model.idle.map(AttentionItem.workstream), symbol: "pause", detail: true)
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
                    .padding(.bottom, model.calendar == nil ? 8 : 4)
                    .padding(.top, model.github == nil ? 8 : 0)
            }
            if let calendar = model.calendar {
                CalendarConnectionView(account: calendar, rules: model.contextRules) { model.setContext($0, forCalendar: $1) }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .padding(.top, model.github == nil && model.plane == nil ? 8 : 0)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        // Opening the panel re-reads Calendar: cheap, and it notices access granted in System Settings.
        .onAppear { model.calendar?.refresh() }
        .animation(.snappy(duration: 0.2), value: model.workstreams)
        .animation(.snappy(duration: 0.2), value: model.meetings)
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
            Text("In neither Personal nor Professional. Right-click a row to classify its owner or repository.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 2)
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
            let rules = model.contextRules
            Section("Everything from \(owner) is…") {
                classifyOptions(current: rules.owners[owner], clearTitle: "Unclassified") { model.setContext($0, forOwner: owner) }
            }
            Section("Only \(name) is…") {
                classifyOptions(current: rules.repositories[repository], clearTitle: "Same as \(owner)") { model.setContext($0, repository: repository) }
            }
        } else {
            Text("Only work in a GitHub repository can be classified")
        }
    }

    /// Personal, Professional and a way back, with a checkmark on the rule in force.
    @ViewBuilder
    private func classifyOptions(current: TernContext?, clearTitle: String, set: @escaping (TernContext?) -> Void) -> some View {
        ForEach(TernContext.allCases, id: \.self) { context in
            Button { set(context) } label: {
                if current == context { Label(context.title, systemImage: "checkmark") } else { Text(context.title) }
            }
        }
        if current != nil {
            Button(clearTitle) { set(nil) }
        }
    }

    private var summary: String {
        let count = model.attentionQueue.count
        return count == 0 ? "All quiet" : "\(count) need\(count == 1 ? "s" : "") you"
    }

    /// The next meeting, and one under way, quietly. Not an agenda: at most one of each.
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Up next")
            if let meeting = model.meetingInProgress {
                MeetingRow(status: meeting)
            }
            if let meeting = model.upNext {
                MeetingRow(status: meeting)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AttentionItem], empty: String?) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: title)
                if items.isEmpty, let empty {
                    Text(empty)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
                ForEach(items) { item in
                    switch item {
                    case .workstream(let workstream):
                        WorkstreamRow(
                            workstream: workstream,
                            isExpanded: expandedID == workstream.id,
                            toggle: { expandedID = expandedID == workstream.id ? nil : workstream.id }
                        )
                        .contextMenu {
                            importanceMenu(for: workstream)
                            if model.isContextScoped, workstream.repositoryKey != nil { classifyMenu(for: workstream) }
                        }
                    case .meeting(let meeting):
                        MeetingRow(status: meeting)
                    }
                }
            }
        }
    }

    /// One line per item, collapsed behind a disclosure when there are many.
    private func compactSection(_ title: String, _ items: [AttentionItem], symbol: String, detail: Bool) -> some View {
        DisclosureGroup {
            ForEach(items) { item in
                switch item {
                case .workstream(let workstream):
                    compactRow(workstream, symbol: symbol, detail: detail)
                case .meeting(let meeting):
                    compactRow(meeting, symbol: symbol)
                }
            }
        } label: {
            Text("\(title.uppercased()) · \(items.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
    }

    private func compactRow(_ meeting: MeetingStatus, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
            Text("Meeting")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(meeting.meeting.title)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer()
            TimelineView(.everyMinute) { context in
                Text(MeetingRow.timing(of: meeting.meeting, phase: meeting.phase, now: context.date))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let url = meeting.meeting.joinURL {
                Button("Join meeting") { NSWorkspace.shared.open(url) }
            }
            Button("Open Calendar") { MeetingRow.openCalendar() }
        }
    }

    private func compactRow(_ workstream: Workstream, symbol: String, detail: Bool) -> some View {
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
                            Label(value.title, systemImage: "checkmark")
                        } else {
                            Text(value.title)
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
