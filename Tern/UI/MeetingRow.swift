import AppKit
import SwiftUI

/// One meeting, in the same visual language as a workstream row. Clicking joins the call when
/// the event carries a link; without one there is nothing to click through to.
struct MeetingRow: View {
    let status: MeetingStatus

    @State private var isHovering = false

    private var meeting: Meeting { status.meeting }
    private var needsYou: Bool { status.needsAttentionNow }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AttentionMarker(level: status.decision.attention, filled: needsYou)

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(meeting.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if status.isNew {
                        Text("New")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(status.decision.attention.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(status.decision.attention.tint.opacity(0.15), in: Capsule())
                    }
                }
                TimelineView(.everyMinute) { context in
                    Text(Self.timing(of: meeting, phase: status.phase, now: context.date))
                        .font(.callout)
                        .foregroundStyle(needsYou ? .primary : .secondary)
                        .monospacedDigit()
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                if needsYou, let action = status.decision.nextAction {
                    actionLine(action)
                        .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering && meeting.joinURL != nil ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture { if let url = meeting.joinURL { NSWorkspace.shared.open(url) } }
        .contextMenu {
            if let url = meeting.joinURL {
                Button("Join meeting") { NSWorkspace.shared.open(url) }
            }
            Button("Open Calendar") { Self.openCalendar() }
        }
        .help(meeting.joinURL == nil ? "No meeting link in this event" : "Join meeting")
        .accessibilityElement(children: .combine)
    }

    /// "Professional · Work calendar · Room 4"
    private var detail: String {
        var parts = [status.context.title, meeting.calendarTitle]
        if let location = meeting.location, meeting.joinURL.map({ !location.contains($0.absoluteString) }) ?? true {
            parts.append(location)
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    @ViewBuilder
    private func actionLine(_ action: NextAction) -> some View {
        let label = HStack(spacing: 4) {
            Image(systemName: meeting.joinURL == nil ? "arrow.turn.down.right" : "video.fill")
                .font(.caption2.weight(.semibold))
            Text(action.title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(status.decision.attention.tint)
        if let url = meeting.joinURL {
            Button { NSWorkspace.shared.open(url) } label: { label }
                .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// "in 12 min", "starting now", "started 3 min ago", "in 2 h".
    static func timing(of meeting: Meeting, phase: MeetingPhase, now: Date) -> String {
        switch phase {
        case .inProgress, .ended:
            let minutes = max(0, Int(now.timeIntervalSince(meeting.startsAt) / 60))
            return minutes == 0 ? "Started just now" : "Started \(minutes) min ago"
        case .startingSoon, .preparing, .upcoming:
            let minutes = Int((meeting.startsAt.timeIntervalSince(now) / 60).rounded(.up))
            if minutes <= 1 { return "Starting now" }
            if minutes < 60 { return "In \(minutes) min" }
            return "At \(meeting.startsAt.formatted(date: .omitted, time: .shortened))"
        }
    }

    static func openCalendar() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

extension WorkstreamContext {
    var title: String {
        switch self {
        case .personal: "Personal"
        case .professional: "Professional"
        case .unclassified: "Unclassified"
        }
    }
}
