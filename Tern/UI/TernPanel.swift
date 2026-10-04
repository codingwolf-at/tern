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
                    section("Needs you", model.needsYou, empty: "Nothing needs you.", isNeedsYou: true)
                    if model.upNext != nil || model.meetingInProgress != nil {
                        upNextSection
                    }
                    if !model.more.isEmpty {
                        compactSection("More", model.more, symbol: "circle.fill", detail: true)
                    }
                    if !model.snoozed.isEmpty {
                        snoozedSection
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
                    .padding(.bottom, model.notifications == nil ? 8 : 4)
                    .padding(.top, model.github == nil && model.plane == nil ? 8 : 0)
            }
            if let notifications = model.notifications {
                NotificationConnectionView(delivery: notifications)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(width: 340)
        // Opening the panel re-reads Calendar: cheap, and it notices access granted in System Settings.
        .onAppear {
            model.calendar?.refresh()
            if let notifications = model.notifications { Task { await notifications.refresh() } }
            showFocusedSubject()
        }
        .onChange(of: model.focusedSubject) { showFocusedSubject() }
        .animation(.snappy(duration: 0.2), value: model.workstreams)
        .animation(.snappy(duration: 0.2), value: model.meetings)
        .animation(.snappy(duration: 0.2), value: expandedID)
    }

    /// Expands the workstream a clicked notification was about. Meetings have no expanded view.
    private func showFocusedSubject() {
        guard let subject = model.focusedSubject else { return }
        if let workstream = model.workstreams.first(where: { $0.subjectID == subject }) { expandedID = workstream.id }
        model.focusedSubject = nil
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 6) {
                TurnMark(isYourTurn: !model.attentionQueue.isEmpty)
                    .frame(width: 18, height: 18)
                Text("tern")
                    .font(.wordmark)
                    .tracking(-0.4)
                    .accessibilityLabel("Tern")
                if BuildEnvironment.current == .debug {
                    Text("DEBUG")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(TernColor.warning)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(TernColor.warning.opacity(0.15), in: Capsule())
                        .help("A Debug build: its own state, Plane token and Calendar access, separate from the installed Tern.")
                }
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
                // Ink, not the system accent and never coral: coral means "your turn".
                .tint(.primary)
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

    /// Snooze lengths for an item that can be snoozed. Only items that claim attention qualify.
    @ViewBuilder
    private func snoozeMenu(for item: AttentionItem) -> some View {
        if model.canSnooze(item) && !model.isSnoozed(item) {
            SnoozeMenu { model.snooze(item, for: $0) }
        }
    }

    /// Items the user said "not now" to: out of Needs you and the badge until the time shown.
    private var snoozedSection: some View {
        DisclosureGroup {
            ForEach(model.snoozed) { item in
                HStack(spacing: 8) {
                    Image(systemName: "moon.zzz")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)
                    Text(item.workstream?.primaryLabel ?? "Meeting")
                        .font(item.workstream?.primaryLabelIsIdentifier == true ? .identifier(.caption) : .caption)
                        .foregroundStyle(.secondary)
                    Text(item.workstream?.title ?? item.meeting?.meeting.title ?? "")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                    Spacer()
                    if let until = model.snooze(of: item)?.until {
                        Text("until \(until.formatted(date: .omitted, time: .shortened))")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Button("Unsnooze") { model.unsnooze(item) }
                        .buttonStyle(.borderless)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                .contextMenu {
                    if let until = model.snooze(of: item)?.until {
                        Text("Snoozed until \(until.formatted(date: .abbreviated, time: .shortened))")
                    }
                    Button("Unsnooze") { model.unsnooze(item) }
                }
            }
        } label: {
            Text("SNOOZED · \(model.snoozed.count)")
                .font(.caption2.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .help("Needs you, but you said not now. Out of Needs you and the badge until the time shown.")
        }
        .padding(.horizontal, 8)
    }

    /// The next meeting, and one under way, quietly. Not an agenda: at most one of each.
    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Up next")
            if let meeting = model.meetingInProgress {
                MeetingRow(status: meeting, actions: model.actions(for: .meeting(meeting)), perform: { model.perform($0) })
            }
            if let meeting = model.upNext {
                MeetingRow(status: meeting, actions: model.actions(for: .meeting(meeting)), perform: { model.perform($0) })
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [AttentionItem], empty: String?, isNeedsYou: Bool = false) -> some View {
        if !items.isEmpty || empty != nil {
            VStack(alignment: .leading, spacing: 2) {
                SectionHeader(title: title, isYourTurn: isNeedsYou && !items.isEmpty)
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
                            toggle: { expandedID = expandedID == workstream.id ? nil : workstream.id },
                            actions: model.actions(for: .workstream(workstream)),
                            perform: { model.perform($0) },
                            isLead: isNeedsYou && item.id == items.first?.id
                        )
                        .contextMenu {
                            model.actions(for: .workstream(workstream)).menuItems { model.perform($0) }
                            snoozeMenu(for: item)
                            importanceMenu(for: workstream)
                            if model.isContextScoped, workstream.repositoryKey != nil { classifyMenu(for: workstream) }
                        }
                    case .meeting(let meeting):
                        MeetingRow(status: meeting, actions: model.actions(for: .meeting(meeting)), perform: { model.perform($0) },
                                   snooze: model.canSnooze(item) ? { @MainActor option in model.snooze(item, for: option) } : nil,
                                   isLead: isNeedsYou && item.id == items.first?.id)
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
            model.actions(for: .meeting(meeting)).menuItems { model.perform($0) }
            snoozeMenu(for: .meeting(meeting))
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
                .font(workstream.primaryLabelIsIdentifier ? .identifier(.caption) : .caption)
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
            model.actions(for: .workstream(workstream)).menuItems { model.perform($0) }
            snoozeMenu(for: .workstream(workstream))
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
                    .foregroundStyle(TernColor.critical)
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
    /// Needs you with something in it: the heading carries the coral.
    var isYourTurn = false

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(isYourTurn ? AnyShapeStyle(TernColor.yourTurnText) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 2)
    }
}
