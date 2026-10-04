#if DEBUG
import SwiftUI

/// Debug-only status of the Claude Code hook connection.
struct ClaudeDiagnosticsView: View {
    let receiver: ClaudeHookReceiver
    let workstreams: [Workstream]

    private var activity: ClaudeHookReceiver.Activity { receiver.activity }

    private var sessions: [AgentSession] {
        workstreams.flatMap(\.agentSessions).filter { $0.id.hasPrefix("\(ClaudeHookNormalizer.provider):") && $0.status != .ended }
    }

    private func count(_ status: AgentSession.Status) -> Int {
        sessions.filter { $0.status == status }.count
    }

    private var lastWorkstream: String? {
        activity.lastWorkstreamID.flatMap { id in workstreams.first { $0.id == id }?.title }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let isLive = activity.lastEventAt.map { context.date.timeIntervalSince($0) < 15 * 60 } ?? false
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isLive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text("Claude Code")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(isLive ? "Receiving" : (activity.received == 0 ? "No hook events yet" : "Quiet"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    if activity.rejected > 0 {
                        Text("\(activity.rejected) rejected")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                if let event = activity.lastEvent, let at = activity.lastEventAt {
                    Text("Last \(event) · \(Age.compact(since: at, now: context.date)) · \(activity.received) received")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Sessions \(sessions.count) · working \(count(.working)) · needs input \(count(.needsInput)) · completed \(count(.completed)) · failed \(count(.failed))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(activity.lastRepository ?? "no repository") @ \(activity.lastBranch ?? "-") → \(lastWorkstream ?? "no workstream")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
    }
}
#endif
