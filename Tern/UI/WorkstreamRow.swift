import SwiftUI

struct WorkstreamRow: View {
    let workstream: Workstream
    let isExpanded: Bool
    let toggle: () -> Void
    var actions: ItemActions = .none
    var perform: @MainActor (ActionTarget) -> Void = { _ in }
    /// The first item in Needs you: the one whose action is drawn in coral.
    var isLead = false

    @State private var isHovering = false

    private var isMyTurn: Bool { workstream.nextOwner == .me }
    private var tone: AttentionTone {
        .of(level: workstream.attention, reason: workstream.evaluation.decision.reason, mine: isMyTurn)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            OwnershipMarker(owner: workstream.nextOwner, tone: tone)

            VStack(alignment: .leading, spacing: 2) {
                titleLine
                Headline(text: workstream.status.headline, tone: tone, emphasized: isMyTurn)
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
                    NextActionLine(action: action)
                        .padding(.top, 3)
                }
                if isMyTurn {
                    ActionButtons(actions: actions, prominent: isLead && tone == .yourTurn, perform: perform)
                        .padding(.top, 2)
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
                .font(workstream.primaryLabelIsIdentifier ? .identifier(.callout, weight: .semibold) : .callout.weight(.semibold))
            if workstream.primaryLabel != workstream.title {
                Text(workstream.title)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if workstream.evaluation.decision.shouldNotify {
                NewBadge()
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

/// The ball when the turn is the user's; a hollow ring while someone else holds it. It
/// supplements the row's text, which always says whose move it is.
struct OwnershipMarker: View {
    let mark: OwnershipMark
    let tone: AttentionTone
    /// What VoiceOver says in place of the glyph.
    let label: String

    init(owner: Owner, tone: AttentionTone) {
        mark = OwnershipMark(owner)
        self.tone = tone
        label = owner == .me ? "Your turn" : "\(owner.displayName) has it"
    }

    init(mark: OwnershipMark, tone: AttentionTone, label: String) {
        self.mark = mark
        self.tone = tone
        self.label = label
    }

    var body: some View {
        Group {
            switch mark {
            case .ball:
                Circle().fill(tone == .quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(TernColor.yourTurn))
            case .ring:
                Circle().strokeBorder(.tertiary, lineWidth: 1.5)
            case .none:
                Color.clear
            }
        }
        .frame(width: 8, height: 8)
        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
        .accessibilityLabel(label)
        .accessibilityHidden(mark == .none)
    }
}

/// A row's status line. Problems get crimson and a symbol, so they read as wrong without colour.
struct Headline: View {
    let text: String
    let tone: AttentionTone
    let emphasized: Bool

    var body: some View {
        if tone == .critical {
            Label(text, systemImage: "exclamationmark.circle.fill")
                .labelStyle(HeadlineLabelStyle())
                .font(.callout)
                .foregroundStyle(TernColor.critical)
        } else {
            Text(text)
                .font(.callout)
                .foregroundStyle(emphasized ? .primary : .secondary)
        }
    }
}

private struct HeadlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Marks a change the user hasn't been shown yet.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(TernColor.yourTurnText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(TernColor.yourTurn.opacity(0.12), in: Capsule())
    }
}

private struct NextActionLine: View {
    let action: NextAction

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
        .foregroundStyle(.secondary)
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
