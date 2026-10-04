import SwiftUI

struct WorkstreamRow: View {
    let workstream: Workstream
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    private var isMyTurn: Bool { workstream.nextOwner == .me }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            AttentionMarker(level: workstream.attention, filled: isMyTurn)

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Text(workstream.status.headline)
                    .font(.callout)
                    .foregroundStyle(isMyTurn ? .primary : .secondary)
                if let detail = workstream.status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let context = workstream.contextLine {
                    Text(context)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if isMyTurn, let action = workstream.nextAction {
                    NextActionLine(action: action, tint: workstream.attention.tint)
                        .padding(.top, 3)
                }
                if isExpanded {
                    WorkstreamDetail(workstream: workstream)
                        .padding(.top, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering || isExpanded ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    private var titleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(workstream.primaryLabel)
                .font(.callout.weight(.semibold))
            if workstream.primaryLabel != workstream.title {
                Text(workstream.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if workstream.evaluation.decision.shouldNotify {
                Text("New")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(workstream.attention.tint)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(workstream.attention.tint.opacity(0.15), in: Capsule())
            }
            if let changed = workstream.lastMeaningfulChange {
                Text(Age.compact(since: changed))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Filled dot when it's the user's turn; hollow ring while someone else holds it.
struct AttentionMarker: View {
    let level: AttentionLevel
    let filled: Bool

    var body: some View {
        Group {
            if filled {
                Circle().fill(level.tint)
            } else {
                Circle().strokeBorder(.secondary, lineWidth: 1.2)
            }
        }
        .frame(width: 8, height: 8)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
    }
}

private struct NextActionLine: View {
    let action: NextAction
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.turn.down.right")
                .font(.caption2.weight(.semibold))
            Text(action.title)
                .font(.caption.weight(.medium))
            if let minutes = action.estimatedMinutes {
                Text("· ~\(minutes) min")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(tint)
    }
}

/// Expanded view: current derived state first, then the context behind it.
private struct WorkstreamDetail: View {
    let workstream: Workstream

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            row("State", workstream.state.displayName)
            row("Owner", workstream.nextOwner.displayName)
            if let action = workstream.nextAction {
                row("Why", action.reason)
                row("Next", action.title)
            }
            if !links.isEmpty {
                row("Links", links.joined(separator: " · "))
            }
            if let meeting = workstream.calendarContext {
                row("Calendar", "\(meeting.title) \(Age.until(meeting.startsAt))")
            }
            if let plane = workstream.planeItem {
                GridRow {
                    Text("Plane")
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    if let url = plane.url {
                        Link("\(plane.identifier) ↗", destination: url)
                    } else {
                        Text(plane.identifier).foregroundStyle(.secondary)
                    }
                }
            }
            if let pr = workstream.pullRequest {
                GridRow {
                    Text("GitHub")
                        .foregroundStyle(.tertiary)
                        .gridColumnAlignment(.trailing)
                    if let url = pr.url {
                        Link("\(pr.repository)#\(pr.number) ↗", destination: url)
                    } else {
                        Text("\(pr.repository)#\(pr.number)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var links: [String] {
        var result: [String] = []
        if let plane = workstream.planeItem { result.append(plane.identifier) }
        if let pr = workstream.pullRequest { result.append(pr.label) }
        for session in workstream.agentSessions {
            result.append("\(session.agentName) (\(session.status.rawValue))")
        }
        return result
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.tertiary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
